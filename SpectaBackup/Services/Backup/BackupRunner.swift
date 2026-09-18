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
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - One runner per destination (BackupCoordinator): jobs on one disk or NAS image take turns, jobs on
//    different destinations run side by side. The heavy capture loop is synchronous, so it holds its
//    runner for the duration — what HistoryReader/HistoryMaterializer rely on: nothing moves a file in
//    current/ while they read. The scheduler keeps a job's own passes and migration from overlapping.
//  - Legacy (1.1.x) snapshot trees are no longer written. They stay browsable and restorable, are thinned
//    together with the checkpoints on one timeline, and `.inprogress-*` partials of the old engine are
//    discarded (nothing resumes them any more).
//  - NAS jobs (sparsebundle strategy) keep their plaintext backups inside the destination's image. Every
//    use — a pass, the timeline, a restore, a browsing session, a migration — holds it attached through
//    the destination's ImageLease (`withPlaintextRoot`). An encrypted job's repo and catalog stay in the
//    job root on the share itself.
//  - A job is an image job when it has no direct layout and the image exists (or the destination needs
//    one, for its first pass) — read from disk, so passes and reads always agree on where its backups are.
//  - Deleting inside an image frees nothing on the share: removing a job's backups (or migrating them into
//    the encrypted repo) removes the image when no other job's backups are in it, or compacts it.
//

import Darwin
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

    // MARK: - One operation at a time

    /// Operations on this destination take turns from start to end. The actor alone would interleave them
    /// at every `await`: two jobs on one NAS would both attach its image, a restore could read a tree a
    /// retention run is deleting, launch cleanup could drop the row a migration has just begun.
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func exclusively<T>(_ body: () async throws -> T) async rethrows -> T {
        if occupied {
            await withCheckedContinuation { waiting.append($0) }   // handed over by the one finishing
        } else {
            occupied = true
        }
        defer {
            if waiting.isEmpty { occupied = false } else { waiting.removeFirst().resume() }
        }
        return try await body()
    }

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
        try await exclusively {
            try await runPass(job: job, quietWindow: quietWindow, forceCheckpoint: forceCheckpoint, progress: progress)
        }
    }

    private func runPass(job: BackupJob, quietWindow: TimeInterval, forceCheckpoint: Bool,
                         progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> PassResult {
        if job.encryptionEnabled {
            return try await runEncrypted(job: job, progress: progress)
        }
        let caps = try DestinationProbe.probe(destination: job.destination)
        // A job that 1.1.x already backed up directly onto this volume stays there (an NFS share with
        // hard links qualified then); moving its history into an image would strand what is there.
        let inImage = try Self.usesImage(job) || (caps.strategy == .sparsebundle && !(try Self.hasDirectLayout(job)))
        return try await withPlaintextRoot(job, inImage: inImage, create: true, writes: true) { jobRoot in
            try await runHistoryPass(job: job, jobRoot: jobRoot, inImage: inImage, capabilities: caps,
                                     quietWindow: quietWindow, forceCheckpoint: forceCheckpoint, progress: progress)
        }
    }

    /// One history-engine pass at `jobRoot`: seed from the newest legacy snapshot (once), capture, then
    /// apply retention to the job's whole timeline.
    private func runHistoryPass(job: BackupJob, jobRoot: URL, inImage: Bool, capabilities: DestinationCapabilities,
                                quietWindow: TimeInterval, forceCheckpoint: Bool,
                                progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> PassResult {
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        sweepScratch(in: jobRoot)
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
        // Inside a NAS image, dropped trees must be gone before it is detached; elsewhere they go in the
        // background (TreeReaper) so their deletion holds up no pass.
        await applyRetention(job: job, layout: layout, jobRoot: jobRoot, legacy: legacy, reapInBackground: !inImage)
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
        sweepScratch(in: jobRoot)   // the remains of an interrupted migration
        let backend = try LocalBackend(root: jobRoot.appendingPathComponent("repo", isDirectory: true))
        guard await RepoManager.isInitialized(backend) else {
            throw EncryptedBackupError.repoNotInitialized
        }

        let (config, keys) = try await RepoManager.unlock(backend: backend, password: Data(password.utf8))
        let engine = DedupEngine(backend: backend, keys: keys, chunker: config.chunker)
        try await engine.open()   // load the blob index so existing blobs are deduplicated, not re-stored

        let catalog = try CatalogStore(path: jobRoot.appendingPathComponent("catalog.sqlite").path)
        await finishLegacyDeletions(in: jobRoot.appendingPathComponent("snapshots", isDirectory: true), job: job,
                                    legacy: catalog, reapInBackground: true)
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
    private func applyRetention(job: BackupJob, layout: HistoryLayout, jobRoot: URL, legacy: CatalogStore?,
                                reapInBackground: Bool) async {
        let snapshotsDir = jobRoot.appendingPathComponent("snapshots", isDirectory: true)
        if let legacy {
            await reconcileLegacyTrees(in: snapshotsDir, job: job, legacy: legacy, reapInBackground: reapInBackground)
        }
        let snapshots = ((try? await legacy?.snapshots(jobID: job.id)) ?? []).filter(Self.isPlaintext)
        // Space the reaper is still freeing counts as free, or a free-space rule would drop restore point
        // after restore point for bytes already on their way back.
        let reaping = reapInBackground ? TreeReaper.shared.pendingBytes(under: jobRoot.path) : 0
        let free = (try? Syscalls.volumeInfo(at: jobRoot.path)).map { $0.freeBytes + reaping } ?? Int64.max
        guard let result = try? HistoryMaintenance(layout: layout).applyRetention(
            policy: job.retention,
            legacy: snapshots.map { .init(id: $0.seqId, time: $0.timestamp, bytes: $0.addedBlocks * 512) },
            freeBytes: free, now: Date()), let legacy else { return }
        for snapshot in snapshots where result.legacySnapshotsToDelete.contains(snapshot.seqId) {
            await deleteLegacySnapshot(snapshot, in: snapshotsDir, legacy: legacy, reapInBackground: reapInBackground)
        }
    }

    private static let deletingPrefix = ".deleting-"

    /// Delete a legacy snapshot the policy dropped: its tree is renamed to `.deleting-<name>` (instant),
    /// then its row goes, then the tree. Whatever an interruption leaves is recognisable — a `.deleting-`
    /// tree is always garbage — so nothing but retention ever decides that a snapshot goes.
    private func deleteLegacySnapshot(_ snapshot: SnapshotRecord, in snapshotsDir: URL, legacy: CatalogStore,
                                      reapInBackground: Bool) async {
        let tree = snapshotsDir.appendingPathComponent(snapshot.dirName, isDirectory: true)
        let doomed = snapshotsDir.appendingPathComponent(Self.deletingPrefix + snapshot.dirName, isDirectory: true)
        if FileManager.default.fileExists(atPath: tree.path) {
            guard (try? Syscalls.atomicRename(tree.path, to: doomed.path)) != nil else { return }
        }
        guard (try? await legacy.deleteSnapshot(seqId: snapshot.seqId)) != nil else { return }
        dispose(doomed, bytes: snapshot.addedBlocks * 512, inBackground: reapInBackground)
    }

    private func dispose(_ tree: URL, bytes: Int64, inBackground: Bool) {
        if inBackground { TreeReaper.shared.reap(tree, bytes: bytes) } else { deleteSnapshotTree(tree) }
    }

    /// `.deleting-` trees an interruption left behind: their rows (if still there) and trees go.
    private func finishLegacyDeletions(in snapshotsDir: URL, job: BackupJob, legacy: CatalogStore,
                                       reapInBackground: Bool) async {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path)) ?? [])
            .filter { $0.hasPrefix(Self.deletingPrefix) }
        guard !names.isEmpty, let rows = try? await legacy.snapshots(jobID: job.id) else { return }
        for name in names {
            let dirName = String(name.dropFirst(Self.deletingPrefix.count))
            var bytes: Int64 = 0
            if let row = rows.first(where: { $0.dirName == dirName }) {
                guard (try? await legacy.deleteSnapshot(seqId: row.seqId)) != nil else { continue }
                bytes = row.addedBlocks * 512
            }
            dispose(snapshotsDir.appendingPathComponent(name, isDirectory: true), bytes: bytes,
                    inBackground: reapInBackground)
        }
    }

    /// Settle what an interruption or an old bug left in snapshots/: finish deletions (`.deleting-`
    /// trees, and their rows if still there), and put back a complete tree that lost its row — 1.1.x launch
    /// cleanup could drop the row of a snapshot it was still publishing. A tree without its COMPLETE marker
    /// is no restore point to judge; it is left alone.
    private func reconcileLegacyTrees(in snapshotsDir: URL, job: BackupJob, legacy: CatalogStore,
                                      reapInBackground: Bool) async {
        guard let rows = try? await legacy.snapshots(jobID: job.id) else { return }
        let byDir = Dictionary(rows.filter { !$0.dirName.isEmpty }.map { ($0.dirName, $0) }, uniquingKeysWith: { a, _ in a })
        let completeSeqs = Set(rows.filter { $0.status == .complete }.map(\.seqId))
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path)) ?? []).sorted() {
            let tree = snapshotsDir.appendingPathComponent(name, isDirectory: true)
            if name.hasPrefix(Self.deletingPrefix) {
                var bytes: Int64 = 0
                if let row = byDir[String(name.dropFirst(Self.deletingPrefix.count))] {
                    guard (try? await legacy.deleteSnapshot(seqId: row.seqId)) != nil else { continue }
                    bytes = row.addedBlocks * 512
                }
                dispose(tree, bytes: bytes, inBackground: reapInBackground)
                continue
            }
            // A seqId another complete snapshot holds is no lost row (and is not walked on every pass).
            guard !name.hasPrefix("."), byDir[name] == nil,
                  let seqId = name.split(separator: "-").last.flatMap({ Int64($0) }),
                  !completeSeqs.contains(seqId) else { continue }
            var st = Darwin.stat()
            guard lstat(tree.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  lstat(tree.appendingPathComponent(SnapshotBrowser.completeMarker).path, &st) == 0 else { continue }
            // The marker was written as the snapshot was published: its time is the snapshot's.
            let published = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            var files = 0
            var bytes: Int64 = 0
            try? FileWalker.walk(root: tree, exclusions: .includeEverything) { entry in
                guard !entry.isDirectory, entry.relativePath != SnapshotBrowser.completeMarker else { return }
                files += 1
                bytes += entry.size
            }
            try? await legacy.adoptSnapshot(seqId: seqId, jobID: job.id, timestamp: published, dirName: name,
                                            fileCount: files, logicalBytes: bytes)
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
        try? TreeRemoval.remove(dir.path)
    }

    /// Delete ALL on-disk data for a job (history, snapshots, encrypted repo, catalogs) — used when the
    /// user removes a job and chooses to delete its backups too.
    func deleteJobData(for job: BackupJob) async {
        await exclusively {
            // Decided before the job root goes (it decides); when the share cannot tell, look in the image too.
            let inImage = (try? Self.usesImage(job)) ?? true
            deleteSnapshotTree(Self.jobRoot(for: job))
            if inImage { removeFromImage(job) }
        }
    }

    /// Remove the job's folder from its destination's image, then have the space given back to the share
    /// once nothing uses the image: the image is removed if no job's backups are left in it, compacted
    /// otherwise (ImageLease decides, under its lock). Nothing freed, nothing reclaimed.
    private func removeFromImage(_ job: BackupJob) {
        let lease = ImageLease.shared(for: job.destination)
        guard let mount = try? lease.acquire(create: false) else { return }
        let folder = Self.jobRoot(for: job, inImageAt: mount)
        if (try? Syscalls.exists(folder.path)) != false {
            deleteSnapshotTree(folder)
            lease.requestReclaim()
        }
        lease.release(flush: true)
    }

    // MARK: - Timeline

    /// The job's restore points (newest first), when it was last backed up, and what its backups occupy.
    /// Throws when the destination is not reachable (an unplugged disk, an unmounted share) or a NAS job's
    /// image cannot be attached: that is no empty timeline, and what is shown stays.
    func history(for job: BackupJob) async throws -> BackupHistory {
        guard FileManager.default.fileExists(atPath: job.destination.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: job.destination.path])
        }
        // The job root on the destination: all of a direct job's backups, an encrypted job's snapshots.
        var history = await backups(at: Self.jobRoot(for: job), of: job)
        if try Self.usesImage(job) {
            // A NAS job's plaintext backups, in the image.
            let inImage = try await withPlaintextRoot(job, inImage: true, writes: false) { root in
                await backups(at: root, of: job)
            }
            history.points += inImage.points
            history.storageBytes += inImage.storageBytes
            history.lastBackup = [history.lastBackup, inImage.lastBackup].compactMap { $0 }.max()
        }
        // Newest first; equal times (a fast pass) fall back to the order they were recorded in.
        history.points.sort { lhs, rhs in
            lhs.time != rhs.time ? lhs.time > rhs.time : Self.recordOrder(lhs) > Self.recordOrder(rhs)
        }
        return history
    }

    /// The restore points and footprint of the backups kept at `jobRoot` (unsorted).
    private func backups(at jobRoot: URL, of job: BackupJob) async -> BackupHistory {
        var history = BackupHistory()
        // Each part on its own: a damaged catalog must not hide the other kind of restore point.
        var plaintextLegacy = 0
        if let legacy = Self.legacyCatalog(at: jobRoot), let snapshots = try? await legacy.snapshots(jobID: job.id) {
            for snapshot in snapshots where snapshot.status == .complete {
                if Self.isPlaintext(snapshot) { plaintextLegacy += 1 }
                let source: RestorePoint.Source = Self.isPlaintext(snapshot)
                    ? .legacySnapshot(dirName: snapshot.dirName) : .encryptedSnapshot(id: snapshot.dirName)
                history.points.append(RestorePoint(source: source, time: snapshot.timestamp,
                                                   fileCount: Int64(snapshot.fileCount), bytes: snapshot.logicalBytes))
                history.storageBytes += snapshot.addedBlocks * 512
                history.lastBackup = max(history.lastBackup ?? snapshot.timestamp, snapshot.timestamp)
            }
        }
        // An unreadable history catalog still leaves the legacy restore points listed.
        try? addHistoryEngine(at: HistoryLayout(jobRoot: jobRoot), to: &history, sharesWithLegacy: plaintextLegacy > 0)
        return history
    }

    /// The history engine's restore points and footprint at `layout`, when it has a catalog.
    private func addHistoryEngine(at layout: HistoryLayout, to history: inout BackupHistory,
                                  sharesWithLegacy: Bool) throws {
        guard FileManager.default.fileExists(atPath: layout.catalogPath) else { return }
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
        // Seeded items share their blocks with the legacy snapshots, which are counted already.
        let shared = sharesWithLegacy ? try store.seededBytes() : 0
        history.storageBytes += totals.bytes - shared + (try store.versionBytes())
    }

    /// Remove orphaned `inProgress` catalog rows left by crashed/killed passes, so they don't linger
    /// as "0 files" snapshots. Called at launch. Only rows begun before `cutoff` (the app's launch) are
    /// orphans: a pass of this run may already be in progress, and deleting its row would leave its
    /// published snapshot out of the catalog. Only the job root on the destination: rows are begun there
    /// (encrypted passes and migrations); a NAS image's catalog holds 1.1.x rows, whose unfinished ones
    /// never show, so launch attaches no image for this.
    func cleanupIncompleteSnapshots(for job: BackupJob, startedBefore cutoff: Date) async {
        await exclusively {
            guard let catalog = Self.legacyCatalog(at: Self.jobRoot(for: job)),
                  let snaps = try? await catalog.snapshots(jobID: job.id) else { return }
            for snap in snaps where snap.status == .inProgress && snap.timestamp < cutoff {
                try? await catalog.deleteSnapshot(seqId: snap.seqId)
            }
        }
    }

    /// Free space at the destination, for the menu-bar gauge.
    func destinationFreeBytes(for job: BackupJob) -> Int64? {
        (try? Syscalls.volumeInfo(at: job.destination.path))?.freeBytes
    }

    // MARK: - Browse and restore

    /// The job's backups opened for the restore UI. It holds a NAS job's image attached until
    /// `endBrowsing`; reading the catalog or a legacy tree never conflicts with a running pass, so browsing
    /// needs no turn on the runner.
    struct BrowseSession: Sendable {
        /// Where the job's plaintext backups are while the session is open.
        let plaintextRoot: URL
        fileprivate let lease: ImageLease?
    }

    /// Open the job's backups for browsing. Attaching a NAS job's image blocks: call off the main actor.
    static func beginBrowsing(job: BackupJob) throws -> BrowseSession {
        guard try usesImage(job) else { return BrowseSession(plaintextRoot: jobRoot(for: job), lease: nil) }
        let lease = ImageLease.shared(for: job.destination)
        let mount = try lease.acquire(create: false)
        return BrowseSession(plaintextRoot: jobRoot(for: job, inImageAt: mount), lease: lease)
    }

    /// Close a session from `beginBrowsing` (once).
    static func endBrowsing(_ session: BrowseSession) {
        session.lease?.release(flush: false)
    }

    /// Lists a browsable restore point of an open session item by item.
    static func browser(session: BrowseSession, point: RestorePoint, sourceName: String) -> (any RestoreBrowser)? {
        let root = session.plaintextRoot
        switch point.source {
        case let .legacySnapshot(dirName):
            return SnapshotBrowser(sourceRoot: root.appendingPathComponent("snapshots/\(dirName)/\(sourceName)",
                                                                          isDirectory: true))
        case let .checkpoint(seq):
            return HistoryBrowser(reader: HistoryReader(layout: HistoryLayout(jobRoot: root)),
                                  sourceName: sourceName, seq: seq)
        case .latest:
            return HistoryBrowser(reader: HistoryReader(layout: HistoryLayout(jobRoot: root)),
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
        try await exclusively {
            try await withPlaintextRoot(job, inImage: try Self.usesImage(job), writes: false) { root in
                try restoreNow(plaintextRoot: root, point: point, sourceName: sourceName, relPaths: relPaths,
                               to: target, conflict: conflict, progress: progress)
            }
        }
    }

    private func restoreNow(plaintextRoot: URL, point: RestorePoint, sourceName: String, relPaths: [String],
                            to target: URL, conflict: RestoreEngine.ConflictPolicy,
                            progress: @escaping @Sendable (Int) -> Void) throws -> RestoreEngine.Outcome {
        switch point.source {
        case let .legacySnapshot(dirName):
            let sourceRoot = plaintextRoot.appendingPathComponent("snapshots/\(dirName)/\(sourceName)", isDirectory: true)
            return try RestoreEngine().restore(snapshotSourceRoot: sourceRoot, relPaths: relPaths, to: target,
                                               conflict: conflict, progress: progress)
        case let .checkpoint(seq):
            return try HistoryReader(layout: HistoryLayout(jobRoot: plaintextRoot))
                .restore(sourceName: sourceName, relPaths: relPaths, at: seq, to: target, conflict: conflict,
                         progress: progress)
        case .latest:
            return try HistoryReader(layout: HistoryLayout(jobRoot: plaintextRoot))
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
        try await exclusively {
            let backend = try LocalBackend(root: Self.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true))
            let (config, keys) = try await RepoManager.unlock(backend: backend, password: Data(password.utf8))
            let engine = DedupEngine(backend: backend, keys: keys, chunker: config.chunker)
            try await engine.restore(snapshotID: snapshotID, to: target)
        }
    }

    // MARK: - Plaintext → encrypted migration

    /// A plaintext restore point to re-encrypt: a legacy snapshot tree, or a state of the history engine
    /// (a checkpoint, or current/ when it holds changes no checkpoint has).
    private enum PlaintextPoint {
        case legacy(SnapshotRecord)
        case history(seq: Int64?, time: Date)

        /// Recorded (as the encrypted snapshot's sourceSnapshotID) once this point is safely encrypted,
        /// so a migration run again after an interruption does not encrypt it twice. Unique over the job's
        /// life: a history catalog discarded by a migration starts again at checkpoint 1 if encryption is
        /// turned off, so a checkpoint is named by its number and its time (ms) — a number alone would take
        /// a new checkpoint for one encrypted long ago, and delete it unencrypted.
        var marker: String {
            switch self {
            case let .legacy(snapshot): return "migrated:legacy:\(snapshot.dirName)"
            case let .history(seq?, time): return "migrated:checkpoint:\(seq)@\(Self.milliseconds(time))"
            case let .history(nil, time): return "migrated:latest:\(Self.milliseconds(time))"
            }
        }

        private static func milliseconds(_ time: Date) -> Int64 {
            Int64((time.timeIntervalSince1970 * 1000).rounded())
        }
    }

    /// The plaintext restore points at `plaintextRoot`, each with whether a migration encrypted it already:
    /// its marker is recorded with an encrypted snapshot, in the catalog of the job root on the destination
    /// (where the repo is). A catalog that exists but cannot be read throws: its points are unknown, and
    /// its data must never be discarded unencrypted.
    private func plaintextPoints(for job: BackupJob,
                                 at plaintextRoot: URL) async throws -> [(point: PlaintextPoint, encrypted: Bool)] {
        var encrypted = Set<String>()
        if let catalog = try Self.openLegacyCatalog(at: Self.jobRoot(for: job)) {
            encrypted = Set(try await catalog.snapshots(jobID: job.id)
                .filter { $0.status == .complete }.compactMap(\.sourceSnapshotID))
        }
        var points: [PlaintextPoint] = []
        if let catalog = try Self.openLegacyCatalog(at: plaintextRoot) {
            points += try await catalog.snapshots(jobID: job.id)
                .filter(Self.isPlaintext).sorted { $0.seqId < $1.seqId }.map(PlaintextPoint.legacy)
        }
        let layout = HistoryLayout(jobRoot: plaintextRoot)
        if try Syscalls.exists(layout.catalogPath) {
            let store = try HistoryStore(path: layout.catalogPath)
            points += try store.checkpoints().map { .history(seq: $0.seq, time: $0.time) }
            if try store.hasUnsealedChanges(), let end = try store.lastPassEnd() {
                points.append(.history(seq: nil, time: end))
            }
        }
        return points.map { ($0, encrypted.contains($0.marker)) }
    }

    /// Plaintext restore points a job still has on disk — encrypted by an interrupted migration or not, a
    /// migration removes them all. History-engine data that is no restore point of its own (a seeded mirror,
    /// the remains of an interrupted migration), or that cannot be read (a NAS image included), counts as
    /// one: it is plaintext on disk all the same.
    func plaintextSnapshotCount(for job: BackupJob) async -> Int {
        let count = try? await withPlaintextRoot(job, inImage: try Self.usesImage(job), writes: false) { root in
            let points = try await plaintextPoints(for: job, at: root)
            return try points.isEmpty && Self.historyDataExists(HistoryLayout(jobRoot: root)) ? 1 : points.count
        }
        return count ?? 1
    }

    /// Re-encrypt EVERY plaintext restore point into the repo (preserving each one's time), oldest first,
    /// then — only after all succeed — delete the plaintext: legacy trees and their catalog rows, and all
    /// of the history engine's data. If any point fails, it aborts and the plaintext is left completely
    /// intact (no data loss, no half-deleted state). Each point keeps every top-level folder it holds,
    /// including sources since removed from the job.
    func migrateToEncrypted(job: BackupJob, progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        guard let password = KeychainStorage.password(for: job.id) else {
            throw EncryptedBackupError.passwordMissing
        }
        try await migrateToEncrypted(job: job, password: password, progress: progress)
    }

    /// The migration with the repo password given (the Keychain holds it in the app).
    func migrateToEncrypted(job: BackupJob, password: String,
                            progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        try await exclusively {
            let inImage = try Self.usesImage(job)
            let onlyLeftovers = try await withPlaintextRoot(job, inImage: inImage, writes: true) { plaintextRoot in
                try await migrate(job: job, from: plaintextRoot, inImage: inImage, password: password,
                                  progress: progress)
                // The migration is done by now: a folder that cannot be judged is only kept, never an error.
                return (try? Self.holdsOnlyLeftovers(plaintextRoot)) ?? false
            }
            // The job's folder in the image is left with nothing its migration did not account for: it goes,
            // and the image with it when no other job's backups are in it.
            if inImage && onlyLeftovers { removeFromImage(job) }
        }
    }

    /// Re-encrypt the plaintext at `plaintextRoot` into the repo in the job root on the destination, then
    /// remove it. `inImage`: the plaintext is in a NAS image, so dropped trees go right away — the image
    /// may be detached before the background reaper would get to them.
    private func migrate(job: BackupJob, from plaintextRoot: URL, inImage: Bool, password: String,
                         progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let jobRoot = Self.jobRoot(for: job)
        let layout = HistoryLayout(jobRoot: plaintextRoot)
        sweepScratch(in: plaintextRoot)
        let points = try await plaintextPoints(for: job, at: plaintextRoot)
        let historyData = try Self.historyDataExists(layout)
        let snapshotsDir = plaintextRoot.appendingPathComponent("snapshots", isDirectory: true)
        let encryptedCatalog = try CatalogStore(path: jobRoot.appendingPathComponent("catalog.sqlite").path)
        let plaintextCatalog = inImage ? try Self.openLegacyCatalog(at: plaintextRoot) : encryptedCatalog
        if let plaintextCatalog {
            await finishLegacyDeletions(in: snapshotsDir, job: job, legacy: plaintextCatalog,
                                        reapInBackground: !inImage)
        }
        guard !points.isEmpty || historyData else { return }

        // 1) Re-encrypt every point not encrypted yet. A failure throws → plaintext stays untouched.
        let pending = points.filter { !$0.encrypted }.map(\.point)
        if !pending.isEmpty {
            let backend = try LocalBackend(root: jobRoot.appendingPathComponent("repo", isDirectory: true))
            let (config, keys) = try await RepoManager.unlock(backend: backend, password: Data(password.utf8))
            let engine = DedupEngine(backend: backend, keys: keys, chunker: config.chunker)
            try await engine.open()   // load the blob index up front so restore points dedup against each other

            for (index, point) in pending.enumerated() {
                progress(index, pending.count)
                switch point {
                case let .legacy(snap):
                    let roots = try Self.topLevelFolders(of: snapshotsDir.appendingPathComponent(snap.dirName, isDirectory: true))
                    try await encrypt(roots, at: snap.timestamp, marker: point.marker, into: engine,
                                      catalog: encryptedCatalog, job: job)
                case let .history(seq, time):
                    let tree = plaintextRoot.appendingPathComponent(".materialize-\(UUID().uuidString)", isDirectory: true)
                    defer { deleteSnapshotTree(tree) }
                    let roots = try HistoryMaterializer(layout: layout).materialize(at: seq, into: tree)
                    try await encrypt(roots, at: time, marker: point.marker, into: engine,
                                      catalog: encryptedCatalog, job: job)
                }
            }
            progress(pending.count, pending.count)
        }

        // 2) Everything is safely encrypted → now remove the plaintext — points an interrupted run encrypted
        //    included — each part in a way an interruption leaves recognisable (`.deleting-` trees, a trash
        //    folder).
        if let plaintextCatalog {
            for case let .legacy(snap) in points.map(\.point) {
                await deleteLegacySnapshot(snap, in: snapshotsDir, legacy: plaintextCatalog, reapInBackground: !inImage)
            }
        }
        if historyData { try discardHistoryData(layout, in: plaintextRoot) }
    }

    /// One restore point into the encrypted repo, recorded in the catalog at its original time with its
    /// migration `marker`. A point without folders has nothing to keep.
    private func encrypt(_ roots: [URL], at time: Date, marker: String, into engine: DedupEngine,
                         catalog: CatalogStore, job: BackupJob) async throws {
        guard !roots.isEmpty else { return }
        let seqId = try await catalog.beginSnapshot(jobID: job.id, timestamp: time, sourceSnapshotID: marker)
        let encID = "enc-\(seqId)"
        do {
            // Re-encrypt the recorded state exactly — no exclusions.
            let result = try await engine.backUp(sources: roots, snapshotID: encID, now: time.timeIntervalSince1970,
                                                 exclusions: .includeEverything, toleratingVanishedEntries: false)
            try await catalog.markComplete(seqId: seqId, dirName: encID, fileCount: result.fileCount,
                                           logicalBytes: Int64(result.totalBytes), addedBlocks: 0, durationMs: 0)
        } catch {
            try? await catalog.markFailed(seqId: seqId)
            throw error
        }
    }

    /// Remove the history engine's plaintext. The catalog goes first — into one trash folder with the
    /// rest — so a crash never leaves a catalog pointing at missing data; a leftover trash folder is
    /// swept by the next pass or migration.
    private func discardHistoryData(_ layout: HistoryLayout, in jobRoot: URL) throws {
        let fm = FileManager.default
        let trash = jobRoot.appendingPathComponent(".trash-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: false)
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: layout.catalogPath + suffix) {
            try Syscalls.atomicRename(layout.catalogPath + suffix, to: trash.path + "/history.sqlite" + suffix)
        }
        for folder in [layout.currentRoot, layout.versionsRoot] where fm.fileExists(atPath: folder) {
            try Syscalls.atomicRename(folder, to: trash.path + "/" + (folder as NSString).lastPathComponent)
        }
        deleteSnapshotTree(trash)
    }

    /// Leftovers of an interrupted migration: materialised trees and trash folders.
    private func sweepScratch(in jobRoot: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: jobRoot.path)) ?? []
        where name.hasPrefix(".materialize-") || name.hasPrefix(".trash-") {
            deleteSnapshotTree(jobRoot.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// The history engine left something on disk. Throws when that cannot be told.
    private static func historyDataExists(_ layout: HistoryLayout) throws -> Bool {
        try [layout.catalogPath, layout.currentRoot, layout.versionsRoot].contains { try Syscalls.exists($0) }
    }

    /// The folders at the top of a legacy snapshot tree (one per source it recorded); none when the tree is
    /// gone. Throws when it cannot be read: a point whose folders are unknown is never taken for empty —
    /// it would be deleted as encrypted with nothing encrypted.
    private static func topLevelFolders(of snapshot: URL) throws -> [URL] {
        guard try Syscalls.exists(snapshot.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: snapshot.path)
        return try names.sorted().compactMap { name in
            let url = snapshot.appendingPathComponent(name, isDirectory: true)
            var st = Darwin.stat()
            guard lstat(url.path, &st) == 0 else { throw InfraError(operation: "lstat", path: url.path, code: errno) }
            return st.st_mode & S_IFMT == S_IFDIR ? url : nil
        }
    }

    /// After a migration: the job root holds nothing the migration did not account for — only its legacy
    /// catalog, trees that are garbage by name (`.deleting-`, `.inprogress-`) and scratch folders. Anything
    /// else (a tree no catalog row knew, history data) keeps the folder.
    private static func holdsOnlyLeftovers(_ root: URL) throws -> Bool {
        guard try Syscalls.exists(root.path) else { return false }
        let fm = FileManager.default
        let catalogFiles: Set<String> = ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm"]
        for name in try fm.contentsOfDirectory(atPath: root.path) where !name.hasPrefix(".") && !catalogFiles.contains(name) {
            guard name == "snapshots",
                  try fm.contentsOfDirectory(atPath: root.appendingPathComponent(name).path).allSatisfy({ $0.hasPrefix(".") })
            else { return false }
        }
        return true
    }

    // MARK: - Where the backups are

    /// The job's plaintext backups live inside its destination's sparsebundle (a NAS share): it has no
    /// direct layout, and the image exists. Read from disk — no probe. Throws when the share cannot tell:
    /// a hiccup must not make the image's backups look absent.
    static func usesImage(_ job: BackupJob) throws -> Bool {
        try !hasDirectLayout(job) && ImageLease.shared(for: job.destination).imageExists()
    }

    /// The job's folder inside its destination's image, attached at `mount`.
    private static func jobRoot(for job: BackupJob, inImageAt mount: URL) -> URL {
        mount.appendingPathComponent("\(SparsebundleManager.jobsFolderName)/\(job.id.uuidString)", isDirectory: true)
    }

    /// Run `body` with the root of the job's plaintext backups: its job root on the destination, or — when
    /// `inImage` — its folder in the destination's image, held attached while `body` runs. `create` (a pass):
    /// make the image when there is none. `writes`: `body` changes what is in the image.
    private func withPlaintextRoot<T>(_ job: BackupJob, inImage: Bool, create: Bool = false, writes: Bool,
                                      _ body: (URL) async throws -> T) async throws -> T {
        guard inImage else { return try await body(Self.jobRoot(for: job)) }
        let lease = ImageLease.shared(for: job.destination)
        let mount = try lease.acquire(maxSizeBytes: job.retention.maxTotalBytes, create: create)
        defer { lease.release(flush: writes) }
        return try await body(Self.jobRoot(for: job, inImageAt: mount))
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

    /// The 1.1.x catalog of a job root, when it has one (it also records encrypted snapshots). For listing:
    /// one that cannot be opened is skipped.
    private static func legacyCatalog(at jobRoot: URL) -> CatalogStore? {
        try? openLegacyCatalog(at: jobRoot)
    }

    /// The 1.1.x catalog of a job root: nil when it has none; throws when it has one that cannot be opened
    /// — what it records is unknown then (migration must not go on without it).
    private static func openLegacyCatalog(at jobRoot: URL) throws -> CatalogStore? {
        let path = jobRoot.appendingPathComponent("catalog.sqlite").path
        guard try Syscalls.exists(path) else { return nil }
        return try CatalogStore(path: path)
    }

    /// 1.1.x (or this engine) keeps plaintext backups directly in the job root on the volume itself.
    private static func hasDirectLayout(_ job: BackupJob) throws -> Bool {
        let root = jobRoot(for: job)
        return try Syscalls.exists(root.appendingPathComponent("snapshots").path)
            || Syscalls.exists(HistoryLayout(jobRoot: root).catalogPath)
    }

    static func jobRoot(for job: BackupJob) -> URL {
        job.destination.appendingPathComponent("SpectaBackup/\(job.id.uuidString)", isDirectory: true)
    }
}
