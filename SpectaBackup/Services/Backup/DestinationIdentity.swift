//
//  @file        DestinationIdentity.swift
//  @description Finds a job's destination folder wherever macOS mounted it. The folder carries a small
//               marker file with an ID the job remembers, so a NAS share remounted at /Volumes/home-1, a
//               drive mounted as "/Volumes/Backup 1", or a NAS reached under a new address is found by what
//               it is rather than by the path it had.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Marker: `<destination>/.spectark-destination`, JSON {"id": UUID}. One per destination folder, shared
//    by every job backing up into it. Created exclusively (a temp file renamed with RENAME_EXCL): of two
//    jobs marking one folder at once, the second adopts the first one's ID.
//  - A new job's folder is marked when the job is created: the user just chose it (`identify`).
//  - A marker with another ID decides: that folder is another destination — even at the job's own path
//    (another NAS's share mounted under the same name). The job is "not connected"; nothing is written.
//  - Jobs from before identities are found where their own backups are shown to be — their
//    `SpectaBackup/<job>` folder, or that folder inside a NAS image (looked into read-only, without the
//    writer lock: any SpectArk image is no proof) — at the recorded path, else at the same place on another
//    volume, and marked there. Every such job that ever ran left that evidence, so none found anywhere
//    means "not connected": whatever folder now sits at the recorded path is never taken on trust.
//  - A lost marker is put back only where the job's own backups are, and only when its marked folder is
//    found nowhere.
//  - Search: the mounted volumes of the destination's kind (local or network, recorded when it was found),
//    at the folder's path within its volume and at the tails of that path (a share mounted one folder
//    deeper). The longest path known is kept, so a deeper mount once does not lose the way back. Volumes
//    are listed without blocking (getmntinfo, MNT_NOWAIT), so a missing local drive never waits on a hung
//    network share.
//  - A copy of a destination folder carries its marker (or its backups): while the original is not
//    mounted, the copy is taken for it — a destination moved to a new disk is followed. Decided so
//    (2026-09-19): being stuck "not connected" after moving to a new disk, with no way to point the job
//    elsewhere, is worse than backing up into an archive copy while the original is away.
//  - Every look is errno-aware: a folder that cannot be read is "cannot tell", never "no marker".
//  - Resolving touches the filesystem: `resolveInBackground` runs it on a serial queue per destination
//    path, off Swift's shared thread pool — jobs sharing a folder never mark it at the same time, and a
//    slow share holds up only resolutions that must look at it.
//

import Darwin
import Foundation

/// The job's identified destination folder is mounted nowhere (DestinationIdentity).
struct DestinationNotConnected: Error, CustomStringConvertible {
    var description: String { "the backup destination is not connected" }
}

enum DestinationIdentity {

    static let markerName = ".spectark-destination"

    /// Where a destination folder was found.
    struct Location: Equatable, Sendable {
        let url: URL
        /// The ID its marker carries; nil when it could not be marked (found by the job's backups alone).
        let id: UUID?
        /// Its path within its volume ("" = the volume itself); nil when that could not be told.
        let subpath: String?
        /// On a local volume (not a network share); nil when that could not be told.
        let isLocal: Bool?
    }

    enum Resolution: Equatable, Sendable {
        case found(Location)
        /// The job's destination is mounted nowhere. Its recorded path, if present, is another folder.
        case notConnected
    }

    /// A mounted volume a destination can be on.
    struct Volume: Sendable {
        let url: URL
        let isLocal: Bool
    }

    // MARK: - Resolving

    /// `resolve`, on the serial queue of the job's recorded destination.
    static func resolveInBackground(_ job: BackupJob) async -> Resolution {
        let queue = queues.queue(for: job.destination.standardizedFileURL.path)
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: resolve(job)) }
        }
    }

    /// Where `job`'s destination folder is now. `volumes`: the mounted volumes to search; `volumeRoot`: the
    /// root of the volume a folder is on (both replaced by tests).
    static func resolve(_ job: BackupJob,
                        volumes: () -> [Volume] = mountedVolumes,
                        volumeRoot: (URL) -> URL? = volumeRoot(of:)) -> Resolution {
        let recorded = job.destination
        guard let id = job.destinationID else {
            return identifyExisting(job, volumes: volumes, volumeRoot: volumeRoot)
        }
        let known = job.destinationSubpath
        func located(_ url: URL) -> Resolution {
            .found(Location(url: url, id: id, subpath: longest(known, subpath(of: url, volumeRoot: volumeRoot)),
                            isLocal: isLocal(url) ?? job.destinationIsLocal))
        }

        if case let .marked(existing) = marker(in: recorded), existing == id { return located(recorded) }
        if let known {
            let kind = volumes().filter { job.destinationIsLocal == nil || $0.isLocal == job.destinationIsLocal }
            for candidate in candidates(for: known, in: kind) {
                if case let .marked(existing) = marker(in: candidate), existing == id { return located(candidate) }
            }
        }
        // Marked nowhere: its marker may have been lost where the job's own backups still are.
        if case .unmarked = marker(in: recorded), holdsBackups(of: job, in: recorded),
           mark(recorded, proposing: id) == id {
            return located(recorded)
        }
        return .notConnected
    }

    /// `identify`, on the serial queue of the folder.
    static func identifyInBackground(newDestination folder: URL) async throws -> Location {
        let queue = queues.queue(for: folder.standardizedFileURL.path)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try identify(newDestination: folder) }) }
        }
    }

    /// Mark a folder the user just chose as a new job's destination (or adopt the mark another job gave it).
    /// Throws when it cannot be marked — nothing could be backed up there either.
    static func identify(newDestination folder: URL,
                         volumeRoot: (URL) -> URL? = volumeRoot(of:)) throws -> Location {
        guard try Syscalls.exists(folder.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        guard let id = mark(folder, proposing: UUID()) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
        }
        return Location(url: folder, id: id, subpath: subpath(of: folder, volumeRoot: volumeRoot), isLocal: isLocal(folder))
    }

    /// A job from before identities: the folder holding its own backups — at its recorded path, else at the
    /// same place on another volume (a drive that came back as "Backup 1").
    private static func identifyExisting(_ job: BackupJob, volumes: () -> [Volume],
                                         volumeRoot: (URL) -> URL?) -> Resolution {
        let recorded = job.destination
        var places = [recorded]
        if let path = subpath(of: recorded, volumeRoot: volumeRoot) ?? pathWithinVolume(recorded) {
            places += candidates(for: path, in: volumes())
        }
        var seen = Set<String>()
        for place in places where seen.insert(place.standardizedFileURL.path).inserted {
            guard holdsBackups(of: job, in: place) else { continue }
            // Marked when it can be; when not (a read-only share), found by its backups this time all the same.
            return .found(Location(url: place, id: mark(place, proposing: UUID()),
                                   subpath: subpath(of: place, volumeRoot: volumeRoot), isLocal: isLocal(place)))
        }
        return .notConnected
    }

    // MARK: - Volumes and paths

    /// The volumes a destination can be on — hidden ones (SpectArk's own NAS images) excluded — as the
    /// kernel last knew them: never waits on a volume that does not answer.
    static func mountedVolumes() -> [Volume] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&mounts, MNT_NOWAIT))
        guard count > 0, let mounts else { return [] }
        return (0..<count).compactMap { index in
            let mount = mounts[index]
            guard mount.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { return nil }
            let path = withUnsafeBytes(of: mount.f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Volume(url: URL(fileURLWithPath: path, isDirectory: true),
                          isLocal: mount.f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }

    /// Whether `folder` is on a local volume; nil when that cannot be told.
    private static func isLocal(_ folder: URL) -> Bool? {
        (try? Syscalls.volumeInfo(at: folder.path))?.isLocal
    }

    /// The root of the volume `url` is on. A fresh URL: resource values are cached per URL instance.
    static func volumeRoot(of url: URL) -> URL? {
        (try? URL(fileURLWithPath: url.path, isDirectory: true).resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    /// `folder`'s path within its volume ("" = the volume itself).
    static func subpath(of folder: URL, volumeRoot: (URL) -> URL?) -> String? {
        guard let root = volumeRoot(folder) else { return nil }
        let rootPath = root.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        if rootPath == "/" { return String(path.drop { $0 == "/" }) }
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count).drop { $0 == "/" })
    }

    /// The path within its volume of a folder whose volume is not mounted: what follows `/Volumes/<name>`.
    private static func pathWithinVolume(_ folder: URL) -> String? {
        let parts = folder.standardizedFileURL.pathComponents   // ["/", "Volumes", name, …]
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        return parts.dropFirst(3).joined(separator: "/")
    }

    /// Each volume at `path` and at its tails.
    private static func candidates(for path: String, in volumes: [Volume]) -> [URL] {
        volumes.flatMap { volume in
            tails(of: path).map { $0.isEmpty ? volume.url : volume.url.appendingPathComponent($0, isDirectory: true) }
        }
    }

    /// "a/b/c" → "a/b/c", "b/c", "c", "".
    private static func tails(of path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        return (0...parts.count).map { parts[$0...].joined(separator: "/") }
    }

    /// The known path, unless what was just seen is not one of its tails (the folder was moved within its
    /// volume): a deeper mount seen once must not lose the way back.
    private static func longest(_ known: String?, _ seen: String?) -> String? {
        guard let known, let seen else { return seen ?? known }
        return tails(of: known).contains(seen) ? known : seen
    }

    // MARK: - Marker

    private struct Marker: Codable {
        let id: UUID
    }

    private enum MarkerState {
        case marked(UUID)
        /// The folder is there and readable, without a readable marker.
        case unmarked
        /// No folder there, or it cannot be read.
        case unreachable
    }

    private static func marker(in folder: URL) -> MarkerState {
        guard (try? Syscalls.exists(folder.path)) == true else { return .unreachable }
        let file = folder.appendingPathComponent(markerName)
        guard let present = try? Syscalls.exists(file.path) else { return .unreachable }
        guard present else { return .unmarked }
        guard let data = try? Data(contentsOf: file) else { return .unreachable }
        guard let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return .unmarked }
        return .marked(marker.id)
    }

    /// Mark `folder` with `proposed`, unless it is marked already: returns the ID it carries afterwards —
    /// the one already there when another job got there first — or nil when it could not be marked.
    private static func mark(_ folder: URL, proposing proposed: UUID) -> UUID? {
        switch marker(in: folder) {
        case let .marked(existing): return existing
        case .unreachable: return nil
        case .unmarked: break
        }
        let file = folder.appendingPathComponent(markerName)
        // A marker that cannot be decoded marks nothing: it goes, so the exclusive rename can succeed — read
        // once more first, in case another job's has just landed.
        if (try? Syscalls.exists(file.path)) == true {
            if case let .marked(existing) = marker(in: folder) { return existing }
            unlink(file.path)
        }
        let temp = folder.appendingPathComponent(markerName + "." + UUID().uuidString)
        guard let data = try? JSONEncoder().encode(Marker(id: proposed)),
              (try? data.write(to: temp)) != nil else { return nil }
        if renamex_np(temp.path, file.path, UInt32(RENAME_EXCL)) == 0 { return proposed }
        let failure = errno
        if failure == ENOTSUP || failure == EINVAL {
            // No exclusive rename on this file system: a plain one (jobs on one destination mark it on one
            // queue, so only another Mac could race it).
            if rename(temp.path, file.path) == 0 { return proposed }
        }
        unlink(temp.path)
        if failure == EEXIST, case let .marked(existing) = marker(in: folder) { return existing }
        return nil
    }

    /// The job's own backups are in `folder`: its job folder there, or inside the NAS image there — looked
    /// into (read-only, no writer lock), since any SpectArk image is no proof it holds this job's backups.
    private static func holdsBackups(of job: BackupJob, in folder: URL) -> Bool {
        var there = job
        there.destination = folder
        if (try? Syscalls.exists(BackupRunner.jobRoot(for: there).path)) == true { return true }
        guard (try? Syscalls.exists(ImageLease.imageURL(for: folder).path)) == true else { return false }
        let inside = "\(SparsebundleManager.jobsFolderName)/\(job.id.uuidString)"
        return ImageLease.shared(for: folder).peek { mount in
            (try? Syscalls.exists(mount.appendingPathComponent(inside).path)) == true
        } ?? false
    }

    // MARK: - Queues

    private static let queues = QueueRegistry()
}

/// One serial queue per destination path.
private final class QueueRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: DispatchQueue] = [:]

    func queue(for path: String) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[path] { return queue }
        let queue = DispatchQueue(label: "ai.calidalab.spectabackup.destination", qos: .utility)
        queues[path] = queue
        return queue
    }
}
