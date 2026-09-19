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
//  - One runner per disk (BackupCoordinator, DiskSpace.diskKey): jobs on one disk take turns, jobs on
//    different disks run side by side. The heavy capture loop is synchronous, so it holds its
//    runner for the duration — what HistoryReader/HistoryMaterializer rely on: nothing moves a file in
//    current/ while they read. The scheduler keeps a job's own passes and migration from overlapping.
//  - Legacy (1.1.x) snapshot trees are no longer written. They stay browsable and restorable, are thinned
//    together with the checkpoints on one timeline, and `.inprogress-*` partials of the old engine are
//    discarded (nothing resumes them any more).
//  - An encrypted job's restore points are its repo's snapshots (RepoTimeline): nothing else records
//    them — no catalog at the destination. The repo is unlocked once per repo while the app runs. Its
//    retention and garbage collection run after each encrypted pass (RepoMaintenance).
//  - NAS jobs (sparsebundle strategy) keep their plaintext backups inside the destination's image. Every
//    use — a pass, the timeline, a restore, a browsing session, a migration — holds it attached through
//    the destination's ImageLease (`withPlaintextRoot`). An encrypted job's repo and catalog stay in the
//    job root on the share itself.
//  - A job is an image job when it has no direct layout and the image exists (or the destination needs
//    one, for its first pass) — read from disk, so passes and reads always agree on where its backups are.
//  - Deleting inside an image frees nothing on the share: removing a job's backups (or migrating them into
//    the encrypted repo) removes the image when no other job's backups are in it, or compacts it.
//  - Disk space (keepDiskReserve, DiskSpace): before and after every pass, a disk with less than its reserve
//    free (5%, or the largest "Keep free space" of its jobs) loses its oldest restore points — of all its
//    jobs together, oldest first — until the reserve is back. A pass that runs out of room is settled, room
//    is made for what it still has to write, and it goes on from where it stopped; it fails only when
//    nothing more may be removed (DiskFullError). An encrypted pass's packs are kept meanwhile, so the
//    retry reuses them. Per-job retention (policy, quota) runs after each pass as before.
//

import Darwin
import Foundation
import os
import Security

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

    /// An encrypted job's repo password (the Keychain; tests hand one in).
    private let passwords: @Sendable (UUID) -> String?
    /// An encrypted job's restore points, read from its repo.
    private let timeline: RepoTimeline
    /// Unlocked repo keys by repo path, with the identity of the repo they unlock (RepoTimeline.identity):
    /// the KDF runs once per repo while the app runs, and a repo created anew at the path is unlocked anew.
    private var unlocked: [String: (repo: String, config: RepoConfig, keys: RepoKeys)] = [:]
    /// Per job: packs an encrypted pass that ran out of room wrote — kept whole while room is made for the
    /// pass to be tried again, so what it stored is reused (RepoMaintenance `protecting`).
    private var unfinishedPacks: [UUID: Set<String>] = [:]

    init(passwords: @escaping @Sendable (UUID) -> String? = { KeychainStorage.password(for: $0) },
         timeline: RepoTimeline = RepoTimeline()) {
        self.passwords = passwords
        self.timeline = timeline
    }

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
        /// Something the user should know although the backup succeeded.
        var warning: String? = nil
        /// Where the journal now stands for the job: the cursors the pass stored, per source name.
        var journalCursors: [String: JournalCursor] = [:]
    }

    /// Run one backup pass for a job. `forceCheckpoint`: the pass was requested (Back Up Now, a due
    /// schedule, a new job) and ends with a checkpoint — an explicit restore point.
    /// `journalHints`: per source name, a later cursor its journal replay may start from (the coordinator
    /// vouches that nothing relevant happened since the stored one — JournalCursor.advanced).
    /// `neighbors`: the other jobs backing up to the same disk — the disk's reserve is kept across all of
    /// them (keepDiskReserve), before the pass, after it, and whenever it runs out of room.
    func run(job: BackupJob,
             neighbors: [BackupJob] = [],
             quietWindow: TimeInterval = 0,
             forceCheckpoint: Bool = false,
             journalHints: [String: JournalHint] = [:],
             progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> PassResult {
        try await exclusively {
            let disk = [job] + neighbors.filter { $0.id != job.id }
            let before = await keepDiskReserve(for: job, jobs: disk)
            // Too full to open its catalogs: the pass could not open its own either.
            if before.blocked, !before.madeRoom { throw DiskFullError(tooFullToMakeRoom: true) }
            var result: PassResult
            while true {
                do {
                    result = try await runPass(job: job, quietWindow: quietWindow, forceCheckpoint: forceCheckpoint,
                                               journalHints: journalHints, progress: progress)
                    break
                } catch where DiskSpace.isOutOfSpace(error) {
                    // The disk ran out of room: the oldest restore points make it — enough for what the pass
                    // still has to write, where it can tell — and the pass goes on from where it stopped. Each
                    // round removes something, so this ends: with the pass done, or nothing left to remove.
                    var needed: Int64 = 0
                    if case let CaptureError.outOfSpace(bytes) = error { needed = bytes }
                    let made = await keepDiskReserve(for: job, jobs: disk, needing: needed)
                    guard made.madeRoom else {
                        if made.blocked { throw DiskFullError(tooFullToMakeRoom: true) }
                        if made.short { throw DiskFullError() }
                        throw error
                    }
                }
            }
            unfinishedPacks[job.id] = nil
            let after = await keepDiskReserve(for: job, jobs: disk)
            let warnings = [result.warning, after.warning].compactMap { $0 }
            result.warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
            return result
        }
    }

    private func runPass(job: BackupJob, quietWindow: TimeInterval, forceCheckpoint: Bool,
                         journalHints: [String: JournalHint],
                         progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> PassResult {
        if job.encryptionEnabled {
            return try await runEncrypted(job: job, quietWindow: quietWindow, forceCheckpoint: forceCheckpoint,
                                          journalHints: journalHints, progress: progress)
        }
        let caps = try DestinationProbe.probe(destination: job.destination)
        // A job that 1.1.x already backed up directly onto this volume stays there (an NFS share with
        // hard links qualified then); moving its history into an image would strand what is there.
        let inImage = try Self.usesImage(job) || (caps.strategy == .sparsebundle && !(try Self.hasDirectLayout(job)))
        return try await withPlaintextRoot(job, inImage: inImage, create: true, writes: true) { jobRoot in
            try await runHistoryPass(job: job, jobRoot: jobRoot, inImage: inImage, capabilities: caps,
                                     quietWindow: quietWindow, forceCheckpoint: forceCheckpoint,
                                     journalHints: journalHints, progress: progress)
        }
    }

    /// One history-engine pass at `jobRoot`: seed from the newest legacy snapshot (once), capture, then
    /// apply retention to the job's whole timeline.
    private func runHistoryPass(job: BackupJob, jobRoot: URL, inImage: Bool, capabilities: DestinationCapabilities,
                                quietWindow: TimeInterval, forceCheckpoint: Bool,
                                journalHints: [String: JournalHint],
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
                                                                journalHints: journalHints,
                                                                room: Self.room(for: job, jobRoot: jobRoot, inImage: inImage),
                                                                progress: progress)
        // Inside a NAS image, dropped trees must be gone before it is detached; elsewhere they go in the
        // background (TreeReaper) so their deletion holds up no pass.
        await applyRetention(job: job, layout: layout, jobRoot: jobRoot, legacy: legacy, reapInBackground: !inImage)
        return PassResult(finishedAt: outcome.finishedAt, capabilities: capabilities,
                          deferredCount: outcome.deferredCount, journalCursors: outcome.journalCursors)
    }

    /// Encrypted path: unlock the dedup repo and run DedupEngine; the snapshot it writes is the restore
    /// point's only record. The repo is created in Settings (where the recovery key can be shown), not here.
    private func runEncrypted(job: BackupJob, quietWindow: TimeInterval, forceCheckpoint: Bool,
                              journalHints: [String: JournalHint],
                              progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> PassResult {
        let caps = try DestinationProbe.probe(destination: job.destination)
        let jobRoot = Self.jobRoot(for: job)
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        sweepScratch(in: jobRoot)   // the remains of an interrupted migration
        guard let backend = try existingRepo(of: job) else { throw EncryptedBackupError.repoNotInitialized }
        let (config, keys) = try await unlockRepo(backend, job: job)
        let engine = DedupEngine(backend: backend, keys: keys, chunker: config.chunker)
        try await engine.open()   // load the blob index so existing blobs are deduplicated, not re-stored

        // A catalog from before the repo was the record: an interrupted deletion is finished, and one left
        // with nothing plaintext to list goes (on a NAS it was SQLite over SMB).
        if let legacy = Self.legacyCatalog(at: jobRoot) {
            await finishLegacyDeletions(in: jobRoot.appendingPathComponent("snapshots", isDirectory: true), job: job,
                                        legacy: legacy, reapInBackground: true)
            if await adoptLegacyMarkers(legacy, job: job, repo: backend, keys: keys) {
                await discardLegacyCatalogIfSpent(legacy, at: jobRoot, job: job)
            }
        }
        let now = Date()
        let snapshotID = RepoTimeline.newSnapshotID(at: now)
        let plan = await encryptedCapturePlan(job: job, repo: backend, keys: keys, quietWindow: quietWindow,
                                              hints: journalHints, now: now)
        let result: DedupEngine.BackUpResult
        do {
            result = try await engine.backUp(sources: job.sources, snapshotID: snapshotID,
                                             now: now.timeIntervalSince1970, requested: forceCheckpoint,
                                             incremental: plan.incremental, exclusions: BackupExclusions(job: job),
                                             toleratingVanishedEntries: true)
        } catch where DiskSpace.isOutOfSpace(error) {
            // What it stored stays while room is made (not collected as garbage): the pass tried again reuses it.
            unfinishedPacks[job.id, default: []].formUnion(await engine.packsWritten())
            throw error
        }
        let finished = Date()
        let warning = await applyEncryptedRetention(job: job, repo: backend, keys: keys)
        await recordStoredBytes(of: job, in: backend)
        // The next pass starts from the snapshot that holds this state, and from where the journal was read up to.
        timeline.recordCapture(job.id, EncryptedCaptureState(
            parent: result.snapshotID, fingerprint: plan.fingerprint, cursors: plan.cursors, carried: result.carried,
            lastFullScan: plan.walkedWhole ? now.timeIntervalSince1970 : plan.lastFullScan,
            lastPassEnd: finished.timeIntervalSince1970))
        return PassResult(finishedAt: finished, capabilities: caps, deferredCount: result.deferred, warning: warning,
                          journalCursors: plan.cursors)
    }

    private struct EncryptedCapturePlan {
        var incremental: DedupEngine.Incremental
        var fingerprint: String
        var cursors: [String: JournalCursor] = [:]
        /// Every source is walked whole this pass.
        var walkedWhole = true
        var lastFullScan: Double?
    }

    private static let log = Logger(subsystem: "ai.calidalab.spectabackup", category: "encrypted")

    /// What an encrypted pass takes from the last one (as the history engine's discover, docs §3.7): its
    /// snapshot as the parent — unchanged files are not read again — and, while the journal can say, only
    /// the folders changed since. A full walk after a settings change, once a day, and whenever the state
    /// is missing or its parent gone; then the newest snapshot a pass wrote still spares unchanged files.
    private func encryptedCapturePlan(job: BackupJob, repo: LocalBackend, keys: RepoKeys, quietWindow: TimeInterval,
                                      hints: [String: JournalHint], now: Date) async -> EncryptedCapturePlan {
        let fingerprint = CaptureEngine.fingerprint(of: job)
        var state = timeline.captureState(job.id)
        if let parent = state?.parent, ((try? await repo.stat(key: "snapshots/\(parent)")) ?? nil) == nil { state = nil }
        var plan = EncryptedCapturePlan(incremental: .init(parent: state?.parent, quietWindow: quietWindow),
                                        fingerprint: fingerprint, lastFullScan: state?.lastFullScan)
        if state == nil, let newest = (try? await timeline.snapshots(jobID: job.id, backend: repo, keys: keys))?
            .filter({ $0.origin == nil }).max(by: { $0.createdAt < $1.createdAt }) {
            plan.incremental.parent = newest.id
        }
        let reason: String?
        if state == nil {
            reason = "no state from the last pass"
        } else if state?.fingerprint != fingerprint {
            reason = "settings or built-in rules changed"
        } else if state?.lastFullScan.map({ now.timeIntervalSince1970 - $0 >= CaptureEngine.safetyScanInterval }) ?? true {
            reason = "daily safety scan"
        } else {
            reason = nil
        }
        let exclusions = BackupExclusions(job: job)
        for source in job.sources {
            let name = source.lastPathComponent
            let cursorAtStart = ChangeJournal.cursorNow(for: source)   // before anything is read
            let recorded = state?.cursors[name]
            let stored = recorded?.advanced(to: hints[name])
            if let recorded, let stored, stored != recorded {
                Self.log.notice("journal replay of \(name, privacy: .public) (encrypted) starts from a quiet check, \(stored.eventID - recorded.eventID) events past the stored cursor")
            }
            var changes = JournalChanges.fullScan(reason: reason ?? "no cursor stored")
            if reason == nil, let stored {
                changes = ChangeJournal.changes(in: source, since: stored, exclusions: exclusions)
            }
            switch changes {
            case let .directories(dirty, lastEventID):
                plan.incremental.scopes[name] = .init(dirty: dirty, carried: state?.carried[name] ?? [])
                if let stored {
                    plan.cursors[name] = JournalCursor(eventID: max(lastEventID ?? 0, stored.eventID),
                                                       volumeUUID: stored.volumeUUID)
                }
                plan.walkedWhole = false
            case let .fullScan(why):
                Self.log.notice("full walk of \(name, privacy: .public) (encrypted): \(why, privacy: .public)")
                if let cursorAtStart { plan.cursors[name] = cursorAtStart }
            }
        }
        return plan
    }

    /// Thin the encrypted job's snapshots with its policy and collect what they no longer need — at most
    /// once a day, unless space is short (RepoMaintenance). A failure leaves garbage for the next run, never a
    /// snapshot without its data; returns what the user should know when old restore points cannot be
    /// cleaned up.
    private func applyEncryptedRetention(job: BackupJob, repo: LocalBackend, keys: RepoKeys) async -> String? {
        let now = Date()
        do {
            let listing = try await timeline.listing(jobID: job.id, backend: repo, keys: keys)
            let outcome = try await RepoMaintenance(backend: repo, keys: keys).run(
                policy: job.retention, snapshots: listing.snapshots,
                collect: timeline.collectionDue(job.id, now: now), now: now)
            if outcome.collected { timeline.recordCollection(job.id, at: now) }
            let unreadable = Set(listing.unreadable).union(outcome.unreadable)
            guard unreadable.isEmpty else {
                Self.log.error("encrypted repo of \(job.name, privacy: .public): unreadable snapshots \(unreadable.sorted(), privacy: .public)")
                return "An encrypted restore point could not be read, so space from old restore points is not being "
                    + "reclaimed. New backups continue."
            }
            return nil
        } catch {
            Self.log.error("encrypted retention of \(job.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return "Old encrypted restore points could not be cleaned up: " + BackupErrorMessage.describe(error)
        }
    }

    // MARK: - Encrypted repo

    /// Measure and remember what the job's repo occupies — its packs — for the timeline's footprint, so
    /// showing it lists nothing at the destination.
    private func recordStoredBytes(of job: BackupJob, in backend: Backend) async {
        guard let repo = try? await RepoTimeline.identity(of: backend),
              let bytes = try? await backend.bytes(prefix: "data") else { return }
        timeline.recordStoredBytes(job.id, repo: repo, bytes)
    }

    /// The job's encrypted repo, when it has one (never created here: that is Settings' job, where the
    /// recovery key can be shown).
    private func existingRepo(of job: BackupJob) throws -> LocalBackend? {
        let root = Self.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true)
        guard try Syscalls.exists(root.appendingPathComponent(RepoManager.configKey).path) else { return nil }
        return try LocalBackend(root: root)
    }

    /// The repo's keys, unlocked with `password` or the job's stored one — once per repo.
    private func unlockRepo(_ backend: LocalBackend, job: BackupJob,
                            password: String? = nil) async throws -> (config: RepoConfig, keys: RepoKeys) {
        let key = backend.root.standardizedFileURL.path
        let repo = try await RepoTimeline.identity(of: backend)
        if let known = unlocked[key], known.repo == repo { return (known.config, known.keys) }
        guard let password = password ?? passwords(job.id) else { throw EncryptedBackupError.passwordMissing }
        let result = try await RepoManager.unlock(backend: backend, password: Data(password.utf8))
        unlocked[key] = (repo, result.config, result.keys)
        return result
    }

    /// The job's encrypted snapshots, as the timeline shows them. Without the password (not stored, not
    /// unlocked yet) only those the local cache knows.
    private func encryptedSnapshots(of job: BackupJob) async throws -> [RepoSnapshotSummary] {
        guard let backend = try existingRepo(of: job) else { return [] }
        let keys = try? await unlockRepo(backend, job: job).keys
        return try await timeline.snapshots(jobID: job.id, backend: backend, keys: keys)
    }

    /// Markers a catalog at the job root recorded for encrypted snapshots (the migrations of earlier builds):
    /// written into those snapshots themselves (their origin) before the catalog may go, so the repo alone
    /// knows which points a migration encrypted — and the cadence never thins a migrated point.
    /// True when every marker is in its snapshot now (or its snapshot is gone): only then may the catalog go.
    private func adoptLegacyMarkers(_ legacy: CatalogStore, job: BackupJob, repo: LocalBackend, keys: RepoKeys) async -> Bool {
        let prefix = "snapshots/"
        guard let rows = try? await legacy.snapshots(jobID: job.id),
              let listed = try? await repo.list(prefix: "snapshots") else { return false }
        let present = Set(listed.map { String($0.dropFirst(prefix.count)) })
        let cipher = BlobCipher(keys: keys)
        var complete = true
        var rewritten: [String] = []
        for row in rows where row.status == .complete && present.contains(row.dirName) {
            guard let marker = row.sourceSnapshotID else { continue }
            let key = prefix + row.dirName
            guard let sealed = try? await repo.get(key: key),
                  var snapshot = try? JSONDecoder().decode(Snapshot.self, from: cipher.openMetadata(sealed, context: key)) else {
                complete = false   // unreadable for now: the catalog keeps the marker
                continue
            }
            guard snapshot.origin == nil else { continue }
            snapshot.origin = marker
            guard let data = try? JSONEncoder().encode(snapshot),
                  let resealed = try? cipher.sealMetadata(data, context: key),
                  (try? await repo.put(key: key, data: resealed)) != nil else {
                complete = false
                continue
            }
            rewritten.append(row.dirName)
        }
        if !rewritten.isEmpty {
            if (try? await repo.sync()) == nil { complete = false }
            timeline.refresh(job.id, snapshots: rewritten)
        }
        return complete
    }

    /// A 1.1.x catalog at the job root that no longer lists anything plaintext — only encrypted snapshots,
    /// which the repo records itself (their markers adopted first): removed.
    private func discardLegacyCatalogIfSpent(_ legacy: CatalogStore, at jobRoot: URL, job: BackupJob) async {
        guard let rows = try? await legacy.snapshots(jobID: job.id), !rows.contains(where: Self.isPlaintext) else { return }
        let path = jobRoot.appendingPathComponent("catalog.sqlite").path
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    // MARK: - Retention

    /// Thin the job's timeline — legacy snapshots, then checkpoints — with its policy and quota; free space is
    /// the disk's concern (keepDiskReserve). `pressureDrops`: that many more of its oldest restore points go.
    /// Returns whether anything went.
    @discardableResult
    private func applyRetention(job: BackupJob, layout: HistoryLayout, jobRoot: URL, legacy: CatalogStore?,
                                reapInBackground: Bool, pressureDrops: Int = 0, now: Date = Date()) async -> Bool {
        let snapshotsDir = jobRoot.appendingPathComponent("snapshots", isDirectory: true)
        if let legacy {
            await reconcileLegacyTrees(in: snapshotsDir, job: job, legacy: legacy, reapInBackground: reapInBackground)
        }
        let snapshots = ((try? await legacy?.snapshots(jobID: job.id)) ?? []).filter(Self.isPlaintext)
        guard let result = try? HistoryMaintenance(layout: layout).applyRetention(
            policy: job.retention, legacy: Self.legacyPoints(snapshots), pressureDrops: pressureDrops, now: now)
        else { return false }
        var removed = result.checkpointsDeleted > 0 || result.versionsDeleted > 0
        guard let legacy else { return removed }
        for snapshot in snapshots where result.legacySnapshotsToDelete.contains(snapshot.seqId) {
            await deleteLegacySnapshot(snapshot, in: snapshotsDir, legacy: legacy, reapInBackground: reapInBackground)
            removed = true
        }
        return removed
    }

    /// Legacy snapshots as retention sees them: their own footprint is their freshly written blocks.
    private static func legacyPoints(_ snapshots: [SnapshotRecord]) -> [HistoryRetention.LegacySnapshot] {
        snapshots.map { .init(id: $0.seqId, time: $0.timestamp, bytes: $0.addedBlocks * 512) }
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
            let repo = Self.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true)
            unlocked[repo.standardizedFileURL.path] = nil
            deleteSnapshotTree(Self.jobRoot(for: job))
            timeline.forget(job.id)
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

    // MARK: - Disk space

    private static let spaceLog = Logger(subsystem: "ai.calidalab.spectabackup", category: "space")

    /// What `keepDiskReserve` did.
    struct Reclaim: Sendable {
        /// Restore points were removed, or garbage collected: a pass that ran out of room may be tried again.
        var madeRoom = false
        /// Less than the target is free even with everything that may go gone.
        var short = false
        /// Some backups there could not even be opened for lack of room: what they hold is not counted.
        var blocked = false
        /// What the user should know: the disk stays short.
        var warning: String? {
            guard short else { return nil }
            return blocked
                ? "The backup disk is too full even to remove old restore points. Free up a little space on it (100 MB is enough)."
                : "The backup disk is almost full, and no older restore points can be removed to make room."
        }
    }

    /// One job's backups, opened to make room on its disk.
    private struct SpaceSide {
        enum Store {
            case history(layout: HistoryLayout, jobRoot: URL, legacy: CatalogStore?, snapshots: [SnapshotRecord],
                         lease: ImageLease?)
            case encrypted(maintenance: RepoMaintenance, snapshots: [RepoSnapshotSummary],
                           survey: RepoMaintenance.Survey, protected: Set<String>)
        }
        let job: BackupJob
        let store: Store
        var ladder: DiskSpace.Ladder
    }

    /// Keep the reserve free on the disk `job`'s backups are on (DiskSpace): while less than it — plus
    /// `extra`, what a pass that ran out of room still has to write — is free, the oldest restore points go,
    /// of every job in `jobs` (those on the disk, `job` included) together, oldest first, and encrypted repos
    /// collect their garbage. A NAS image that lost restore points is compacted at once, so the share has the
    /// room back before anything is measured or written again. Nothing is opened while enough is free.
    func keepDiskReserve(for job: BackupJob, jobs: [BackupJob], needing extra: Int64 = 0) async -> Reclaim {
        guard let volume = try? Syscalls.volumeInfo(at: job.destination.path) else { return Reclaim() }
        let reserve = DiskSpace.reserve(capacity: volume.totalBytes, jobs: jobs)
        let target = DiskSpace.saturatingAdd(reserve, max(0, extra))
        // Space the reaper is still freeing counts as free: it is on its way back. So does the ballast: it is
        // there to be given back.
        func reaping() -> Int64 {
            jobs.reduce(Int64(0)) { $0 + TreeReaper.shared.pendingBytes(under: Self.jobRoot(for: $1).path) }
        }
        let ballasts = Set(jobs.map { Self.ballastURL(for: $0.destination).standardizedFileURL })
        let set = ballasts.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        let free = DiskSpace.saturatingAdd(DiskSpace.saturatingAdd(volume.freeBytes, reaping()), set)
        guard free < target else {
            Self.placeBallast(for: job.destination, bytes: DiskSpace.ballastBytes(reserve: reserve))
            return Reclaim()
        }
        // Room to make room: a full disk cannot even open a catalog.
        for ballast in ballasts { try? FileManager.default.removeItem(at: ballast) }
        // Less than a ballast's worth to work with: what cannot be opened now is taken for the disk being full
        // (SQLite says so only sometimes — measured: SQLITE_IOERR_SHMOPEN, no errno, on a full APFS volume).
        let cramped = ((try? Syscalls.volumeInfo(at: job.destination.path))?.freeBytes ?? 0)
            < DiskSpace.ballastBytes(reserve: reserve)

        let now = Date()
        var sides: [SpaceSide] = []
        var blocked = false
        for candidate in jobs where DiskSpace.givesUpSpace(candidate) {
            if let side = await openForSpace(candidate, now: now, cramped: cramped, blocked: &blocked) { sides.append(side) }
        }
        let plan = DiskSpace.plan(free: free, target: target, ladders: sides.map(\.ladder))
        var reclaim = Reclaim(short: plan.short, blocked: blocked)
        for side in sides {
            if await makeRoom(side, drops: plan.drops[side.job.id] ?? 0, now: now) { reclaim.madeRoom = true }
        }
        // The reserve is back: so is the ballast (out of it — the ballast counts as free).
        if let after = try? Syscalls.volumeInfo(at: job.destination.path),
           DiskSpace.saturatingAdd(after.freeBytes, reaping()) >= target {
            Self.placeBallast(for: job.destination, bytes: DiskSpace.ballastBytes(reserve: reserve))
        }
        let removed = plan.drops.values.reduce(0, +)
        Self.spaceLog.notice("\(volume.freeBytes >> 20) MB free on the disk of \(job.name, privacy: .public), \(target >> 20) MB wanted: \(removed) restore points removed across \(plan.drops.count) jobs, \(plan.freeAfter >> 20) MB expected free\(plan.short ? " — still short" : "", privacy: .public)")
        return reclaim
    }

    /// What a pass may still write to `job`'s disk: its free space — the share's, for a NAS image, whose own
    /// free space means nothing — less a headroom as large as the ballast, so a catalog and the file system
    /// always have room; space the reaper is freeing counts (not for an image: nothing is reaped in one).
    private static func room(for job: BackupJob, jobRoot: URL, inImage: Bool) -> () -> Int64? {
        let destination = job.destination
        return {
            guard let volume = try? Syscalls.volumeInfo(at: destination.path) else { return nil }
            let headroom = DiskSpace.ballastBytes(reserve: DiskSpace.reserve(capacity: volume.totalBytes, jobs: [job]))
            let reaping = inImage ? 0 : TreeReaper.shared.pendingBytes(under: jobRoot.path)
            return volume.freeBytes + reaping - headroom
        }
    }

    /// Room set aside on a destination to make room with once its disk is full (DiskSpace.ballastBytes).
    static func ballastURL(for destination: URL) -> URL {
        destination.appendingPathComponent("SpectaBackup/.space-reserve")
    }

    private static func size(of url: URL) -> Int64 {
        var st = Darwin.stat()
        return lstat(url.path, &st) == 0 ? Int64(st.st_size) : 0
    }

    /// Put the ballast on `destination` when it is missing: data that takes its full size whatever the file
    /// system (a random pattern: a share that compresses cannot shrink it), written aside and renamed into
    /// place, so a ballast is always whole.
    private static func placeBallast(for destination: URL, bytes: Int64) {
        let url = ballastURL(for: destination)
        guard bytes > 0, (try? Syscalls.exists(url.path)) == false else { return }
        let partial = url.deletingLastPathComponent().appendingPathComponent(".space-reserve.partial")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var chunk = Data(count: 1 << 20)
            _ = chunk.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            var left = bytes
            while left > 0 {
                try handle.write(contentsOf: chunk.prefix(Int(min(left, Int64(chunk.count)))))
                left -= Int64(chunk.count)
            }
            try handle.synchronize()
            try Syscalls.atomicRename(partial.path, to: url.path)
        } catch {
            try? FileManager.default.removeItem(at: partial)
        }
    }

    /// `job`'s backups opened to make room, with what each of its oldest restore points would free; nil when
    /// they cannot be read (their repo locked without a password, the share unable to tell) or there are none.
    /// `blocked`: set when they could not be opened for lack of room — the failure says so, or it came with
    /// the disk `cramped` (less than a ballast's worth free).
    private func openForSpace(_ job: BackupJob, now: Date, cramped: Bool, blocked: inout Bool) async -> SpaceSide? {
        if job.encryptionEnabled {
            guard let backend = try? existingRepo(of: job),
                  let keys = try? await unlockRepo(backend, job: job).keys,
                  let listing = try? await timeline.listing(jobID: job.id, backend: backend, keys: keys) else { return nil }
            let maintenance = RepoMaintenance(backend: backend, keys: keys)
            let protected = unfinishedPacks[job.id] ?? []
            guard let survey = try? await maintenance.survey(needsGraph: true, needsIndex: true),
                  let ladder = RepoMaintenance.ladder(policy: job.retention, snapshots: listing.snapshots,
                                                      survey: survey, protecting: protected, now: now) else { return nil }
            return SpaceSide(job: job, store: .encrypted(maintenance: maintenance, snapshots: listing.snapshots,
                                                         survey: survey, protected: protected),
                             ladder: DiskSpace.Ladder(jobID: job.id, garbage: ladder.garbage, steps: ladder.steps))
        }
        guard let inImage = try? Self.usesImage(job) else { return nil }
        let lease = inImage ? ImageLease.shared(for: job.destination) : nil
        let jobRoot: URL
        if let lease {
            guard let mount = try? lease.acquire(create: false) else { return nil }
            jobRoot = Self.jobRoot(for: job, inImageAt: mount)
        } else {
            jobRoot = Self.jobRoot(for: job)
        }
        let layout = HistoryLayout(jobRoot: jobRoot)
        let legacy = Self.legacyCatalog(at: jobRoot)
        let snapshots = ((try? await legacy?.snapshots(jobID: job.id)) ?? []).filter(Self.isPlaintext)
        let steps: [DiskSpace.Step]?
        do {
            // A pass that ran out of room left its last batch unsettled: settled now, so what it moved counts.
            _ = try CaptureEngine(layout: layout).settleInterruptedPass()
            steps = try HistoryMaintenance(layout: layout).ladder(policy: job.retention,
                                                                  legacy: Self.legacyPoints(snapshots), now: now)
        } catch {
            if cramped || DiskSpace.isOutOfSpace(error) { blocked = true }
            Self.spaceLog.error("the backups of \(job.name, privacy: .public) could not be opened to make room: \(String(describing: error), privacy: .public)")
            steps = nil
        }
        guard let steps else {
            lease?.release(flush: false)
            return nil
        }
        return SpaceSide(job: job, store: .history(layout: layout, jobRoot: jobRoot, legacy: legacy, snapshots: snapshots,
                                                   lease: lease),
                         ladder: DiskSpace.Ladder(jobID: job.id, steps: steps))
    }

    /// Remove `drops` of the side's oldest restore points (an encrypted repo also collects its garbage), and
    /// let go of what was opened. Returns whether anything went.
    private func makeRoom(_ side: SpaceSide, drops: Int, now: Date) async -> Bool {
        switch side.store {
        case let .history(layout, jobRoot, legacy, _, lease):
            // Deleted at once, not by the reaper: the room is wanted now.
            let removed = drops > 0 ? await applyRetention(job: side.job, layout: layout, jobRoot: jobRoot, legacy: legacy,
                                                           reapInBackground: false, pressureDrops: drops, now: now) : false
            guard let lease else { return removed }
            lease.release(flush: removed)
            // Deleting inside an image frees nothing on the share until it is compacted.
            if removed { lease.reclaimNow() }
            return removed
        case let .encrypted(maintenance, snapshots, survey, protected):
            guard drops > 0 || side.ladder.garbage > 0 else { return false }
            do {
                let outcome = try await maintenance.run(policy: side.job.retention, snapshots: snapshots,
                                                        pressure: .init(drops: drops), collect: true,
                                                        protecting: protected, survey: survey, now: now)
                if outcome.collected { timeline.recordCollection(side.job.id, at: now) }
                await recordStoredBytes(of: side.job, in: maintenance.backend)
                return !outcome.dropped.isEmpty || outcome.reclaimedBytes > 0
            } catch {
                Self.spaceLog.error("making room in the encrypted repo of \(side.job.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
    }

    // MARK: - Timeline

    /// The job's restore points (newest first), when it was last backed up, and what its backups occupy.
    /// Throws when the destination is not reachable (an unplugged disk, an unmounted share) or a NAS job's
    /// image cannot be attached: that is no empty timeline, and what is shown stays.
    func history(for job: BackupJob) async throws -> BackupHistory {
        guard FileManager.default.fileExists(atPath: job.destination.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: job.destination.path])
        }
        // The job root on the destination: a direct job's plaintext backups.
        var history = await backups(at: Self.jobRoot(for: job), of: job)
        // Encrypted snapshots: the repo is their record. A pass that found nothing changed wrote none, but
        // brought the backup up to date all the same. What the repo occupies was measured as its last pass
        // ended (RepoTimeline).
        let encrypted = (try? await encryptedSnapshots(of: job)) ?? []
        for snapshot in encrypted {
            let time = Date(timeIntervalSince1970: snapshot.createdAt)
            history.points.append(RestorePoint(source: .encryptedSnapshot(id: snapshot.id), time: time,
                                               fileCount: Int64(snapshot.fileCount), bytes: Int64(snapshot.totalBytes)))
            history.lastBackup = max(history.lastBackup ?? time, time)
        }
        if !encrypted.isEmpty { history.storageBytes += timeline.storedBytes(job.id) ?? 0 }
        if let end = timeline.captureState(job.id)?.lastPassEnd {
            let time = Date(timeIntervalSince1970: end)
            history.lastBackup = max(history.lastBackup ?? time, time)
        }
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

    /// The plaintext restore points and footprint of the backups kept at `jobRoot` (unsorted). Encrypted
    /// snapshots a 1.1.x catalog lists as well are the repo's to list.
    private func backups(at jobRoot: URL, of job: BackupJob) async -> BackupHistory {
        var history = BackupHistory()
        // Each part on its own: a damaged catalog must not hide the other kind of restore point.
        var plaintextLegacy = 0
        if let legacy = Self.legacyCatalog(at: jobRoot), let snapshots = try? await legacy.snapshots(jobID: job.id) {
            for snapshot in snapshots where Self.isPlaintext(snapshot) {
                plaintextLegacy += 1
                history.points.append(RestorePoint(source: .legacySnapshot(dirName: snapshot.dirName), time: snapshot.timestamp,
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
        try await exclusively {
            guard let backend = try existingRepo(of: job) else { throw EncryptedBackupError.repoNotInitialized }
            let (config, keys) = try await unlockRepo(backend, job: job)
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

    /// The plaintext restore points at `plaintextRoot`, each with whether a migration encrypted it already
    /// (`encryptedOrigins`). A catalog that exists but cannot be read throws: its points are unknown, and
    /// its data must never be discarded unencrypted.
    private func plaintextPoints(for job: BackupJob,
                                 at plaintextRoot: URL) async throws -> [(point: PlaintextPoint, encrypted: Bool)] {
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
        guard !points.isEmpty else { return [] }
        let encrypted = try await encryptedOrigins(of: job)
        return points.map { ($0, encrypted.contains($0.marker)) }
    }

    /// Markers of the plaintext restore points already in the repo: each encrypted snapshot's origin, and —
    /// from before the repo was the record — the markers the job root's 1.1.x catalog recorded. Without the
    /// repo's keys, snapshots the timeline cache does not know are left out: their points are taken for not
    /// encrypted yet (encrypted again, never deleted unencrypted).
    private func encryptedOrigins(of job: BackupJob) async throws -> Set<String> {
        var origins = Set(try await encryptedSnapshots(of: job).compactMap(\.origin))
        // A marker is only as good as its snapshot: one retention has dropped encrypts nothing any more.
        if let catalog = try Self.openLegacyCatalog(at: Self.jobRoot(for: job)) {
            let prefix = "snapshots/"
            let present = Set(try await existingRepo(of: job)?.list(prefix: "snapshots")
                .map { String($0.dropFirst(prefix.count)) } ?? [])
            origins.formUnion(try await catalog.snapshots(jobID: job.id)
                .filter { $0.status == .complete && present.contains($0.dirName) }.compactMap(\.sourceSnapshotID))
        }
        return origins
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
        guard let password = passwords(job.id) else {
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
        let repo = try existingRepo(of: job)
        // Unlocked first: which points are encrypted already is recorded in the repo.
        var unlockedRepo: (config: RepoConfig, keys: RepoKeys)?
        if let repo { unlockedRepo = try await unlockRepo(repo, job: job, password: password) }
        var markersAdopted = true
        if let repo, let unlockedRepo, let legacy = Self.legacyCatalog(at: jobRoot) {
            markersAdopted = await adoptLegacyMarkers(legacy, job: job, repo: repo, keys: unlockedRepo.keys)
        }
        let points = try await plaintextPoints(for: job, at: plaintextRoot)
        let historyData = try Self.historyDataExists(layout)
        let snapshotsDir = plaintextRoot.appendingPathComponent("snapshots", isDirectory: true)
        let plaintextCatalog = try Self.openLegacyCatalog(at: plaintextRoot)
        if let plaintextCatalog {
            await finishLegacyDeletions(in: snapshotsDir, job: job, legacy: plaintextCatalog,
                                        reapInBackground: !inImage)
        }
        guard !points.isEmpty || historyData else { return }

        // 1) Re-encrypt every point not encrypted yet. A failure throws → plaintext stays untouched.
        let pending = points.filter { !$0.encrypted }.map(\.point)
        if !pending.isEmpty {
            guard let repo, let unlockedRepo else { throw EncryptedBackupError.repoNotInitialized }
            let engine = DedupEngine(backend: repo, keys: unlockedRepo.keys, chunker: unlockedRepo.config.chunker)
            try await engine.open()   // load the blob index up front so restore points dedup against each other

            for (index, point) in pending.enumerated() {
                progress(index, pending.count)
                switch point {
                case let .legacy(snap):
                    let roots = try Self.topLevelFolders(of: snapshotsDir.appendingPathComponent(snap.dirName, isDirectory: true))
                    try await encrypt(roots, at: snap.timestamp, marker: point.marker, into: engine)
                case let .history(seq, time):
                    let tree = plaintextRoot.appendingPathComponent(".materialize-\(UUID().uuidString)", isDirectory: true)
                    defer { deleteSnapshotTree(tree) }
                    let roots = try HistoryMaterializer(layout: layout).materialize(at: seq, into: tree)
                    try await encrypt(roots, at: time, marker: point.marker, into: engine)
                }
            }
            progress(pending.count, pending.count)
            await recordStoredBytes(of: job, in: repo)
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
        // Nothing plaintext left for the job root's 1.1.x catalog to list, and its markers in the repo: it goes.
        if markersAdopted, let legacy = Self.legacyCatalog(at: jobRoot) {
            await discardLegacyCatalogIfSpent(legacy, at: jobRoot, job: job)
        }
    }

    /// One restore point into the encrypted repo, at its original time, with its migration `marker` as the
    /// snapshot's origin. A point without folders has nothing to keep.
    private func encrypt(_ roots: [URL], at time: Date, marker: String, into engine: DedupEngine) async throws {
        guard !roots.isEmpty else { return }
        // Re-encrypt the recorded state exactly — no exclusions.
        try await engine.backUp(sources: roots, snapshotID: RepoTimeline.newSnapshotID(at: time),
                                now: time.timeIntervalSince1970, origin: marker,
                                exclusions: .includeEverything, toleratingVanishedEntries: false)
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
        let mount = try lease.acquire(create: create)
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
