//
//  @file        RepoTimeline.swift
//  @description An encrypted job's restore points, read from its repo. The repo is the only record: its
//               `snapshots/<id>` objects carry each snapshot's time, file count, size and origin, sealed
//               with the repo keys. Each is decrypted once and remembered in a small local cache, so the
//               timeline shows without the password and a refresh decrypts only what is new.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Nothing of the timeline is written at the destination in the clear (no catalog there any more — on a
//    NAS it was SQLite over SMB). The cache lives in Application Support: `RepoCache/<job>.json`.
//  - Every change to a cache is a load-change-save under one process-wide lock, so a timeline read never
//    overwrites what a pass recorded meanwhile (its state, a collection).
//  - The cache belongs to one repo: it records a hash of the repo's recovery key slot, written once when
//    the repo is created (a fresh key each time) and untouched by a password change. A repo created anew
//    never inherits another's cache.
//  - Without keys, snapshots the cache does not know yet are left out; they show once the repo is unlocked
//    (every pass unlocks it). Snapshots gone from the repo (pruned) leave the cache. A snapshot that cannot
//    be decrypted is left out, never cached, and hides nothing else.
//  - Snapshot IDs: "<ms since 1970>-<8 hex>" — unique without a catalog to number them. Repos from before
//    keep their "enc-<n>" IDs.
//  - The cache also keeps when the repo's garbage was last collected (RepoMaintenance runs it daily),
//    where the next pass starts (EncryptedCaptureState: its parent snapshot and journal cursors), and what
//    the repo's packs occupy — measured when a pass or a space reclamation ends, so showing it lists nothing
//    at the destination. Losing it costs one full walk, never data: the parent is checked to still exist.
//

import CryptoKit
import Foundation

/// What the timeline shows of one encrypted snapshot.
struct RepoSnapshotSummary: Codable, Equatable, Sendable {
    let id: String
    let createdAt: Double   // seconds since 1970
    let fileCount: Int
    let totalBytes: Int
    let origin: String?
    /// An explicit restore point (Snapshot.requested).
    var requested: Bool?
}

/// Where the next encrypted pass starts (DedupEngine.Incremental): the snapshot the last pass wrote, the
/// journal cursor each source was read up to, and the folders it left files for later in.
struct EncryptedCaptureState: Codable, Equatable, Sendable {
    var parent: String
    /// The job settings the state holds for (CaptureEngine.fingerprint): others mean a full walk.
    var fingerprint: String
    /// Source name → cursor; absent for a source whose volume keeps no journal.
    var cursors: [String: JournalCursor]
    var carried: [String: Set<String>]
    /// When every source was last walked whole (seconds since 1970).
    var lastFullScan: Double?
    /// When the last pass finished: the backup matched the sources then, whether or not it wrote a snapshot.
    var lastPassEnd: Double?
}

struct RepoTimeline: Sendable {

    /// Where caches live: Application Support in the app, a scratch folder in a unit-test host.
    static let defaultDirectory: URL = {
        if AppRuntime.isUnitTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SpectArkTests-RepoCache-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpectaBackup/RepoCache", isDirectory: true)
    }()

    let directory: URL

    init(directory: URL = RepoTimeline.defaultDirectory) {
        self.directory = directory
    }

    /// A new snapshot's ID.
    static func newSnapshotID(at time: Date) -> String {
        "\(Int64((time.timeIntervalSince1970 * 1000).rounded()))-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The repo's snapshots (unordered). `keys`: nil lists only what the cache knows.
    func snapshots(jobID: UUID, backend: Backend, keys: RepoKeys?) async throws -> [RepoSnapshotSummary] {
        try await listing(jobID: jobID, backend: backend, keys: keys).snapshots
    }

    struct Listing: Sendable {
        var snapshots: [RepoSnapshotSummary] = []
        /// Snapshot objects that could not be read with the keys given: damaged restore points.
        var unreadable: [String] = []
    }

    /// The repo's snapshots, and — with `keys` — those that could not be read.
    func listing(jobID: UUID, backend: Backend, keys: RepoKeys?) async throws -> Listing {
        let repo = try await Self.identity(of: backend)
        let known = load(jobID).flatMap { $0.repo == repo ? $0.snapshots : nil } ?? [:]

        let prefix = "snapshots/"
        let ids = try await backend.list(prefix: "snapshots").map { String($0.dropFirst(prefix.count)) }
        let cipher = keys.map(BlobCipher.init(keys:))
        var added: [String: RepoSnapshotSummary] = [:]
        var result = Listing()
        for id in ids {
            if let summary = known[id] {
                result.snapshots.append(summary)
                continue
            }
            guard let cipher else { continue }
            guard let sealed = try? await backend.get(key: prefix + id),
                  let plaintext = try? cipher.openMetadata(sealed, context: prefix + id),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: plaintext) else {
                result.unreadable.append(id)
                continue
            }
            let summary = RepoSnapshotSummary(id: id, createdAt: snapshot.createdAt, fileCount: snapshot.fileCount,
                                              totalBytes: snapshot.totalBytes, origin: snapshot.origin,
                                              requested: snapshot.requested)
            added[id] = summary
            result.snapshots.append(summary)
        }
        let listed = Set(ids)
        let gone = known.keys.filter { !listed.contains($0) }
        if !added.isEmpty || !gone.isEmpty {
            // Merged into what is on disk now: a pass may have recorded its state meanwhile.
            update(jobID, repo: repo) { cache in
                cache.snapshots.merge(added) { _, new in new }
                for id in gone { cache.snapshots[id] = nil }
            }
        }
        return result
    }

    /// Forget what the cache knows of these snapshots (their objects were rewritten): read them again.
    func refresh(_ jobID: UUID, snapshots ids: [String]) {
        Self.locked {
            guard var cache = load(jobID) else { return }
            for id in ids { cache.snapshots[id] = nil }
            save(cache, for: jobID)
        }
    }

    /// How often garbage is collected when nothing presses (RepoMaintenance).
    static let collectionInterval: TimeInterval = 86_400

    /// Garbage was last collected at least `collectionInterval` ago, or never.
    func collectionDue(_ jobID: UUID, now: Date) -> Bool {
        guard let last = load(jobID)?.lastCollection else { return true }
        return now.timeIntervalSince1970 - last >= Self.collectionInterval
    }

    /// Remember a collection (in the job's cache; none yet — no snapshot listed — keeps it due).
    func recordCollection(_ jobID: UUID, at time: Date) {
        Self.locked {
            guard var cache = load(jobID) else { return }
            cache.lastCollection = time.timeIntervalSince1970
            save(cache, for: jobID)
        }
    }

    /// Where the job's next encrypted pass starts, if a pass recorded it.
    func captureState(_ jobID: UUID) -> EncryptedCaptureState? {
        load(jobID)?.capture
    }

    /// Record where the next pass starts (in the job's cache; none yet — no snapshot listed — means the next
    /// pass walks everything, as it would anyway).
    func recordCapture(_ jobID: UUID, _ state: EncryptedCaptureState) {
        Self.locked {
            guard var cache = load(jobID) else { return }
            cache.capture = state
            save(cache, for: jobID)
        }
    }

    /// What the job's repo occupies, as last measured (the timeline's footprint; nil before any pass).
    func storedBytes(_ jobID: UUID) -> Int64? {
        load(jobID)?.storedBytes
    }

    /// Remember what the repo (`repo`: its identity) occupies now.
    func recordStoredBytes(_ jobID: UUID, repo: String, _ bytes: Int64) {
        update(jobID, repo: repo) { $0.storedBytes = bytes }
    }

    /// Forget a job's cache (its backups were removed).
    func forget(_ jobID: UUID) {
        Self.locked { try? FileManager.default.removeItem(at: file(for: jobID)) }
    }

    // MARK: - Cache

    private struct Cache: Codable {
        /// Hash of the repo's recovery key slot.
        let repo: String
        var snapshots: [String: RepoSnapshotSummary]
        /// When garbage was last collected (seconds since 1970).
        var lastCollection: Double?
        /// Where the next pass starts.
        var capture: EncryptedCaptureState?
        /// What the repo's packs occupy (bytes), as last measured — after a pass, or after room was made.
        var storedBytes: Int64?
    }

    private func file(for jobID: UUID) -> URL {
        directory.appendingPathComponent("\(jobID.uuidString).json")
    }

    private func load(_ jobID: UUID) -> Cache? {
        guard let data = try? Data(contentsOf: file(for: jobID)) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    /// Load, change and save a job's cache as one step against every other writer in the process.
    private func update(_ jobID: UUID, repo: String, _ change: (inout Cache) -> Void) {
        Self.locked {
            var cache = load(jobID).flatMap { $0.repo == repo ? $0 : nil } ?? Cache(repo: repo, snapshots: [:])
            change(&cache)
            save(cache, for: jobID)
        }
    }

    /// Caches are read and written by every runner and by the timeline's readers: one at a time.
    private static let fileLock = NSLock()

    private static func locked<T>(_ body: () throws -> T) rethrows -> T {
        fileLock.lock()
        defer { fileLock.unlock() }
        return try body()
    }

    /// Best effort: without it the timeline is only decrypted again.
    private func save(_ cache: Cache, for jobID: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: file(for: jobID), options: .atomic)
    }

    /// What tells one repo from another: its recovery key slot (a fresh key per repo).
    static func identity(of backend: Backend) async throws -> String {
        let slot = try await backend.get(key: RepoManager.slotKey("recovery"))
        return SHA256.hash(data: slot).map { String(format: "%02x", $0) }.joined()
    }
}
