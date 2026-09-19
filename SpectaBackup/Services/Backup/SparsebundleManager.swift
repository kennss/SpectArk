//
//  @file        SparsebundleManager.swift
//  @description Manages an APFS sparsebundle disk image on a destination that is not a local APFS/HFS+
//               volume (NAS shares, exFAT/FAT drives). The image is attached, the history engine runs
//               inside its APFS volume exactly as on a local disk, then it is detached.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-19
//
//  This is the most fragile backup path (review H6) — a network drop can corrupt the embedded
//  filesystem. Safety measures:
//  - Attached only while in use: BackupRunner lends one attachment to passes, the timeline and restore,
//    and detaches it once idle; every attachment is detached when the app quits.
//  - APFS *journaled* image (resilient to interruption).
//  - Always detach (caller uses defer); abort the pass on any I/O error rather than retrying. A detach
//    touches only our volume (checked by UUID at the mount point) and keeps the lock while it is refused.
//  - Single-writer lock file beside the image (two machines attaching the same bundle = corruption).
//    It records the writer's PID, start time and host UUID, so a lock left by a crash is recognised
//    as stale even after a reboot hands its PID to another process.
//  - Deleting files inside the image does NOT shrink it (APFS in a sparsebundle returns no bands on its
//    own — measured): `detach(_:reclaim:)` compacts it, or removes it when nothing in it is kept.
//  - The app reads (timeline, browse, restore) through the same read-write attachment a pass uses
//    (ImageLease): attaching an image that is attached already only returns the existing mount.
//

import Darwin
import Foundation
import SystemConfiguration

struct SparsebundleManager: Sendable {

    static let imageName = "SpectaBackup.sparsebundle"
    static let lockName = ".spectabackup.lock"

    struct Attachment: Sendable, Hashable {
        let imageURL: URL
        let mountPoint: URL
        let lockURL: URL?
        /// The attached volume's UUID: tells this attachment from another volume mounted at the same path
        /// after macOS ejected ours (two NAS images, or a drive, can all be named "SpectaBackup").
        let volumeID: String
    }

    enum SBError: Error, CustomStringConvertible {
        case locked(String)
        case missingImage
        case noMountPoint
        case command(String, Int32, String)

        var description: String {
            switch self {
            case let .locked(p): return "sparsebundle is locked by another writer: \(p)"
            case .missingImage: return "the backup image is missing from the destination"
            case .noMountPoint: return "hdiutil attach returned no usable mount point"
            case let .command(c, code, err): return "hdiutil \(c) failed (\(code)): \(err)"
            }
        }
    }

    /// The folder inside the image that holds one folder per job (`<jobsFolderName>/<job UUID>`).
    static let jobsFolderName = "SpectaBackup"
    /// Prefix of an image being removed: renamed first (instant), deleted after — a removal interrupted
    /// halfway leaves no broken image behind that every later attach would fail on.
    static let removingPrefix = ".deleting-"

    /// Ensure the image exists (create if missing, read-write only) and attach it; returns the mount.
    /// `capacity`: the size a new image may grow to (bytes) — by default the share's own (see `create`).
    static func attach(at destination: URL, capacity: Int64? = nil, readOnly: Bool) throws -> Attachment {
        let image = destination.appendingPathComponent(imageName, isDirectory: true)

        if !(try Syscalls.exists(image.path)) {
            guard !readOnly else { throw SBError.missingImage }
            try create(image: image, capacity: capacity)
        }

        // Single-writer lock (read-write only). Best-effort: prevents same-host double-attach and
        // signals intent to other hosts. A stale lock from a crash is overwritten; one that cannot be
        // read is not taken for stale.
        var lockURL: URL?
        if !readOnly {
            let lock = destination.appendingPathComponent(lockName)
            if try Syscalls.exists(lock.path) {
                let contents = String(decoding: try Data(contentsOf: lock), as: UTF8.self)
                if !contents.isEmpty, isLockLive(contents, at: lock.path) { throw SBError.locked(contents) }
            }
            if let owner = currentLockOwner(), let data = try? JSONEncoder().encode(owner) {
                try? data.write(to: lock, options: .atomic)
            }
            heldLocks.insert(lock.path)
            lockURL = lock
        }

        do {
            let mount = try attachImage(image, readOnly: readOnly)
            // Just attached by us, so the path is ours to detach if the volume cannot be identified.
            guard let id = volumeID(at: mount) else {
                _ = try? run(["detach", mount.path, "-force"])
                throw SBError.noMountPoint
            }
            let attachment = Attachment(imageURL: image, mountPoint: mount, lockURL: lockURL, volumeID: id)
            attachments.insert(attachment)
            return attachment
        } catch {
            if let lockURL { release(lockURL) }
            throw error
        }
    }

    /// Detach the image and release its lock. Only our volume is ever detached: when macOS ejected it and
    /// something else is mounted at its old path now, that is left alone. Returns false — lock kept, the
    /// image being still attached and writable — when the detach was refused.
    @discardableResult
    static func detach(_ attachment: Attachment) -> Bool {
        guard detachVolume(attachment) else { return false }
        attachments.remove(attachment)
        if let lock = attachment.lockURL { release(lock) }
        return true
    }

    /// An attachment whose volume is gone (macOS ejected it): forgotten, its lock released. Never runs
    /// hdiutil — with the volume gone, its old path may hold somebody else's.
    static func forget(_ attachment: Attachment) {
        attachments.remove(attachment)
        if let lock = attachment.lockURL { release(lock) }
    }

    /// Our volume is no longer attached: detached now, or gone already.
    private static func detachVolume(_ attachment: Attachment) -> Bool {
        guard isAttached(attachment) else { return true }
        _ = try? run(["detach", attachment.mountPoint.path, "-force"])
        return !isAttached(attachment)
    }

    /// The image is still mounted where it was attached — a dropped share or sleep can make macOS eject
    /// it behind our back, and another volume can then be mounted at the same path.
    static func isAttached(_ attachment: Attachment) -> Bool {
        volumeID(at: attachment.mountPoint) == attachment.volumeID
    }

    /// Push everything written into the image out to its bands, as a detach would — so an attachment
    /// that stays up while idle holds nothing unwritten if the share then drops.
    static func flush(_ attachment: Attachment) {
        guard isAttached(attachment) else { return }
        let fd = open(attachment.mountPoint.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
    }

    /// UUID of the volume `url` is on. A fresh URL each time: resource values are cached per URL.
    private static func volumeID(at url: URL) -> String? {
        (try? URL(fileURLWithPath: url.path, isDirectory: true)
            .resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// Images this process has attached and not yet detached.
    private static let attachments = AttachmentRegistry()

    /// Detach everything this process attached (app termination).
    static func detachAll() {
        for attachment in attachments.all() { detach(attachment) }
    }

    /// This process no longer holds `lock` — even if the file cannot be removed (a dropped share), it
    /// must not block this process's next attach.
    private static func release(_ lock: URL) {
        heldLocks.remove(lock.path)
        try? FileManager.default.removeItem(at: lock)
    }

    /// What to do with an image's free space once it is detached.
    enum Reclaim: Sendable {
        /// Give the image's free blocks back to the share (`hdiutil compact`).
        case compact
        /// Nothing in the image is kept: remove it.
        case remove
    }

    /// What `detach(_:reclaim:)` did.
    enum ReclaimResult: Equatable, Sendable {
        /// The detach was refused: nothing done, the lock kept, the image still attached.
        case refused
        /// Detached, and the reclaim ran.
        case reclaimed
        /// Detached; the reclaim did not run through, and the image is as it was (why, for the log).
        case failed(String)
    }

    /// Detach, then compact or remove the image — still holding its writer lock, so no other Mac attaches
    /// it meanwhile. Deleting inside an image frees nothing on the share until this runs. A failed
    /// compaction changes nothing; a removal renames the image away first, and what a failed deletion
    /// leaves is removed by `sweepRemovedImages`.
    @discardableResult
    static func detach(_ attachment: Attachment, reclaim: Reclaim) -> ReclaimResult {
        // A removal was decided on what the attached volume held: only that volume, still here, backs it.
        let wasAttached = isAttached(attachment)
        guard detachVolume(attachment) else { return .refused }
        attachments.remove(attachment)
        defer { if let lock = attachment.lockURL { release(lock) } }
        switch reclaim {
        case .compact:
            do {
                try run(["compact", attachment.imageURL.path, "-batteryallowed"])
            } catch {
                return .failed("\(error)")
            }
        case .remove:
            guard wasAttached else { return .failed("the volume was ejected before it was detached") }
            let removing = attachment.imageURL.deletingLastPathComponent()
                .appendingPathComponent(removingPrefix + imageName + "-" + UUID().uuidString, isDirectory: true)
            do {
                try Syscalls.atomicRename(attachment.imageURL.path, to: removing.path)
            } catch {
                return .failed("\(error)")
            }
            try? FileManager.default.removeItem(at: removing)
        }
        return .reclaimed
    }

    /// Images a removal left behind at `destination` (renamed away, not fully deleted): deleted in the
    /// background. Nothing attaches them — they are garbage by name.
    static func sweepRemovedImages(at destination: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        where name.hasPrefix(removingPrefix + imageName) {
            TreeReaper.shared.reap(destination.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: - hdiutil

    /// A new image, sized to grow as far as the share it is on (`capacity` overrides): sparse, it takes only
    /// what it holds. Not the job's quota — retention keeps that, and an image exactly that full would fail
    /// a pass that briefly holds more before its retention runs. hdiutil's "b" size unit is a 512-byte
    /// sector (an image sized in "bytes" with it came out 512 times larger — measured).
    private static func create(image: URL, capacity: Int64?) throws {
        let share = try? Syscalls.volumeInfo(at: image.deletingLastPathComponent().path).totalBytes
        let bytes = max(capacity ?? share ?? (2 << 40), 1 << 30)
        _ = try run(["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", "SpectaBackup",
                     "-size", "\(bytes / 512)b", "-nospotlight", image.path])
    }

    private static func attachImage(_ image: URL, readOnly: Bool) throws -> URL {
        var args = ["attach", image.path, "-nobrowse", "-noverify", "-plist"]
        args.append(readOnly ? "-readonly" : "-readwrite")
        let out = try run(args)
        guard let mount = parseMountPoint(plistData: out) else { throw SBError.noMountPoint }
        return URL(fileURLWithPath: mount)
    }

    private static func parseMountPoint(plistData: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return mountPoint
            }
        }
        return nil
    }

    // MARK: - Writer lock

    /// What a writer records in the lock file. `started` (seconds since 1970) tells a live writer from a
    /// crashed one whose PID was reused — after a reboot a system process can own the same number.
    /// `machine` is the host UUID: host names change with the network, the hardware does not.
    struct LockOwner: Codable, Equatable, Sendable {
        let pid: Int32
        let started: Int64
        let machine: String
        let host: String
    }

    /// The lock contents for this process.
    static func currentLockOwner() -> LockOwner? {
        guard let started = processStart(getpid())?.started, let machine = hostUUID() else { return nil }
        return LockOwner(pid: getpid(), started: started, machine: machine, host: ProcessInfo.processInfo.hostName)
    }

    /// Locks this process holds right now (lock file paths), i.e. images it has attached and not detached.
    static let heldLocks = LockRegistry()

    /// A lock is live only while its writer holds it: on this machine, a process with that PID that was
    /// started at the recorded time — and when that process is this one, only while an attachment of ours
    /// holds the lock at `path` (a detach whose lock file could not be removed must not block us). A lock
    /// from another machine is respected. A lock in the 1.1.x format ("pid@host") carries no start time,
    /// so it is live only while that PID runs SpectArk; its host is compared with every name this Mac
    /// goes by, since the name it was written under may not be the current one.
    static func isLockLive(_ contents: String, at path: String? = nil) -> Bool {
        if let owner = try? JSONDecoder().decode(LockOwner.self, from: Data(contents.utf8)) {
            guard owner.machine == hostUUID() else { return true }
            guard processStart(owner.pid)?.started == owner.started else { return false }
            if owner.pid == getpid() { return path.map { heldLocks.contains($0) } ?? false }
            return true
        }
        guard let atIndex = contents.firstIndex(of: "@") else { return false }
        let host = String(contents[contents.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard thisMachineNames().contains(host.lowercased()) else { return true }   // another Mac → respect
        guard let pid = Int32(contents[..<atIndex]), pid != getpid(), let process = processStart(pid) else { return false }
        return process.name == processStart(getpid())?.name
    }

    /// Every name this Mac goes by (lowercased): its current host name, local host name and DNS names.
    private static func thisMachineNames() -> Set<String> {
        var names = Set(Host.current().names.map { $0.lowercased() })
        names.insert(ProcessInfo.processInfo.hostName.lowercased())
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? { names.insert((local + ".local").lowercased()) }
        return names
    }

    /// Start time and short name of a running process; nil when there is none with that PID.
    private static func processStart(_ pid: Int32) -> (started: Int64, name: String)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (Int64(info.pbi_start_tvsec), name)
    }

    private static func hostUUID() -> String? {
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 0, tv_nsec: 0)
        guard gethostuuid(&uuid, &wait) == 0 else { return nil }
        return UUID(uuid: uuid).uuidString
    }

    @discardableResult
    private static func run(_ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SBError.command(args.first ?? "", process.terminationStatus, err)
        }
        return data
    }
}

/// A thread-safe set of lock file paths.
final class LockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    func insert(_ path: String) { lock.lock(); paths.insert(path); lock.unlock() }
    func remove(_ path: String) { lock.lock(); paths.remove(path); lock.unlock() }
    func contains(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return paths.contains(path) }
}

/// A thread-safe set of attachments.
final class AttachmentRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items = Set<SparsebundleManager.Attachment>()

    func insert(_ item: SparsebundleManager.Attachment) { lock.lock(); items.insert(item); lock.unlock() }
    func remove(_ item: SparsebundleManager.Attachment) { lock.lock(); items.remove(item); lock.unlock() }
    func all() -> [SparsebundleManager.Attachment] { lock.lock(); defer { lock.unlock() }; return Array(items) }
}
