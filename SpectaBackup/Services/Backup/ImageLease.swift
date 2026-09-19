//
//  @file        ImageLease.swift
//  @description Keeps a destination's sparsebundle (a NAS job's backups) attached while anything uses
//               it — a pass, the timeline, a restore, an open restore sheet — and detaches it once nothing
//               has for a little while. Also gives the image's free space back to the share — when asked,
//               and as it is detached idle once enough is to be had (CompactionLedger keeps what each
//               image's compactions showed, across launches). One lease per image, shared by everything
//               in the process.
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
//  - Compaction: space retention frees inside an image stays allocated on the share until the image is
//    compacted (measured). When the idle timer detaches an image, what the share holds for it (band files ×
//    band size) is compared with what its volume uses (ATTR_VOL_SPACEUSED, measured while still attached):
//    the gap. Compaction gives back only bands left wholly free, so part of the gap is the image's own —
//    its structures, and free space scattered through bands still in use (measured on a 105 GB NAS image:
//    1.2 GB of gap, 72 MB given back, 3 minutes over SMB). The gap a compaction leaves is the baseline, and
//    the next compaction waits for the gap to grow `compactionThreshold` past it; the baseline follows the
//    gap down as later writes fill the scattered space. APFS gives freed blocks back to the image only as
//    later transactions process its free queue — at once in a small container, over later writes in a large
//    one (measured: 100 MB freed in a 100 GB image reclaimed 4 MB at once, all of it after a minute of
//    further writes) — so a compaction that left a gap past the threshold is followed up a day later; a
//    follow-up that gives back less than the threshold settles the baseline. All this is kept across
//    launches (CompactionLedger), or every launch would compact again what cannot be given back. Compaction
//    runs under the writer lock; sleep and quit never compact.
//

import Darwin
import Foundation
import os

final class ImageLease: @unchecked Sendable {

    private static let log = Logger(subsystem: "ai.calidalab.spectabackup", category: "image")

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
    /// Bytes the gap must grow past its baseline before an idle image is compacted as it is detached.
    private let compactionThreshold: Int64
    /// What is known of this image's compactions, across launches.
    let ledger: CompactionLedger
    /// A compaction that left a gap is followed up this much later (APFS will have released more by then).
    static let compactionFollowUpInterval: TimeInterval = 86_400
    private let lock = NSLock()
    /// Where reclaims run (tests wait for it with `drain`).
    private let queue = DispatchQueue(label: "ai.calidalab.spectabackup.image-lease", qos: .utility)
    private var attachment: SparsebundleManager.Attachment?
    private var users = 0
    /// Bumped by every acquire, so an idle-detach timer armed before it does nothing.
    private var generation = 0
    private var reclaimWanted = false

    init(destination: URL, idleTimeout: TimeInterval = 30, compactionThreshold: Int64 = 1 << 30,
         ledger: CompactionLedger = .shared) {
        self.destination = destination
        self.idleTimeout = idleTimeout
        self.compactionThreshold = compactionThreshold
        self.ledger = ledger
    }

    /// The image exists at the destination. Throws when the share cannot tell (it stopped answering).
    func imageExists() throws -> Bool {
        try Syscalls.exists(Self.imageURL(for: destination).path)
    }

    /// Hold the image attached and return its mount point. `create`: make the image when there is none —
    /// only a pass does (`capacity`: its size, by default the share's). Pair every successful call with
    /// `release`.
    func acquire(capacity: Int64? = nil, create: Bool) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        let mount = try attachedLocked(create: create, capacity: capacity)
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

    /// `requestReclaim`, waited for: the image's free space is back on the share when this returns — unless
    /// something else uses the image; then it is once that lets go.
    func reclaimNow() {
        requestReclaim()
        queue.sync {}
    }

    /// Detach now if nothing uses the image — and, with `generation`, nothing acquired it since the timer
    /// was armed.
    func detachIfIdle(generation armed: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard armed == nil || armed == generation else { return }
        detachLocked(mayCompact: armed != nil)   // only the idle timer takes the time to compact
    }

    /// Look inside the image without claiming it: through the attachment when one is held, else attached
    /// read-only for the look — no writer lock, so another Mac using the image is not held up — and
    /// detached right after. Under the lease's lock: an image attached read-only cannot be attached
    /// read-write (measured), so nothing of this process may try meanwhile. nil when it cannot be attached.
    func peek<T>(_ body: (URL) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        if let current = attachment, SparsebundleManager.isAttached(current) { return body(current.mountPoint) }
        guard let look = try? SparsebundleManager.attach(at: destination, readOnly: true) else { return nil }
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
    private func attachedLocked(create: Bool, capacity: Int64? = nil) throws -> URL {
        if let current = attachment, !SparsebundleManager.isAttached(current) {
            SparsebundleManager.forget(current)   // ejected: only its lock is released, no hdiutil
            attachment = nil
        }
        if let attachment { return attachment.mountPoint }
        SparsebundleManager.sweepRemovedImages(at: destination)
        guard try create || imageExists() else { throw SparsebundleManager.SBError.missingImage }
        let attached = try SparsebundleManager.attach(at: destination, capacity: capacity, readOnly: false)
        attachment = attached
        return attached.mountPoint
    }

    private func detachLocked(mayCompact: Bool = false) {
        guard users == 0, let current = attachment else { return }
        if mayCompact, let used = Self.usedBytes(of: current), let held = Self.heldBytes(of: current.imageURL) {
            let record = ledger.record(for: current.volumeID)
            if let trigger = Self.compactionTrigger(gap: held - used, record: record,
                                                    threshold: compactionThreshold, now: Date()) {
                compactLocked(current, held: held, used: used, trigger: trigger)
                return
            }
            if let lowered = Self.lowered(record, toGap: held - used) {
                ledger.set(lowered, for: current.volumeID)
            }
        }
        guard SparsebundleManager.detach(current) else { return }
        attachment = nil
    }

    /// Detach the image and compact it, and note what that gave back. False: the detach was refused (the
    /// image is still attached). `held`, `used`: measured just before, while attached; nil when they could
    /// not be — then nothing is noted, and the idle timer measures afresh next time.
    @discardableResult
    private func compactLocked(_ current: SparsebundleManager.Attachment, held: Int64?, used: Int64?,
                               trigger: CompactionTrigger) -> Bool {
        let started = Date()
        let result = SparsebundleManager.detach(current, reclaim: .compact)
        guard result != .refused else { return false }
        attachment = nil
        guard let held, let used else { return true }
        let after = result == .reclaimed ? (Self.heldBytes(of: current.imageURL) ?? held) : held
        let left = max(0, after - used), given = max(0, held - after)
        let record = Self.record(afterCompacting: trigger, previous: ledger.record(for: current.volumeID),
                                 left: left, given: given, succeeded: result == .reclaimed,
                                 threshold: compactionThreshold, now: Date())
        ledger.set(record, for: current.volumeID)
        let seconds = Int(Date().timeIntervalSince(started).rounded())
        let next = record.followUp == nil ? "" : "; looked at again in a day"
        if case let .failed(why) = result {
            Self.log.error("compacting the image at \(self.destination.path, privacy: .public) failed after \(seconds) s: \(why, privacy: .public)\(next, privacy: .public)")
        } else {
            Self.log.notice("compacted the image at \(self.destination.path, privacy: .public) (\(trigger.rawValue, privacy: .public)): \(given >> 20) MB of \((held - used) >> 20) MB held beyond use given back in \(seconds) s\(next, privacy: .public)")
        }
        return true
    }

    // MARK: - Compaction policy

    /// Why an idle image is compacted.
    enum CompactionTrigger: String, Sendable {
        /// The gap grew past its baseline by the threshold: something was freed since.
        case grown
        /// A compaction that left a gap is looked at again.
        case followUp
    }

    /// Whether an image whose share holds `gap` bytes beyond its volume's use is compacted now.
    static func compactionTrigger(gap: Int64, record: CompactionRecord?, threshold: Int64,
                                  now: Date) -> CompactionTrigger? {
        guard gap >= threshold else { return nil }
        if gap >= (record?.baseline ?? 0) + threshold { return .grown }
        if let due = record?.followUp, now >= due { return .followUp }
        return nil
    }

    /// What is known of an image once it was compacted: `left` bytes still held beyond use, `given` back.
    /// A failed compaction is no verdict: tried again a day later. One that left a gap past the threshold
    /// may have run before APFS released what was freed: looked at again a day later — unless it was that
    /// look again, and it gave back less than the threshold, so what is left is the image's own.
    static func record(afterCompacting trigger: CompactionTrigger, previous: CompactionRecord?, left: Int64,
                       given: Int64, succeeded: Bool, threshold: Int64, now: Date) -> CompactionRecord {
        let again = !succeeded || (left >= threshold && (trigger == .grown || given >= threshold))
        return CompactionRecord(baseline: left, compacted: succeeded ? now : previous?.compacted,
                                followUp: again ? now.addingTimeInterval(compactionFollowUpInterval) : nil)
    }

    /// The record with its baseline brought down to a smaller gap (later writes filled scattered free space),
    /// so growth is measured from the least the gap has been; nil when nothing changes.
    static func lowered(_ record: CompactionRecord?, toGap gap: Int64) -> CompactionRecord? {
        guard var record, gap < record.baseline else { return nil }
        record.baseline = max(0, gap)
        return record
    }

    /// Bytes the attached image's volume holds (ATTR_VOL_SPACEUSED — what `diskutil` calls its capacity in
    /// use). Not statfs: a sparse image's free space is capped by the share's, so its "used" is meaningless
    /// (measured: 1 TB for an empty image), and freeing space inside does not show there.
    private static func usedBytes(of attachment: SparsebundleManager.Attachment) -> Int64? {
        guard SparsebundleManager.isAttached(attachment) else { return nil }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 32)   // u_int32 length, then the off_t — packed, unaligned
        guard getattrlist(attachment.mountPoint.path, &request, &buffer, buffer.count, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: Int64.self) }
    }

    /// Bytes the share holds for the image: its band files, each allocated whole (band size, Info.plist).
    private static func heldBytes(of image: URL) -> Int64? {
        guard let info = NSDictionary(contentsOf: image.appendingPathComponent("Info.plist")),
              let bandSize = (info["band-size"] as? NSNumber)?.int64Value,
              let bands = try? FileManager.default.contentsOfDirectory(atPath: image.appendingPathComponent("bands").path)
        else { return nil }
        return Int64(bands.filter { !$0.hasPrefix(".") }.count) * bandSize
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
        guard let mount = try? attachedLocked(create: false), let current = attachment else { return }
        let verdict = Self.holdsNoBackups(mount)
        let used = Self.usedBytes(of: current), held = Self.heldBytes(of: current.imageURL)
        // Ejected while it was read: what was read is no verdict on the image (an empty listing may be
        // another volume's, or none at all).
        guard SparsebundleManager.isAttached(current) else {
            SparsebundleManager.forget(current)
            attachment = nil
            return
        }
        let detached: Bool
        if verdict == true {
            let result = SparsebundleManager.detach(current, reclaim: .remove)
            detached = result != .refused
            if detached { attachment = nil }
            if result == .reclaimed { ledger.forget(current.volumeID) }
        } else {
            // A job's backups were removed: freed, as the idle timer's own growth trigger means.
            detached = compactLocked(current, held: held, used: used, trigger: .grown)
        }
        if detached {
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

/// What the idle timer knows of one image's compactions.
struct CompactionRecord: Codable, Equatable, Sendable {
    /// Bytes the share held beyond the volume's use after the last compaction — the image's own, as far as
    /// is known — brought down as the gap shrinks (`ImageLease.lowered`).
    var baseline: Int64
    /// When a compaction last ran through.
    var compacted: Date?
    /// A follow-up compaction is due from then.
    var followUp: Date?
}

/// Compaction records kept across launches, keyed by the image's volume UUID — a new image in the same place
/// starts afresh, and an image removed takes its record with it. One JSON file; every lease shares it.
final class CompactionLedger: @unchecked Sendable {

    static let shared = CompactionLedger(file: defaultFile)

    /// Application Support in the app, a scratch file in a unit-test host.
    static let defaultFile: URL = {
        if AppRuntime.isUnitTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SpectArkTests-ImageCompaction-\(ProcessInfo.processInfo.processIdentifier).json")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpectaBackup/ImageCompaction.json")
    }()

    let file: URL
    private let lock = NSLock()

    init(file: URL) {
        self.file = file
    }

    func record(for volumeID: String) -> CompactionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return load()[volumeID]
    }

    func set(_ record: CompactionRecord, for volumeID: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = load()
        records[volumeID] = record
        save(records)
    }

    func forget(_ volumeID: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = load()
        guard records.removeValue(forKey: volumeID) != nil else { return }
        save(records)
    }

    /// Every record (tests).
    func all() -> [String: CompactionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    /// Unreadable or absent: nothing known, so the next idle detach measures afresh — at worst one
    /// compaction more.
    private func load() -> [String: CompactionRecord] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: CompactionRecord].self, from: data)) ?? [:]
    }

    private func save(_ records: [String: CompactionRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
