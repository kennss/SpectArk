//
//  @file        ImageLease.swift
//  @description Keeps a destination's sparsebundle (a NAS job's backups) attached while anything uses
//               it — a pass, the timeline, a restore, an open restore sheet — and detaches it once nothing
//               has for a little while. Also gives the image's free space back to the share when asked.
//               One lease per image, shared by everything in the process.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Not an actor, and independent of BackupRunner's gate: the restore sheet opens a session while a
//    long pass holds the runner, and the image is attached already.
//  - `acquire` blocks while it attaches (hdiutil, seconds over SMB), and holds the lease's lock meanwhile
//    so concurrent users wait for one attach instead of racing a second: call it off the main actor.
//    `release` may wait for that lock too; the main actor hands it to a background task.
//  - Before an attachment is reused it is checked to still be our volume (its UUID at the mount point):
//    macOS ejects a disk image whose share dropped. A dead one is forgotten (its lock released) and the
//    image attached again; users still holding the old mount point fail on it like any pass the share
//    dropped under.
//  - Idle: detached `idleTimeout` (30 s) after the last user left — long enough for a pass and the
//    timeline refresh right after it to share one attach, short enough that another Mac backing up to
//    the same image is not locked out for long. Writers flush on release (SparsebundleManager.flush), so
//    an idle attachment holds nothing unwritten.
//  - Reclaim (`requestReclaim`): runs once nobody uses the image, on the lease's own queue. Whether the
//    image still holds any job's backups is decided then, under the lock and with the image attached
//    (so the writer lock is ours): none → the image is removed; some, or unreadable → it is compacted.
//    Read on a volume that was ejected meanwhile, the listing is no verdict; a reclaim that cannot run
//    now stays wanted and runs when the image is next left unused.
//  - `peek` looks inside without claiming the image (identifying a destination): read-only, no lock.
//  - Sleep detaches idle images, skipping any lease busy attaching or compacting (the main thread never
//    waits on it); quitting detaches everything (SparsebundleManager.detachAll, from AppDelegate).
//

import Darwin
import Foundation

final class ImageLease: @unchecked Sendable {

    /// The image a destination's NAS backups live in.
    static func imageURL(for destination: URL) -> URL {
        destination.appendingPathComponent(SparsebundleManager.imageName, isDirectory: true)
    }

    /// The lease of `destination`'s image (created on first use).
    static func shared(for destination: URL) -> ImageLease {
        let key = imageURL(for: destination).standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let lease = registry[key] { return lease }
        let lease = ImageLease(destination: destination)
        registry[key] = lease
        return lease
    }

    /// Detach every image nothing is using right now (the Mac is going to sleep). A lease busy attaching
    /// or compacting is skipped rather than waited for.
    static func detachIdle() {
        registryLock.lock()
        let leases = Array(registry.values)
        registryLock.unlock()
        for lease in leases where lease.lock.try() {
            lease.detachLocked()
            lease.lock.unlock()
        }
    }

    nonisolated(unsafe) private static var registry: [String: ImageLease] = [:]
    private static let registryLock = NSLock()

    let destination: URL
    private let idleTimeout: TimeInterval
    private let lock = NSLock()
    /// Where reclaims run (tests wait for it with `drain`).
    private let queue = DispatchQueue(label: "ai.calidalab.spectabackup.image-lease", qos: .utility)
    private var attachment: SparsebundleManager.Attachment?
    private var users = 0
    /// Bumped by every acquire, so an idle-detach timer armed before it does nothing.
    private var generation = 0
    private var reclaimWanted = false

    init(destination: URL, idleTimeout: TimeInterval = 30) {
        self.destination = destination
        self.idleTimeout = idleTimeout
    }

    /// The image exists at the destination. Throws when the share cannot tell (it stopped answering).
    func imageExists() throws -> Bool {
        try Syscalls.exists(Self.imageURL(for: destination).path)
    }

    /// Hold the image attached and return its mount point. `create`: make the image (sized for
    /// `maxSizeBytes`, 0 = the default cap) when there is none — only a pass does. Pair every successful
    /// call with `release`.
    func acquire(maxSizeBytes: Int64 = 0, create: Bool) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        let mount = try attachedLocked(create: create, maxSizeBytes: maxSizeBytes)
        users += 1
        return mount
    }

    /// Done with the image. `flush`: the user wrote into it. The last user out runs a wanted reclaim, or
    /// arms the idle detach.
    func release(flush: Bool) {
        lock.lock()
        let current = attachment
        lock.unlock()
        if flush, let current { SparsebundleManager.flush(current) }

        lock.lock()
        defer { lock.unlock() }
        users -= 1
        guard users == 0 else { return }
        if reclaimWanted {
            queue.async { self.reclaim() }
        } else {
            armIdleDetachLocked()
        }
    }

    /// Give the image's free space back to the share once nobody uses it — remove the image if it holds
    /// no job's backups any more, compact it otherwise.
    func requestReclaim() {
        lock.lock()
        defer { lock.unlock() }
        reclaimWanted = true
        if users == 0 { queue.async { self.reclaim() } }
    }

    /// Detach now if nothing uses the image — and, with `generation`, nothing acquired it since the timer
    /// was armed.
    func detachIfIdle(generation armed: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard armed == nil || armed == generation else { return }
        detachLocked()
    }

    /// Look inside the image without claiming it: through the attachment when one is held, else attached
    /// read-only for the look — no writer lock, so another Mac using the image is not held up — and
    /// detached right after. Under the lease's lock: an image attached read-only cannot be attached
    /// read-write (measured), so nothing of this process may try meanwhile. nil when it cannot be attached.
    func peek<T>(_ body: (URL) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        if let current = attachment, SparsebundleManager.isAttached(current) { return body(current.mountPoint) }
        guard let look = try? SparsebundleManager.attach(at: destination, maxSizeBytes: 0, readOnly: true) else { return nil }
        defer { SparsebundleManager.detach(look) }
        return body(look.mountPoint)
    }

    /// Wait until the reclaims requested so far have run (tests).
    func drain() {
        queue.sync {}
    }

    /// The image is attached through this lease right now (tests).
    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return attachment != nil
    }

    // MARK: - Under the lock

    /// The live attachment, attaching (or attaching again) when there is none.
    private func attachedLocked(create: Bool, maxSizeBytes: Int64) throws -> URL {
        if let current = attachment, !SparsebundleManager.isAttached(current) {
            SparsebundleManager.forget(current)   // ejected: only its lock is released, no hdiutil
            attachment = nil
        }
        if let attachment { return attachment.mountPoint }
        SparsebundleManager.sweepRemovedImages(at: destination)
        guard try create || imageExists() else { throw SparsebundleManager.SBError.missingImage }
        let attached = try SparsebundleManager.attach(at: destination, maxSizeBytes: maxSizeBytes, readOnly: false)
        attachment = attached
        return attached.mountPoint
    }

    private func detachLocked() {
        guard users == 0, let current = attachment, SparsebundleManager.detach(current) else { return }
        attachment = nil
    }

    private func armIdleDetachLocked() {
        let armed = generation
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleTimeout) { [weak self] in
            self?.detachIfIdle(generation: armed)
        }
    }

    /// Runs a wanted reclaim; one that cannot run now stays wanted and is tried again when the image is
    /// next left unused.
    private func reclaim() {
        lock.lock()
        defer { lock.unlock() }
        guard users == 0, reclaimWanted else { return }
        // Attached (again, after a sleep) so the writer lock is ours while the image is judged and
        // reclaimed: another Mac may have added a job to it meanwhile.
        guard let mount = try? attachedLocked(create: false, maxSizeBytes: 0), let current = attachment else { return }
        let verdict = Self.holdsNoBackups(mount)
        // Ejected while it was read: what was read is no verdict on the image (an empty listing may be
        // another volume's, or none at all).
        guard SparsebundleManager.isAttached(current) else {
            SparsebundleManager.forget(current)
            attachment = nil
            return
        }
        if SparsebundleManager.detach(current, reclaim: verdict == true ? .remove : .compact) {
            attachment = nil
            reclaimWanted = false
        } else {
            armIdleDetachLocked()   // refused: still attached, so it is detached as idle later
        }
    }

    /// Whether the image's jobs folder holds no job's folder: true = none, false = some, nil = it could not
    /// be read (then nothing is removed).
    private static func holdsNoBackups(_ mount: URL) -> Bool? {
        let folder = mount.appendingPathComponent(SparsebundleManager.jobsFolderName, isDirectory: true).path
        guard let dir = opendir(folder) else { return errno == ENOENT ? true : nil }
        defer { closedir(dir) }
        while true {
            errno = 0
            guard let entry = readdir(dir) else { return errno == 0 ? true : nil }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !name.hasPrefix(".") { return false }
        }
    }
}
