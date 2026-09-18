//
//  @file        BackupCoordinator.swift
//  @description Main-actor, observable owner of the job list and per-job runtime state. Persists job
//               config, kicks off passes on the BackupRunner actor, and marshals progress/results
//               back to the UI. The single source of truth the dashboard and menu bar both observe.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - @Observable + @MainActor (Swift 6). UI reads `jobs` and `state(for:)`; heavy work is on `runner`.
//  - When a job runs is decided by its PassScheduler (pure, unit-tested): this class only feeds it
//    events and performs the action it returns — start a pass now, or arm the job's single timer.
//    Nothing that arrives while a job is busy is dropped; manual runs are never throttled.
//  - A job never runs two passes at once (the scheduler's busy state); the runner actor additionally
//    serializes execution to avoid concurrent destination writes.
//  - Watchers only fire for changes the job's exclusions would not skip (ChangeFilter).
//  - Realtime jobs get one catch-up pass at launch (changes made while SpectArk was not running), and
//    one when they start running on changes (enabled, switched to realtime) or when what they back
//    up changes (sources, exclusions).
//

import Foundation

@MainActor
@Observable
final class BackupCoordinator {

    private(set) var jobs: [BackupJob]
    private(set) var states: [UUID: JobRuntimeState] = [:]

    private let store = JobStore()
    /// False in a unit-test host: the saved job list is neither loaded nor overwritten (AppRuntime).
    private let usesSavedJobs: Bool
    private let runner = BackupRunner()
    private var watchers: [UUID: FolderWatcher] = [:]
    /// Per-job scheduling state; the source of truth for "busy" and for what runs next.
    private var schedulers: [UUID: PassScheduler] = [:]
    /// The timer of each job's armed automatic pass.
    private var armedPasses: [UUID: Task<Void, Never>] = [:]
    /// inProgress catalog rows older than this belong to a previous run of the app (see refreshAllHistory).
    private let launchedAt = Date()
    private var meters: [UUID: ThroughputMeter] = [:]
    private var scheduleTicker: Task<Void, Never>?

    init(usesSavedJobs: Bool = true) {
        self.usesSavedJobs = usesSavedJobs
        jobs = usesSavedJobs ? store.load() : []
    }

    // MARK: - Accessors

    func state(for id: UUID) -> JobRuntimeState {
        states[id] ?? JobRuntimeState()
    }

    var anyRunning: Bool {
        states.values.contains { $0.isRunning }
    }

    // MARK: - Job management

    func addJob(_ job: BackupJob) {
        jobs.append(job)
        persist()
        loadHistory(for: job)
        if case .realtime = job.trigger { startWatcher(for: job) }
        // Immediate first backup of the (possibly already-populated) folder — requirement #4.
        runNow(job.id)
    }

    func removeJob(_ id: UUID, deleteSnapshots: Bool = false) {
        stopWatcher(id)
        cancelArmedPass(id)
        schedulers[id] = nil
        let job = jobs.first(where: { $0.id == id })
        jobs.removeAll { $0.id == id }
        states[id] = nil
        persist()
        if deleteSnapshots, let job {
            KeychainStorage.removePassword(for: id)   // drop the encrypted repo's key too, if any
            Task { await runner.deleteJobData(for: job) }
        }
    }

    /// Apply edited settings (content filter / trigger / retention / quota) and restart its watcher.
    /// Interval jobs are picked up by the schedule ticker, which reads `jobs` live. A realtime job gets a
    /// pass now when it starts running on changes (changes since its last pass produced no events we
    /// saw) or when what it backs up changed — e.g. turning "Skip rebuildable files" off must back up
    /// those folders without waiting for an unrelated edit.
    func updateJob(_ job: BackupJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        let old = jobs[idx]
        jobs[idx] = job
        persist()
        stopWatcher(job.id)
        guard Self.runsOnChanges(job) else {
            cancelArmedPass(job.id)
            schedulers[job.id]?.automaticRunsStopped()
            return
        }
        startWatcher(for: job)
        let contentChanged = old.sources != job.sources || old.excludeGlobs != job.excludeGlobs
            || old.skipsBuildArtifacts != job.skipsBuildArtifacts
        if !Self.runsOnChanges(old) || contentChanged {
            handleChange(job.id)
        }
    }

    private static func runsOnChanges(_ job: BackupJob) -> Bool {
        job.isEnabled && job.trigger == .realtime
    }

    /// Initialize (or verify) an encrypted job's repo and store its password in the Keychain. Returns
    /// the recovery key when the repo was just created (show it ONCE), or nil if it already existed.
    /// The heavy argon2 KDF / repo creation runs off the main actor.
    func enableEncryption(for job: BackupJob, password: String) async throws -> String? {
        let repoRoot = BackupRunner.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true)
        let pw = Data(password.utf8)
        let recovery = try await Task.detached(priority: .userInitiated) { () -> String? in
            let backend = try LocalBackend(root: repoRoot)
            if await RepoManager.isInitialized(backend) {
                _ = try await RepoManager.unlock(backend: backend, password: pw)   // verify password
                return nil
            }
            return try await RepoManager.create(backend: backend, password: pw).recoveryKey
        }.value
        KeychainStorage.setPassword(password, for: job.id)
        return recovery
    }

    private func persist() {
        guard usesSavedJobs else { return }
        try? store.save(jobs)
    }

    // MARK: - Running

    /// Back up now (the user, a new job, or a due schedule). Starts immediately, or right after the
    /// job's current work if it is busy — never throttled.
    func runNow(_ jobID: UUID) {
        guard jobs.contains(where: { $0.id == jobID }) else { return }
        perform(schedulers[jobID, default: PassScheduler()].manualRequested(), for: jobID)
    }

    private func startPass(_ jobID: UUID, quietWindow: TimeInterval, requested: Bool) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        cancelArmedPass(jobID)   // this pass covers whatever the armed one was for
        schedulers[jobID, default: PassScheduler()].workStarted(.pass(quietWindow: quietWindow))
        var st = state(for: jobID)
        st.isRunning = true
        st.lastError = nil
        st.progress = BackupProgress()
        states[jobID] = st

        Task { await execute(job: job, quietWindow: quietWindow, requested: requested) }
    }

    private func execute(job: BackupJob, quietWindow: TimeInterval, requested: Bool) async {
        let jobID = job.id
        meters[jobID] = ThroughputMeter()
        updateFreeSpace(jobID)
        let progress: @Sendable (BackupProgress) -> Void = { p in
            Task { @MainActor [weak self] in self?.applyProgress(p, for: jobID) }
        }
        let started = Date()
        let deferredCount: Int
        let succeeded: Bool
        do {
            let result = try await runner.run(job: job, quietWindow: quietWindow, forceCheckpoint: requested,
                                              progress: progress)
            let history = try? await runner.history(for: job)
            guard jobs.contains(where: { $0.id == jobID }) else { return forgetRemovedJob(jobID) }
            var st = state(for: jobID)
            st.isRunning = false
            st.throughputBytesPerSec = 0
            st.lastBackup = result.finishedAt
            if let history { st.apply(history) }
            states[jobID] = st
            updateFreeSpace(jobID)
            deferredCount = result.deferredCount
            succeeded = true
        } catch {
            guard jobs.contains(where: { $0.id == jobID }) else { return forgetRemovedJob(jobID) }
            var st = state(for: jobID)
            st.isRunning = false
            st.throughputBytesPerSec = 0
            st.lastError = BackupErrorMessage.describe(error)
            states[jobID] = st
            deferredCount = 0
            succeeded = false
        }
        let ended = Date()
        let next = schedulers[jobID, default: PassScheduler()]
            .passFinished(now: ended, duration: ended.timeIntervalSince(started),
                          deferredCount: deferredCount, succeeded: succeeded)
        perform(next, for: jobID)
    }

    /// A job removed while its pass ran: drop what the pass would otherwise write back.
    private func forgetRemovedJob(_ jobID: UUID) {
        schedulers[jobID] = nil
        meters[jobID] = nil
        states[jobID] = nil
    }

    private func applyProgress(_ p: BackupProgress, for jobID: UUID) {
        var meter = meters[jobID] ?? ThroughputMeter()
        meter.update(totalBytes: p.bytesCopied, now: Date())
        meters[jobID] = meter
        guard var st = states[jobID] else { return }
        st.progress = p
        st.throughputBytesPerSec = meter.bytesPerSecond
        states[jobID] = st
    }

    private func updateFreeSpace(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let info = try? Syscalls.volumeInfo(at: job.destination.path)
        var st = state(for: jobID)
        st.destinationFreeBytes = info?.freeBytes
        st.destinationTotalBytes = info?.totalBytes
        states[jobID] = st
    }

    // MARK: - History

    /// Load the timeline of all jobs (call at launch).
    func refreshAllHistory() {
        for job in jobs {
            let j = job
            Task {
                // Drop orphaned 0-file inProgress rows left by a previous run — never a row of a pass
                // this run has already started (the launch catch-up pass may beat this cleanup).
                await runner.cleanupIncompleteSnapshots(for: j, startedBefore: launchedAt)
                loadHistory(for: j)
            }
        }
    }

    /// Refresh destination free space for all jobs (e.g. when the menu bar opens).
    func refreshMetrics() {
        for job in jobs { updateFreeSpace(job.id) }
    }

    /// Free/total space per destination VOLUME, aggregated across jobs that target the same disk.
    /// Volumes that aren't mounted (e.g. a disconnected NAS) are skipped.
    func destinationUsages() -> [DestinationUsage] {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeNameKey]
        var byVolume: [String: DestinationUsage] = [:]
        for job in jobs {
            guard let rv = try? job.destination.resourceValues(forKeys: keys),
                  let volumeURL = rv.volume else { continue }
            let mount = volumeURL.path
            if byVolume[mount] != nil {
                byVolume[mount]?.jobCount += 1
            } else {
                // Free/total via statfs (Syscalls.volumeInfo) — the SAME source the detail pane uses,
                // so the footer matches it. NOT volumeAvailableCapacityForImportantUsage, which returns
                // 0 on SMB/NAS network volumes (showed "Zero KB free" with a full red bar).
                guard let info = try? Syscalls.volumeInfo(at: job.destination.path) else { continue }
                byVolume[mount] = DestinationUsage(
                    id: mount,
                    name: rv.volumeName ?? volumeURL.lastPathComponent,
                    freeBytes: info.freeBytes,
                    totalBytes: info.totalBytes,
                    jobCount: 1)
            }
        }
        return byVolume.values.sorted { $0.name < $1.name }
    }

    private func loadHistory(for job: BackupJob) {
        let jobID = job.id
        Task {
            guard let history = try? await runner.history(for: job) else { return }
            var st = state(for: jobID)
            st.apply(history)
            states[jobID] = st
        }
    }

    // MARK: - Restore

    /// Lists a restore point item by item, for the restore UI (nil for encrypted snapshots).
    func browser(jobID: UUID, point: RestorePoint, sourceName: String) -> (any RestoreBrowser)? {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return nil }
        return runner.browser(job: job, point: point, sourceName: sourceName)
    }

    /// Restore selected items of a restore point into a target directory (runs off the main actor).
    func restore(jobID: UUID, point: RestorePoint, sourceName: String,
                 relPaths: [String], to target: URL, conflict: RestoreEngine.ConflictPolicy,
                 progress: @escaping @Sendable (Int) -> Void) async throws -> RestoreEngine.Outcome {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return RestoreEngine.Outcome() }
        return try await runner.restore(job: job, point: point, sourceName: sourceName,
                                        relPaths: relPaths, to: target, conflict: conflict, progress: progress)
    }

    /// Restore an entire encrypted snapshot into a target folder.
    func restoreEncrypted(jobID: UUID, snapshotDirName: String, to target: URL) async throws {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        try await runner.restoreEncrypted(job: job, snapshotID: snapshotDirName, to: target)
    }

    // MARK: - Encryption migration

    /// How many plaintext restore points a job still has (used to decide whether to migrate).
    func plaintextSnapshotCount(_ jobID: UUID) async -> Int {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return 0 }
        return await runner.plaintextSnapshotCount(for: job)
    }

    /// Dismiss the post-migration success note.
    func clearMigrationMessage(_ jobID: UUID) {
        var s = state(for: jobID)
        s.migrationMessage = nil
        states[jobID] = s
    }

    /// Migrate a job's plaintext restore points into its encrypted repo (off-main), surfacing progress and
    /// keeping the plaintext intact if anything fails.
    func migrateToEncrypted(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        cancelArmedPass(jobID)   // pending work carries over to the migration's end (PassScheduler)
        schedulers[jobID, default: PassScheduler()].workStarted(.migration)
        var st = state(for: jobID)
        st.isMigrating = true
        st.migrationProgress = MigrationProgress(done: 0, total: 0)
        st.lastError = nil
        states[jobID] = st

        let progress: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor [weak self] in
                guard var s = self?.states[jobID] else { return }
                s.migrationProgress = MigrationProgress(done: done, total: total)
                self?.states[jobID] = s
            }
        }
        Task {
            var succeeded = false
            do {
                try await runner.migrateToEncrypted(job: job, progress: progress)
                loadHistory(for: job)
                succeeded = true
            } catch {
                var s = state(for: jobID)
                s.lastError = "Migration stopped — your plaintext backups are safe. " + BackupErrorMessage.describe(error)
                states[jobID] = s
            }
            guard jobs.contains(where: { $0.id == jobID }) else { return forgetRemovedJob(jobID) }
            var s = state(for: jobID)
            s.isMigrating = false
            s.migrationProgress = nil
            if succeeded { s.migrationMessage = "Encryption complete — plaintext backups converted and removed." }
            states[jobID] = s
            updateFreeSpace(jobID)
            perform(schedulers[jobID, default: PassScheduler()].migrationFinished(now: Date()), for: jobID)
        }
    }

    // MARK: - Realtime monitoring

    /// Start FSEvents watchers for all enabled realtime jobs (call at launch), each with one catch-up
    /// pass: changes made while SpectArk was not running produced no events we could have seen.
    func startMonitoring() {
        for job in jobs where job.isEnabled {
            guard case .realtime = job.trigger else { continue }
            startWatcher(for: job)
            handleChange(job.id)
        }
        startScheduleTicker()
    }

    /// Periodically fire interval-triggered jobs that have come due (also catches missed runs).
    private func startScheduleTicker() {
        scheduleTicker?.cancel()
        scheduleTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                self?.checkSchedules()
            }
        }
    }

    private func checkSchedules() {
        let now = Date()
        for job in jobs where job.isEnabled {
            guard case .interval(let spec) = job.trigger else { continue }
            // A busy job is re-checked on the next tick; queueing a follow-up here would run a
            // redundant pass right after the one that is already making it current.
            guard schedulers[job.id]?.isBusy != true else { continue }
            let last = state(for: job.id).lastBackup
            if Scheduler.isDue(spec: spec, lastBackup: last, now: now) {
                runNow(job.id)
            }
        }
    }

    private func startWatcher(for job: BackupJob) {
        let jobID = job.id
        let filter = ChangeFilter(sources: job.sources, exclusions: BackupExclusions(job: job))
        let watcher = FolderWatcher(paths: job.sources.map(\.path),
                                    isRelevant: { filter.containsRelevantChange($0) }) { [weak self] in
            Task { @MainActor in self?.handleChange(jobID) }
        }
        watcher.start()
        watchers[jobID] = watcher
    }

    /// Stop watching a job's sources. An armed pass is kept: after a settings edit it still runs,
    /// reading the job's current config when it fires.
    private func stopWatcher(_ id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
    }

    /// A relevant change arrived (or a catch-up is due).
    private func handleChange(_ jobID: UUID) {
        guard jobs.contains(where: { $0.id == jobID }) else { return }
        perform(schedulers[jobID, default: PassScheduler()].changeArrived(now: Date()), for: jobID)
    }

    // MARK: - Performing scheduler actions

    private func perform(_ action: PassScheduler.Action, for jobID: UUID) {
        switch action {
        case .none:
            break
        case let .start(quietWindow, requested):
            startPass(jobID, quietWindow: quietWindow, requested: requested)
        case .arm(let delay, _):   // the scheduler remembers the armed quiet window itself
            arm(jobID, delay: delay)
        }
    }

    /// (Re)arm the job's single automatic-pass timer — only for jobs that run on changes.
    private func arm(_ jobID: UUID, delay: TimeInterval) {
        guard let job = jobs.first(where: { $0.id == jobID }), Self.runsOnChanges(job) else {
            cancelArmedPass(jobID)
            schedulers[jobID]?.automaticRunsStopped()
            return
        }
        armedPasses[jobID]?.cancel()
        armedPasses[jobID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.armedPasses[jobID] = nil
            guard let job = self.jobs.first(where: { $0.id == jobID }), Self.runsOnChanges(job) else {
                self.schedulers[jobID]?.automaticRunsStopped()
                return
            }
            self.perform(self.schedulers[jobID, default: PassScheduler()].armedPassFired(), for: jobID)
        }
    }

    private func cancelArmedPass(_ id: UUID) {
        armedPasses[id]?.cancel()
        armedPasses[id] = nil
    }
}

extension JobRuntimeState {
    /// Take over what the destination says about the job's backups. `lastBackup` only moves forward:
    /// a pass that just finished may be newer than anything the timeline records.
    mutating func apply(_ history: BackupHistory) {
        restorePoints = history.points
        storageBytes = history.storageBytes
        if let last = history.lastBackup { lastBackup = max(lastBackup ?? last, last) }
    }
}
