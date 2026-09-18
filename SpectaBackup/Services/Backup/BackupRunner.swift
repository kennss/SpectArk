//
//  @file        BackupRunner.swift
//  @description Actor that executes backup work off the main actor and serializes all I/O on a job's
//               destination. Plaintext jobs run the history engine (CaptureEngine) — at the destination,
//               or inside the attached sparsebundle for NAS shares — after seeding it once from the newest
//               1.1.x snapshot, then apply retention to the whole timeline. Encrypted jobs run the
//               DedupEngine. Also serves the timeline, restore, and plaintext→encrypted migration.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Being an actor, work runs serialized; the heavy capture loop is synchronous, so it holds the actor
//    for the duration (one pass at a time — correct for avoiding concurrent destination writes, and what
//    HistoryReader/HistoryMaterializer rely on: nothing moves a file in current/ while they read).
//  - Legacy (1.1.x) snapshot trees are no longer written. They stay browsable and restorable, are thinned
//    together with the checkpoints on one timeline, and `.inprogress-*` partials of the old engine are
//    discarded (nothing resumes them any more).
//  - NAS jobs (sparsebundle strategy) keep their history inside the image, which is attached only for a
//    pass; their timeline and restore need the same attach wrapper (TODO), so `history(for:)` sees only
//    what lives at the destination itself.
//

import Foundation

enum EncryptedBackupError: Error, CustomStringConvertible {
    case passwordMissing
    case repoNotInitialized
    var description: String {
        switch self {
        case .passwordMissing: return "no repo password in Keychain for this encrypted job"
        case .repoNotInitialized: return "encrypted repo not initialized — enable encryption in Settings first"
        }
    }
}

enum RestoreError: Error, CustomStringConvertible {
    case notBrowsable
    var description: String { "this restore point can only be restored as a whole" }
}

actor BackupRunner {

    struct PassResult: Sendable {
        /// When the pass finished: the backup matched the source as of this moment.
        let finishedAt: Date
        let capabilities: DestinationCapabilities
        /// Files the pass left for later because they were still being written (quiet window).
        let deferredCount: Int
    }

    /// Run one backup pass for a job. `forceCheckpoint`: the pass was requested (Back Up Now, a due
    /// schedule, a new job) and ends with a checkpoint — an explicit restore point.
    func run(job: BackupJob,
             quietWindow: TimeInterval = 0,
             forceCheckpoint: Bool = false,
             progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> PassResult {
        if job.encryptionEnabled {
            return try await runEncrypted(job: job, progress: progress)
        }
        let caps = try DestinationProbe.probe(destination: job.destination)
        if caps.strategy == .sparsebundle {
            let attachment = try SparsebundleManager.attach(at: job.destination,
                                                            maxSizeBytes: job.retention.maxTotalBytes,
                                                            readOnly: false)
            defer { SparsebundleManager.detach(attachment) }
            let jobRoot = attachment.mountPoint.appendingPathComponent("SpectaBackup/\(job.id.uuidString)",
                                                                      isDirectory: true)
            return try await runHistoryPass(job: job, jobRoot: jobRoot, capabilities: caps, quietWindow: quietWindow,
                                            forceCheckpoint: forceCheckpoint, progress: progress)
        }
        return try await runHistoryPass(job: job, jobRoot: Self.jobRoot(for: job), capabilities: caps,
                                        quietWindow: quietWindow, forceCheckpoint: forceCheckpoint,
                                        progress: progress)
    }

    /// One history-engine pass at `jobRoot`: seed from the newest legacy snapshot (once), capture, then
    /// apply retention to the job's whole timeline.
    private func runHistoryPass(job: BackupJob, jobRoot: URL, capabilities: DestinationCapabilities,
                                quietWindow: TimeInterval, forceCheckpoint: Bool,
                                progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> PassResult {
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        let layout = HistoryLayout(jobRoot: jobRoot)
        let legacy = Self.legacyCatalog(at: jobRoot)
        if let legacy, let newest = try? await legacy.latestComplete(jobID: job.id), Self.isPlaintext(newest) {
            // An optimisation only: if it fails, the first pass copies the whole source instead.
            _ = try? HistorySeeder(layout: layout).seedIfPristine(
                from: jobRoot.appendingPathComponent("snapshots/\(newest.dirName)", isDirectory: true),
                sourceNames: job.sources.map(\.lastPathComponent), exclusions: BackupExclusions(job: job))
        }
        discardLegacyPartials(in: jobRoot)

        let outcome = try CaptureEngine(layout: layout).runPass(job: job, quietWindow: quietWindow,
                                                                forceCheckpoint: forceCheckpoint,
                                                                progress: progress)
        await applyRetention(job: job, layout: layout, jobRoot: jobRoot, legacy: legacy)
        return PassResult(finishedAt: outcome.finishedAt, capabilities: capabilities,
                          deferredCount: outcome.deferredCount)
    }

    /// Encrypted path: unlock the dedup repo and run DedupEngine, recording the snapshot in the legacy
    /// catalog so the timeline stays unified. The repo is created in Settings (where the recovery key can
    /// be shown), not here. Encrypted-repo retention (prune/GC) is a follow-up.
    private func runEncrypted(job: BackupJob,
                              progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> PassResult {
        guard let password = KeychainStorage.password(for: job.id) else {
            throw EncryptedBackupError.passwordMissing
        }
        let caps = try DestinationProbe.probe(destination: job.destination)
        let jobRoot = Self.jobRoot(for: job)
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        let backend = try LocalBackend(root: jobRoot.appendingPathComponent("repo", isDirectory: true))
        guard await RepoManager.isInitialized(backend) else {
            throw EncryptedBackupError.repoNotInitialized
        }

        let (config, keys) = try await RepoManager.unlock(backend: backend, password: Data(password.utf8))
        let engine = DedupEngine(backend: backend, keys: keys, chunker: config.chunker)
        try await engine.open()   // load the blob index so existing blobs are deduplicated, not re-stored

        let catalog = try CatalogStore(path: jobRoot.appendingPathComponent("catalog.sqlite").path)
        let now = Date()
        let seqId = try await catalog.beginSnapshot(jobID: job.id, timestamp: now, sourceSnapshotID: nil)
        let snapshotID = "enc-\(seqId)"
        let start = Date()
        do {
            let snap = try await engine.backUp(sources: job.sources, snapshotID: snapshotID,
                                               now: now.timeIntervalSince1970,
                                               exclusions: BackupExclusions(job: job),
                                               toleratingVanishedEntries: true)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            try await catalog.markComplete(seqId: seqId, dirName: snapshotID, fileCount: snap.fileCount,
                                           logicalBytes: Int64(snap.totalBytes), addedBlocks: 0, durationMs: durationMs)
            return PassResult(finishedAt: Date(), capabilities: caps, deferredCount: 0)   // no quiet window here
        } catch {
            try? await catalog.markFailed(seqId: seqId)
            throw error
        }
    }

    // MARK: - Retention

    /// Thin the job's timeline — legacy snapshots, then checkpoints — with its policy, measuring free
    /// space on the volume that holds the backups (the sparsebundle's own volume when applicable).
    private func applyRetention(job: BackupJob, layout: HistoryLayout, jobRoot: URL, legacy: CatalogStore?) async {
        let snapshots = ((try? await legacy?.snapshots(jobID: job.id)) ?? []).filter(Self.isPlaintext)
        let free = (try? Syscalls.volumeInfo(at: jobRoot.path))?.freeBytes ?? Int64.max
        guard let result = try? HistoryMaintenance(layout: layout).applyRetention(
            policy: job.retention,
            legacy: snapshots.map { .init(id: $0.seqId, time: $0.timestamp, bytes: $0.addedBlocks * 512) },
            freeBytes: free, now: Date()) else { return }
        let snapshotsDir = jobRoot.appendingPathComponent("snapshots", isDirectory: true)
        for snapshot in snapshots where result.legacySnapshotsToDelete.contains(snapshot.seqId) {
            deleteSnapshotTree(snapshotsDir.appendingPathComponent(snapshot.dirName, isDirectory: true))
            try? await legacy?.deleteSnapshot(seqId: snapshot.seqId)
        }
    }

    /// Partial trees of the 1.1.x engine: only it could resume them, and it no longer runs.
    private func discardLegacyPartials(in jobRoot: URL) {
        let snapshotsDir = jobRoot.appendingPathComponent("snapshots", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path)) ?? []
        for name in names where name.hasPrefix(".inprogress-") {
            deleteSnapshotTree(snapshotsDir.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// Remove a snapshot directory. Fast path: just delete it — most backups have no BSD immutable
    /// flags, so we avoid walking every file to clear uchg first (that walk is brutally slow on huge
    /// trees over an external/NAS volume and was leaving Remove&Delete unable to free the disk). Only
    /// if the delete is blocked (e.g. uchg flags) do we clear flags and retry.
    private func deleteSnapshotTree(_ dir: URL) {
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        if (try? FileManager.default.removeItem(at: dir)) != nil { return }
        try? Syscalls.clearUserFlags(dir.path)
        try? FileWalker.walk(root: dir, exclusions: .includeEverything) { entry in
            try? Syscalls.clearUserFlags(entry.url.path)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Delete ALL on-disk data for a job (history, snapshots, encrypted repo, catalogs) — used when the
    /// user removes a job and chooses to delete its backups too.
    func deleteJobData(for job: BackupJob) {
        deleteSnapshotTree(Self.jobRoot(for: job))
    }

    // MARK: - Timeline

    /// The job's restore points (newest first), when it was last backed up, and what its backups occupy.
    func history(for job: BackupJob) async throws -> BackupHistory {
        let jobRoot = Self.jobRoot(for: job)
        var history = BackupHistory()

        if let legacy = Self.legacyCatalog(at: jobRoot) {
            for snapshot in try await legacy.snapshots(jobID: job.id) where snapshot.status == .complete {
                let source: RestorePoint.Source = Self.isPlaintext(snapshot)
                    ? .legacySnapshot(dirName: snapshot.dirName) : .encryptedSnapshot(id: snapshot.dirName)
                history.points.append(RestorePoint(source: source, time: snapshot.timestamp,
                                                   fileCount: Int64(snapshot.fileCount), bytes: snapshot.logicalBytes))
                history.storageBytes += snapshot.addedBlocks * 512
                history.lastBackup = max(history.lastBackup ?? snapshot.timestamp, snapshot.timestamp)
            }
        }

        let layout = HistoryLayout(jobRoot: jobRoot)
        if FileManager.default.fileExists(atPath: layout.catalogPath) {
            let store = try HistoryStore(path: layout.catalogPath)
            for checkpoint in try store.checkpoints() {
                history.points.append(RestorePoint(source: .checkpoint(seq: checkpoint.seq), time: checkpoint.time,
                                                   fileCount: checkpoint.files, bytes: checkpoint.bytes))
            }
            let totals = try store.currentTotals()
            if let end = try store.lastPassEnd() {
                if try store.hasUnsealedChanges() {
                    history.points.append(RestorePoint(source: .latest, time: end,
                                                       fileCount: totals.files, bytes: totals.bytes))
                }
                history.lastBackup = max(history.lastBackup ?? end, end)
            }
            history.storageBytes += totals.bytes + (try store.versionBytes())
        }
        // Newest first; equal times (a fast pass) fall back to the order they were recorded in.
        history.points.sort { lhs, rhs in
            lhs.time != rhs.time ? lhs.time > rhs.time : Self.recordOrder(lhs) > Self.recordOrder(rhs)
        }
        return history
    }

    /// Remove orphaned `inProgress` catalog rows left by crashed/killed passes, so they don't linger
    /// as "0 files" snapshots. Called at launch. Only rows begun before `cutoff` (the app's launch) are
    /// orphans: a pass of this run may already be in progress, and deleting its row would leave its
    /// published snapshot out of the catalog.
    func cleanupIncompleteSnapshots(for job: BackupJob, startedBefore cutoff: Date) async {
        guard let catalog = Self.legacyCatalog(at: Self.jobRoot(for: job)),
              let snaps = try? await catalog.snapshots(jobID: job.id) else { return }
        for snap in snaps where snap.status == .inProgress && snap.timestamp < cutoff {
            try? await catalog.deleteSnapshot(seqId: snap.seqId)
        }
    }

    /// Free space at the destination, for the menu-bar gauge.
    func destinationFreeBytes(for job: BackupJob) -> Int64? {
        (try? Syscalls.volumeInfo(at: job.destination.path))?.freeBytes
    }

    // MARK: - Browse and restore

    /// Lists a browsable restore point item by item. Reading the catalog or a legacy tree never
    /// conflicts with a running pass, so this is usable from any thread.
    nonisolated func browser(job: BackupJob, point: RestorePoint, sourceName: String) -> (any RestoreBrowser)? {
        let jobRoot = Self.jobRoot(for: job)
        switch point.source {
        case let .legacySnapshot(dirName):
            return SnapshotBrowser(sourceRoot: jobRoot.appendingPathComponent("snapshots/\(dirName)/\(sourceName)",
                                                                             isDirectory: true))
        case let .checkpoint(seq):
            return HistoryBrowser(reader: HistoryReader(layout: HistoryLayout(jobRoot: jobRoot)),
                                  sourceName: sourceName, seq: seq)
        case .latest:
            return HistoryBrowser(reader: HistoryReader(layout: HistoryLayout(jobRoot: jobRoot)),
                                  sourceName: sourceName, seq: nil)
        case .encryptedSnapshot:
            return nil
        }
    }

    /// Restore selected items (paths relative to the source folder) of a restore point into `target`.
    func restore(job: BackupJob,
                 point: RestorePoint,
                 sourceName: String,
                 relPaths: [String],
                 to target: URL,
                 conflict: RestoreEngine.ConflictPolicy,
                 progress: @escaping @Sendable (Int) -> Void) async throws -> RestoreEngine.Outcome {
        let jobRoot = Self.jobRoot(for: job)
        switch point.source {
        case let .legacySnapshot(dirName):
            let sourceRoot = jobRoot.appendingPathComponent("snapshots/\(dirName)/\(sourceName)", isDirectory: true)
            return try RestoreEngine().restore(snapshotSourceRoot: sourceRoot, relPaths: relPaths, to: target,
                                               conflict: conflict, progress: progress)
        case let .checkpoint(seq):
            return try HistoryReader(layout: HistoryLayout(jobRoot: jobRoot))
                .restore(sourceName: sourceName, relPaths: relPaths, at: seq, to: target, conflict: conflict,
                         progress: progress)
        case .latest:
            return try HistoryReader(layout: HistoryLayout(jobRoot: jobRoot))
                .restore(sourceName: sourceName, relPaths: relPaths, at: nil, to: target, conflict: conflict,
                         progress: progress)
        case .encryptedSnapshot:
            throw RestoreError.notBrowsable
        }
    }

    /// Restore an entire encrypted snapshot into a target folder (each backed-up source becomes a
    /// subfolder). File-by-file selection for encrypted repos is a follow-up.
    func restoreEncrypted(job: BackupJob, snapshotID: String, to target: URL) async throws {
        guard let password = KeychainStorage.password(for: job.id) else {
            throw EncryptedBackupError.passwordMissing
        }
        let backend = try LocalBackend(root: Self.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true))
        let (config, keys) = try await RepoManager.unlock(backend: backend, password: Data(password.utf8))
        let engine = DedupEngine(backend: backend, keys: keys, chunker: config.chunker)
        try await engine.restore(snapshotID: snapshotID, to: target)
    }

    // MARK: - Plaintext → encrypted migration

    /// A plaintext restore point to re-encrypt: a legacy snapshot tree, or a state of the history engine
    /// (a checkpoint, or current/ when it holds changes no checkpoint has).
    private enum PlaintextPoint {
        case legacy(SnapshotRecord)
        case history(seq: Int64?, time: Date)
    }

    private func plaintextPoints(for job: BackupJob) async -> [PlaintextPoint] {
        let jobRoot = Self.jobRoot(for: job)
        var points: [PlaintextPoint] = []
        if let catalog = Self.legacyCatalog(at: jobRoot), let snaps = try? await catalog.snapshots(jobID: job.id) {
            points += snaps.filter(Self.isPlaintext).sorted { $0.seqId < $1.seqId }.map(PlaintextPoint.legacy)
        }
        let layout = HistoryLayout(jobRoot: jobRoot)
        if FileManager.default.fileExists(atPath: layout.catalogPath), let store = try? HistoryStore(path: layout.catalogPath) {
            points += ((try? store.checkpoints()) ?? []).map { .history(seq: $0.seq, time: $0.time) }
            if (try? store.hasUnsealedChanges()) == true, let end = try? store.lastPassEnd() {
                points.append(.history(seq: nil, time: end))
            }
        }
        return points
    }

    /// Number of plaintext restore points (not yet migrated) for a job.
    func plaintextSnapshotCount(for job: BackupJob) async -> Int {
        await plaintextPoints(for: job).count
    }

    /// Re-encrypt EVERY plaintext restore point into the repo (preserving each one's time), oldest first,
    /// then — only after all succeed — delete the plaintext: legacy trees and their catalog rows, and the
    /// history engine's current/, versions/ and catalog. If any point fails, it aborts and the plaintext
    /// is left completely intact (no data loss, no half-deleted state).
    func migrateToEncrypted(job: BackupJob, progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        guard let password = KeychainStorage.password(for: job.id) else {
            throw EncryptedBackupError.passwordMissing
        }
        let points = await plaintextPoints(for: job)
        guard !points.isEmpty else { return }
        let jobRoot = Self.jobRoot(for: job)
        let snapshotsDir = jobRoot.appendingPathComponent("snapshots", isDirectory: true)
        let catalog = try CatalogStore(path: jobRoot.appendingPathComponent("catalog.sqlite").path)
        let layout = HistoryLayout(jobRoot: jobRoot)
        let sourceNames = job.sources.map(\.lastPathComponent)

        // Trees materialised by an earlier, interrupted migration.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: jobRoot.path)) ?? []
        where name.hasPrefix(".materialize-") {
            deleteSnapshotTree(jobRoot.appendingPathComponent(name, isDirectory: true))
        }

        let backend = try LocalBackend(root: jobRoot.appendingPathComponent("repo", isDirectory: true))
        let (config, keys) = try await RepoManager.unlock(backend: backend, password: Data(password.utf8))
        let engine = DedupEngine(backend: backend, keys: keys, chunker: config.chunker)
        try await engine.open()   // load the blob index up front so restore points dedup against each other

        // 1) Re-encrypt every point. A failure throws → plaintext stays untouched.
        for (index, point) in points.enumerated() {
            progress(index, points.count)
            let time: Date
            let roots: [URL]
            var scratch: URL?
            switch point {
            case let .legacy(snap):
                time = snap.timestamp
                let snapDir = snapshotsDir.appendingPathComponent(snap.dirName, isDirectory: true)
                roots = sourceNames.map { snapDir.appendingPathComponent($0, isDirectory: true) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            case let .history(seq, pointTime):
                time = pointTime
                let tree = jobRoot.appendingPathComponent(".materialize-\(UUID().uuidString)", isDirectory: true)
                scratch = tree
                roots = try HistoryMaterializer(layout: layout).materialize(sourceNames: sourceNames, at: seq, into: tree)
            }
            defer { if let scratch { deleteSnapshotTree(scratch) } }
            let newSeqId = try await catalog.beginSnapshot(jobID: job.id, timestamp: time, sourceSnapshotID: nil)
            let encID = "enc-\(newSeqId)"
            do {
                // Re-encrypt the recorded state exactly — no exclusions.
                let result = try await engine.backUp(sources: roots, snapshotID: encID,
                                                     now: time.timeIntervalSince1970,
                                                     exclusions: .includeEverything,
                                                     toleratingVanishedEntries: false)
                try await catalog.markComplete(seqId: newSeqId, dirName: encID, fileCount: result.fileCount,
                                               logicalBytes: Int64(result.totalBytes), addedBlocks: 0, durationMs: 0)
            } catch {
                try? await catalog.markFailed(seqId: newSeqId)
                throw error
            }
        }
        progress(points.count, points.count)

        // 2) Everything is safely re-encrypted → now remove the plaintext.
        for case let .legacy(snap) in points {
            deleteSnapshotTree(snapshotsDir.appendingPathComponent(snap.dirName, isDirectory: true))
            try? await catalog.deleteSnapshot(seqId: snap.seqId)
        }
        if points.contains(where: { if case .history = $0 { return true } else { return false } }) {
            deleteSnapshotTree(URL(fileURLWithPath: layout.currentRoot, isDirectory: true))
            deleteSnapshotTree(URL(fileURLWithPath: layout.versionsRoot, isDirectory: true))
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: layout.catalogPath + suffix)
            }
        }
    }

    // MARK: - Helpers

    /// Recording order across kinds: legacy and encrypted snapshots, then checkpoints, then the latest state.
    private static func recordOrder(_ point: RestorePoint) -> (Int, Int64) {
        switch point.source {
        case .legacySnapshot, .encryptedSnapshot: return (0, 0)
        case let .checkpoint(seq): return (1, seq)
        case .latest: return (2, 0)
        }
    }

    /// A complete, non-encrypted legacy snapshot (encrypted ones use an "enc-" dirName).
    private static func isPlaintext(_ snap: SnapshotRecord) -> Bool {
        snap.status == .complete && !snap.dirName.isEmpty && !snap.dirName.hasPrefix("enc-")
    }

    /// The 1.1.x catalog of a job root, when it has one (it also records encrypted snapshots).
    private static func legacyCatalog(at jobRoot: URL) -> CatalogStore? {
        let path = jobRoot.appendingPathComponent("catalog.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? CatalogStore(path: path)
    }

    static func jobRoot(for job: BackupJob) -> URL {
        job.destination.appendingPathComponent("SpectaBackup/\(job.id.uuidString)", isDirectory: true)
    }
}
