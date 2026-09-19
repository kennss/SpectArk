//
//  @file        CaptureEngine.swift
//  @description One capture pass of the history engine: bring the mirror (current/) up to date with the
//               source, moving superseded versions that some checkpoint contains into versions/, and
//               seal a checkpoint when the 15-minute spacing allows. Every filesystem change is logged
//               as an intent first, so an interrupted pass is repaired on the next open.
//               Design: docs/INCREMENTAL_ENGINE_DESIGN.md §3.2–3.5.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - What to compare comes from the FSEvents journal (ChangeJournal): only directories whose contents
//    changed since the stored cursor, one level each. A full walk happens without a usable cursor, when
//    the source folder is no longer the verified directory (inode), after a settings or rules change,
//    when events were lost, and once a day. Why a source is walked in full is logged (subsystem
//    ai.calidalab.spectabackup, category history): a full walk of a large source is slow, and the reason
//    is otherwise gone once the pass has moved the cursor on. So is a replay that starts from a journal hint
//    (how far past the stored cursor).
//  - The journal only says where to look. A reported directory is compared as itself only if its path
//    reaches it without a symlink and in the letter case on disk (realpath), it is not excluded, and this
//    pass is not removing it; otherwise its parent's listing decides. A directory is compared whole when
//    it is new, or its source inode differs from the one recorded when its subtree was last compared
//    completely (another directory under the same name, or never finished — e.g. an interrupted pass).
//    Those inodes are recorded only by `finishPass`, i.e. once the pass has succeeded.
//  - Cost: the reported directories plus work proportional to the changes. Nothing is cloned.
//  - Apply order: all removals (deepest first), then additions in walk order (parents first), in
//    batches: log intents (commit) → filesystem steps with plain fsync → sync touched directories →
//    resolve (commit = F_FULLFSYNC). A catalog row never points at data not yet on stable storage.
//  - Put = copy the source to a temp beside the target, fsync it, retire the old item (move it to
//    versions/ if a checkpoint contains it, else unlink it), rename the temp over the target.
//  - A copy is checked against the source (type, size, mtime, ctime, inode just before and just after it):
//    one whose source moved — since the plan judged it settled, or while it was copied — may be torn, so
//    it is dropped, the old copy stays, and the file is deferred like one still in its quiet window (the
//    settle pass follows). A settle pass (no quiet window) copies again, up to `settleCopyAttempts`, then
//    keeps the last copy — a file written without pause must still be backed up — recorded as of just
//    before that copy, so the next pass sees the change and copies it again. What is recorded is what was
//    copied: the stamp from just before the copy, not the plan's. The copy
//    drops the source's lock flags (UF_IMMUTABLE/UF_APPEND forbid those renames); the catalog records
//    them and restore puts them back.
//  - Recovery decides each leftover intent from the disk: temp present? target still the old inode?
//    old already retired? Roll forward only when the new file is fully in place; otherwise roll back
//    and let the next pass redo the work.
//  - Nothing is ever written or removed through a symlink inside current/: before each operation the
//    parent's realpath must be the parent itself (MirrorGuard). The plan never produces such a path;
//    the guard covers the source changing between planning and applying, and recovery rolls back an
//    intent whose parent does not resolve inside current/.
//  - `faultHook` exists for the crash-recovery tests: throwing from it simulates a crash at that step.
//

import Darwin
import Foundation
import os

struct CaptureOutcome: Sendable {
    /// Items added, replaced or removed in current/.
    let changedCount: Int
    /// Changed files left for a later pass because they were still being written (quiet window).
    let deferredCount: Int
    let bytesCopied: Int64
    /// Checkpoints sealed by this pass, oldest first (at most two: a leftover state, then this one).
    let sealed: [HistoryCheckpoint]
    /// Intents of an interrupted earlier pass that this pass settled first.
    let recoveredIntents: Int
    /// At least one source was walked completely (no usable journal span); otherwise only the
    /// directories the journal reported were compared.
    let fullScan: Bool
    /// Directory listings and subtree walks compared with the catalog.
    let comparedDirectories: Int
    /// When the pass finished: current/ matched the source as of this moment.
    let finishedAt: Date
    /// The journal cursors the pass stored, per source name (none for a source without a journal).
    var journalCursors: [String: JournalCursor] = [:]
}

enum CaptureError: Error, CustomStringConvertible {
    /// A path's parent in current/ resolves elsewhere (a symlink or a letter-case variant on the way).
    case pathEscapesMirror(String)

    var description: String {
        switch self {
        case let .pathEscapesMirror(path):
            return "cannot place \(path) in the backup: a folder on its way is a link or differs only in letter case"
        }
    }
}

struct CaptureEngine: Sendable {

    /// Checkpoints are at least this far apart (docs §3.3).
    static let checkpointSpacing: TimeInterval = 15 * 60
    /// Intents logged and resolved per commit.
    static let batchSize = 500

    /// Filesystem steps of one intent, for the crash-recovery tests. `copying`: a copy is done and its
    /// source not yet looked at again — where a writer changing the source mid-copy is simulated.
    enum Step: Sendable {
        case logged, copying, copied, oldRetired, renamed
    }

    /// Copies of a file that keeps changing, in a settle pass, before the last one is kept as it is.
    static let settleCopyAttempts = 3

    let layout: HistoryLayout
    var faultHook: (@Sendable (Step, String) throws -> Void)?

    init(layout: HistoryLayout, faultHook: (@Sendable (Step, String) throws -> Void)? = nil) {
        self.layout = layout
        self.faultHook = faultHook
    }

    // MARK: - Pass

    /// Run one capture pass. `forceCheckpoint` (Back Up Now) seals regardless of spacing. `journalHints`:
    /// per source name, a later cursor a replay may start from (JournalCursor.advanced).
    func runPass(job: BackupJob,
                 quietWindow: TimeInterval,
                 forceCheckpoint: Bool,
                 journalHints: [String: JournalHint] = [:],
                 now: () -> Date = { Date() },
                 progress: (BackupProgress) -> Void = { _ in }) throws -> CaptureOutcome {
        let fm = FileManager.default
        try fm.createDirectory(atPath: layout.currentRoot, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: layout.versionsRoot, withIntermediateDirectories: true)
        let store = try HistoryStore(path: layout.catalogPath)

        let recovered = try recover(store)
        // A pristine catalog owns nothing: anything in current/ or versions/ is the leftover of an
        // interrupted seed (HistorySeeder) and would otherwise linger untracked.
        if recovered == 0, try store.isPristine() { try HistorySeeder(layout: layout).clearLeftovers() }
        if try !store.mirrorLocksChecked() { try unlockMirror(store) }
        var sealed: [HistoryCheckpoint] = []

        // A state the previous pass left unsealed becomes a checkpoint once spacing allows (docs §3.3.2).
        // Not after recovery: the recovered changes belong to an interrupted pass, so current/ never
        // matched the source in that state — the end of this pass seals instead.
        if recovered == 0, try store.hasUnsealedChanges(), try spacingElapsed(store, at: now()) {
            sealed.append(try store.seal(at: try store.lastPassEnd() ?? now()))
        }

        let start = now()
        let scope = try discover(job: job, store: store, hints: journalHints, now: start)
        let plan = try makePlan(job: job, scope: scope, store: store, quietWindow: quietWindow)
        var stats = ApplyStats()
        for batch in stride(from: 0, to: plan.operations.count, by: Self.batchSize).map({
            Array(plan.operations[$0..<min($0 + Self.batchSize, plan.operations.count)])
        }) {
            try apply(batch, store: store, settling: quietWindow == 0, stats: &stats, progress: progress)
        }

        let end = now()
        try store.finishPass(end: end, cursors: scope.cursors, carried: Array(plan.carried.union(stats.carried)).sorted {
            ($0.source, $0.path) < ($1.source, $1.path)
        }, fingerprint: scope.fingerprint, fullScanAt: scope.everySourceFullyScanned ? start : nil,
           verifiedDirectories: plan.verifiedDirectories)
        if try store.hasUnsealedChanges(), try forceCheckpoint || spacingElapsed(store, at: end) {
            sealed.append(try store.seal(at: end))
        }
        return CaptureOutcome(changedCount: stats.changed, deferredCount: plan.deferredCount + stats.deferred,
                              bytesCopied: stats.bytesCopied, sealed: sealed, recoveredIntents: recovered,
                              fullScan: !scope.fullyScannedSources.isEmpty,
                              comparedDirectories: plan.comparedDirectories, finishedAt: end,
                              journalCursors: scope.cursors.compactMapValues { $0 })
    }

    private func spacingElapsed(_ store: HistoryStore, at time: Date) throws -> Bool {
        guard let last = try store.lastCheckpoint() else { return true }
        return time.timeIntervalSince(last.time) >= Self.checkpointSpacing
    }

    // MARK: - Discover (docs §3.7)

    /// A full scan is forced at least this often, even when the journal looks complete.
    static let safetyScanInterval: TimeInterval = 86_400

    private static let log = Logger(subsystem: "ai.calidalab.spectabackup", category: "history")

    /// One directory to compare: one level, or its whole subtree.
    private struct ScanUnit {
        let source: URL
        let name: String
        /// Relative to the source folder; "" = the folder itself.
        let rel: String
        let recursive: Bool
    }

    private struct Scope {
        var units: [ScanUnit] = []
        var cursors: [String: JournalCursor?] = [:]
        var fingerprint: String
        var fullyScannedSources = Set<String>()
        var everySourceFullyScanned = true
    }

    /// The settings the stored state was captured with. A different fingerprint means the set of
    /// backed-up items may differ without any file event (exclusions, sources, the app's built-in
    /// rules): full scan.
    static func fingerprint(of job: BackupJob) -> String {
        (job.sources.map { "source=" + $0.path }
            + ["artifacts=\(job.skipsBuildArtifacts)", "rules=\(BackupExclusions.rulesVersion)"]
            + job.excludeGlobs.map { "glob=" + $0 }).joined(separator: "\n")
    }

    private func discover(job: BackupJob, store: HistoryStore, hints: [String: JournalHint],
                          now: Date) throws -> Scope {
        let fingerprint = Self.fingerprint(of: job)
        let settingsChanged = try store.settingsFingerprint() != fingerprint
        let safetyDue = try store.lastFullScan().map { now.timeIntervalSince($0) >= Self.safetyScanInterval } ?? true
        let carried = try store.carriedDirectories()
        let exclusions = BackupExclusions(job: job)
        var scope = Scope(fingerprint: fingerprint)

        for source in job.sources {
            let name = source.lastPathComponent
            let cursorAtStart = ChangeJournal.cursorNow(for: source)   // before anything is read
            let recorded = try store.journalCursor(for: name)
            let stored = recorded?.advanced(to: hints[name])
            if let recorded, let stored, stored != recorded {
                Self.log.notice("journal replay of \(name, privacy: .public) starts from a quiet check, \(stored.eventID - recorded.eventID) events past the stored cursor")
            }
            let changes: JournalChanges
            if settingsChanged {
                changes = .fullScan(reason: "settings or built-in rules changed")
            } else if safetyDue {
                changes = .fullScan(reason: "daily safety scan")
            } else if let stored {
                changes = try rootIsVerified(source, name: name, store: store)
                    ? ChangeJournal.changes(in: source, since: stored, exclusions: exclusions)
                    : .fullScan(reason: "source folder is not the verified directory")
            } else {
                changes = .fullScan(reason: "no cursor stored")
            }
            switch changes {
            case let .fullScan(reason):
                Self.log.notice("full scan of \(name, privacy: .public): \(reason, privacy: .public)")
                scope.units.append(ScanUnit(source: source, name: name, rel: "", recursive: true))
                scope.cursors.updateValue(cursorAtStart, forKey: name)   // nil (no journal) clears it
                scope.fullyScannedSources.insert(name)
            case let .directories(dirty, lastEventID):
                scope.everySourceFullyScanned = false
                for (rel, recursive) in dirty {
                    scope.units.append(ScanUnit(source: source, name: name, rel: rel, recursive: recursive))
                }
                for directory in carried where directory.source == name {
                    scope.units.append(ScanUnit(source: source, name: name, rel: directory.path, recursive: false))
                }
                if let stored {
                    scope.cursors[name] = JournalCursor(eventID: max(lastEventID ?? 0, stored.eventID),
                                                        volumeUUID: stored.volumeUUID)
                }
            }
        }
        return scope
    }

    /// The source folder is still the directory the catalog was last fully compared with. Replacing it
    /// (or a folder above it) leaves no events under its path, so only its identity can tell.
    private func rootIsVerified(_ source: URL, name: String, store: HistoryStore) throws -> Bool {
        guard let entry = try store.entry(at: name), entry.kind == .directory, entry.sourceIno != 0,
              let identity = try? FileWalker.identity(of: source.path) else { return false }
        return UInt64(identity.ino) == entry.sourceIno
    }

    // MARK: - Plan

    private enum Operation {
        case addDirectory(path: String)
        case put(path: String, source: String, kind: HistoryItemKind, size: Int64, mtimeNs: Int64,
                 lockFlags: UInt32, old: HistoryEntry?)
        case remove(entry: HistoryEntry)
    }

    private struct Plan {
        var operations: [Operation] = []
        var deferredCount = 0
        var carried = Set<HistoryStore.CarriedDirectory>()
        var comparedDirectories = 0
        /// Directories whose whole subtree was compared: catalog path → source inode.
        var verifiedDirectories: [String: UInt64] = [:]
    }

    private func makePlan(job: BackupJob, scope: Scope, store: HistoryStore, quietWindow: TimeInterval) throws -> Plan {
        let builder = PlanBuilder(store: store, exclusions: BackupExclusions(job: job))
        // A source dropped from the job leaves current/.
        let names = Set(job.sources.map(\.lastPathComponent))
        for (path, entry) in try store.entryChildren(of: "") where !names.contains(path) {
            try builder.removeTree(entry)
        }
        for unit in scope.units.sorted(by: { ($0.name, $0.rel) < ($1.name, $1.rel) }) {
            let session = SourceSnapshotProvider.beginSession(for: unit.source, quietWindow: quietWindow)
            defer { session.cleanup() }
            try builder.compare(unit, session: session)
        }
        return builder.plan
    }

    /// Compares scan units with the catalog and collects the operations that make current/ match.
    private final class PlanBuilder {
        private let store: HistoryStore
        private let exclusions: BackupExclusions
        private var additions: [Operation] = []
        private var removals: [String: HistoryEntry] = [:]
        private var planned = Set<String>()        // paths already added (no duplicates across units)
        private var comparedLevels = Set<String>()
        private var covered: [String] = []         // catalog paths whose whole subtree was compared
        private var verified: [String: UInt64] = [:]
        private var canonicalRoots: [String: String?] = [:]   // source name → realpath of its folder
        private var deferredCount = 0
        private var carried = Set<HistoryStore.CarriedDirectory>()
        private var compared = 0

        init(store: HistoryStore, exclusions: BackupExclusions) {
            self.store = store
            self.exclusions = exclusions
        }

        var plan: Plan {
            // Removals deepest first so a directory is empty when its turn comes; then additions in
            // discovery order (parents before children).
            let orderedRemovals = removals.values.sorted { lhs, rhs in
                let l = lhs.path.split(separator: "/").count, r = rhs.path.split(separator: "/").count
                return l != r ? l > r : lhs.path > rhs.path
            }
            return Plan(operations: orderedRemovals.map { .remove(entry: $0) } + additions,
                        deferredCount: deferredCount, carried: carried, comparedDirectories: compared,
                        verifiedDirectories: verified)
        }

        private func isCovered(_ path: String) -> Bool {
            covered.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        /// This pass removes `path` or a folder above it.
        private func isRemoved(_ path: String) -> Bool {
            var current = Substring(path)
            while true {
                if removals[String(current)] != nil { return true }
                guard let slash = current.lastIndex(of: "/") else { return false }
                current = current[..<slash]
            }
        }

        func compare(_ unit: ScanUnit, session: any SourceReadSession) throws {
            let catalogPath = unit.rel.isEmpty ? unit.name : unit.name + "/" + unit.rel
            guard !isCovered(catalogPath) else { return }
            let dir = unit.rel.isEmpty ? session.rootURL : session.rootURL.appendingPathComponent(unit.rel)

            if unit.rel.isEmpty {
                // The source folder itself (its identity was checked when the scope was discovered).
                if let own = try store.entry(at: catalogPath), own.kind != .directory { try removeTree(own) }
                if try store.entry(at: catalogPath)?.kind != .directory { addDirectory(catalogPath) }
                if unit.recursive {
                    try subtree(catalogPath, dir: dir, rel: unit.rel, name: unit.name, session: session)
                } else {
                    try level(catalogPath, dir: dir, rel: unit.rel, name: unit.name, session: session)
                }
                return
            }
            guard let entry = try store.entry(at: catalogPath), entry.kind == .directory,
                  let identity = trustedDirectory(unit, dir: dir, catalogPath: catalogPath, session: session) else {
                // New, gone, of another kind, reached through a symlink or spelled in another letter case,
                // excluded, or removed by this pass: the parent's listing tells what is there.
                let parent = (unit.rel as NSString).deletingLastPathComponent
                try compare(ScanUnit(source: unit.source, name: unit.name, rel: parent, recursive: false),
                            session: session)
                return
            }
            if unit.recursive || entry.sourceIno != identity {
                try subtree(catalogPath, dir: dir, rel: unit.rel, name: unit.name, session: session)
            } else {
                try level(catalogPath, dir: dir, rel: unit.rel, name: unit.name, session: session)
            }
        }

        /// The source inode of the directory a unit names, if the unit may be compared as that directory:
        /// its path reaches it without a symlink and in the letter case stored on disk (realpath(3)
        /// returns stored names), it is a directory, nothing on the path is excluded, and this pass is not
        /// removing it or a folder above it.
        private func trustedDirectory(_ unit: ScanUnit, dir: URL, catalogPath: String,
                                      session: any SourceReadSession) -> UInt64? {
            guard !isRemoved(catalogPath) else { return nil }
            if canonicalRoots[unit.name] == nil {
                canonicalRoots[unit.name] = .some(SourceSpellings.canonical(session.rootURL.path))
            }
            guard let root = canonicalRoots[unit.name] ?? nil,
                  SourceSpellings.canonical(dir.path) == root + "/" + unit.rel else { return nil }
            var st = Darwin.stat()
            guard lstat(dir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
            guard exclusions.excludedComponent(of: unit.rel, root: session.rootURL.path,
                                               lastIsDirectory: true) == nil else { return nil }
            return UInt64(st.st_ino)
        }

        private func level(_ catalogPath: String, dir: URL, rel: String, name: String,
                           session: any SourceReadSession) throws {
            guard comparedLevels.insert(catalogPath).inserted else { return }
            compared += 1
            guard let items = try FileWalker.list(dir, relBase: rel, exclusions: exclusions,
                                                  toleratingVanishedEntries: true) else {
                return   // vanished since the event; the parent's own event covers it
            }
            let existing = try store.entryChildren(of: catalogPath)
            var seen = Set<String>()
            for item in items {
                let path = name + "/" + item.relativePath
                seen.insert(path)
                try consider(item, path: path, existing: existing[path], name: name, session: session,
                             inLevel: true)
            }
            for (path, entry) in existing where !seen.contains(path) { try removeTree(entry) }
        }

        private func subtree(_ catalogPath: String, dir: URL, rel: String, name: String,
                             session: any SourceReadSession) throws {
            guard !isCovered(catalogPath) else { return }
            covered.append(catalogPath)
            compared += 1
            let existing = try store.entries(under: catalogPath)
            var seen = Set<String>()
            var walked: [String: UInt64] = [:]
            do {
                walked[catalogPath] = UInt64(try FileWalker.identity(of: dir.path).ino)
                try FileWalker.walk(root: dir, relBase: rel, exclusions: exclusions,
                                    toleratingVanishedEntries: true) { item in
                    let path = name + "/" + item.relativePath
                    seen.insert(path)
                    if item.isDirectory && !item.isSymlink { walked[path] = UInt64(item.ino) }
                    try consider(item, path: path, existing: existing[path], name: name, session: session,
                                 inLevel: false)
                }
            } catch where !rel.isEmpty && FileWalker.vanished(dir.path, expectDirectory: true)
                        && !FileWalker.vanished(session.rootURL.path, expectDirectory: true) {
                return   // this subtree vanished mid-walk (the source is fine); its own events cover it
            }
            for (path, entry) in existing where !seen.contains(path) { removals[path] = entry }
            // Only a completed walk verifies these directories.
            verified.merge(walked) { _, new in new }
        }

        private func consider(_ item: FileEntry, path: String, existing: HistoryEntry?, name: String,
                              session: any SourceReadSession, inLevel: Bool) throws {
            let kind: HistoryItemKind = item.isSymlink ? .symlink : (item.isDirectory ? .directory : .file)
            var old = existing
            if let existing, existing.kind != kind {
                try removeTree(existing)
                old = nil
            }
            if kind == .directory {
                if old == nil { addDirectory(path) }
                // A one-level comparison descends into a directory that is new, or that is not the one
                // whose subtree was last compared (inode changed, or never compared whole). A subtree walk
                // descends by itself.
                if inLevel, old?.sourceIno != UInt64(item.ino) {
                    try subtree(path, dir: item.url, rel: item.relativePath, name: name, session: session)
                }
                return
            }
            if let old, old.size == item.size, old.mtimeNs == item.mtimeNs { return }   // unchanged
            if session.shouldDefer(modificationDate: item.mtime) {
                deferredCount += 1   // keep the current copy until it settles; compare this folder again
                carried.insert(.init(source: name, path: (item.relativePath as NSString).deletingLastPathComponent))
                return
            }
            guard planned.insert(path).inserted else { return }
            additions.append(.put(path: path, source: item.url.path, kind: kind, size: item.size,
                                  mtimeNs: item.mtimeNs, lockFlags: item.flags & Syscalls.lockFlags, old: old))
        }

        func removeTree(_ entry: HistoryEntry) throws {
            removals[entry.path] = entry
            guard entry.kind == .directory else { return }
            for (path, descendant) in try store.entries(under: entry.path) { removals[path] = descendant }
        }

        private func addDirectory(_ path: String) {
            guard planned.insert(path).inserted else { return }
            additions.append(.addDirectory(path: path))
        }
    }

    // MARK: - Apply

    private struct ApplyStats {
        var changed = 0
        var bytesCopied: Int64 = 0
        var processed = 0
        /// Files whose copy was dropped as possibly torn, and the folders to compare again for them.
        var deferred = 0
        var carried = Set<HistoryStore.CarriedDirectory>()
    }

    /// `settling`: a pass without a quiet window (a settle pass, Back Up Now) — see copyVerified.
    private func apply(_ batch: [Operation], store: HistoryStore, settling: Bool, stats: inout ApplyStats,
                       progress: (BackupProgress) -> Void) throws {
        let drafts = batch.map { op -> HistoryStore.IntentDraft in
            switch op {
            case let .addDirectory(path):
                return .init(op: .addDirectory, path: path, old: nil, newKind: .directory, newSize: 0, newMtimeNs: 0)
            case let .put(path, _, kind, size, mtimeNs, lockFlags, old):
                return .init(op: .put, path: path, old: old, newKind: kind, newSize: size, newMtimeNs: mtimeNs,
                             newLockFlags: lockFlags)
            case let .remove(entry):
                return .init(op: .remove, path: entry.path, old: entry, newKind: entry.kind, newSize: 0, newMtimeNs: 0)
            }
        }
        let intents = try store.logIntents(drafts)

        var resolutions: [IntentResolution] = []
        var touched = Set<String>()
        var mirror = MirrorGuard(layout: layout)
        for (intent, op) in zip(intents, batch) {
            try fault(.logged, intent.path)
            try mirror.check(parentOf: intent.path)
            let target = layout.current(intent.path)
            touched.insert((target as NSString).deletingLastPathComponent)
            switch op {
            case .addDirectory:
                try createDirectoryIfNeeded(target)
                resolutions.append(.applied(intentID: intent.id, path: intent.path,
                                            entry: try newEntry(intent, at: target), retired: nil))
            case let .put(_, source, kind, _, _, _, _):
                let temp = layout.temp(for: intent.path, intentID: intent.id)
                let copied: SourceStamp?
                do {
                    copied = try copyVerified(source, to: temp, intent: intent, settling: settling)
                } catch _ where FileWalker.vanished(source) {
                    // Deleted since the plan: the path is simply gone now.
                    try? FileManager.default.removeItem(atPath: temp)
                    guard intent.old != nil else {
                        resolutions.append(.rollback(intentID: intent.id))
                        continue
                    }
                    let lock = try retireOld(intent, touched: &touched)
                    resolutions.append(.applied(intentID: intent.id, path: intent.path, entry: nil,
                                                retired: retiredIfKept(intent, lockFlags: lock)))
                    stats.changed += 1
                    continue
                }
                guard let copied else {
                    // Possibly torn: dropped; the old copy stays until the file settles.
                    try? FileManager.default.removeItem(atPath: temp)
                    resolutions.append(.rollback(intentID: intent.id))
                    stats.deferred += 1
                    stats.carried.insert(Self.carriedDirectory(of: intent.path))
                    continue
                }
                try Syscalls.unlock(temp)
                if kind != .symlink { try Syscalls.syncToDevice(temp) }
                try fault(.copied, intent.path)
                var lock: UInt32 = 0
                if intent.old != nil { lock = try retireOld(intent, touched: &touched) }
                try fault(.oldRetired, intent.path)
                try Syscalls.atomicRename(temp, to: target)
                try fault(.renamed, intent.path)
                if kind == .symlink { mirror.reset() }
                resolutions.append(.applied(intentID: intent.id, path: intent.path,
                                            entry: try newEntry(intent, at: target, copied: copied),
                                            retired: retiredIfKept(intent, lockFlags: lock)))
                stats.bytesCopied += copied.size
            case .remove:
                var lock: UInt32 = 0
                if intent.old?.kind == .directory {
                    try removeDirectory(target)
                    mirror.reset()
                } else {
                    lock = try retireOld(intent, touched: &touched)
                }
                resolutions.append(.applied(intentID: intent.id, path: intent.path, entry: nil,
                                            retired: retiredIfKept(intent, lockFlags: lock)))
            }
            stats.changed += 1
            stats.processed += 1
            progress(BackupProgress(filesProcessed: stats.processed, bytesCopied: stats.bytesCopied,
                                    currentPath: intent.path))
        }

        for directory in touched where FileManager.default.fileExists(atPath: directory) {
            try Syscalls.syncToDevice(directory)
        }
        try store.resolve(resolutions)
    }

    /// Move the old item into versions/ when a checkpoint contains it, otherwise unlink it. An old item
    /// already missing from current/ (removed behind our back) has nothing to keep; the version row is
    /// then skipped (see retiredIfKept) rather than failing every future pass. A copy in current/ is never
    /// locked by the engine, but one can be (locked in Finder, or seeded by an earlier build): the lock is
    /// lifted — the inode is the mirror's own — and returned, to be kept with the version.
    private func retireOld(_ intent: HistoryIntent, touched: inout Set<String>) throws -> UInt32 {
        let target = layout.current(intent.path)
        guard inode(of: target) != nil else { return 0 }
        if intent.retainsOld {
            let lock = try Syscalls.flags(of: target) & Syscalls.lockFlags
            if lock != 0 { try Syscalls.unlock(target) }
            let shard = layout.versionShard(intent.storedName)
            try FileManager.default.createDirectory(atPath: shard, withIntermediateDirectories: true)
            try Syscalls.atomicRename(target, to: layout.version(intent.storedName))
            touched.insert(shard)
            return lock
        }
        try removeItem(target)
        return 0
    }

    private func retired(_ intent: HistoryIntent, lockFlags: UInt32 = 0) -> RetiredVersion? {
        guard intent.retainsOld, var old = intent.old else { return nil }
        old.lockFlags |= lockFlags
        return RetiredVersion(old: old, died: intent.generation,
                              stored: old.kind == .directory ? nil : intent.storedName)
    }

    /// The catalog row of an item just put in place. `copied`: the stamp of what was copied; without it
    /// (recovery after a crash) the plan's size and mtime are recorded — if the file changed since, the next
    /// pass sees the difference and copies it again.
    private func newEntry(_ intent: HistoryIntent, at target: String, copied: SourceStamp? = nil) throws -> HistoryEntry {
        var st = Darwin.stat()
        guard lstat(target, &st) == 0 else { throw InfraError(operation: "lstat", path: target, code: errno) }
        return HistoryEntry(path: intent.path, kind: intent.newKind, size: copied?.size ?? intent.newSize,
                            mtimeNs: copied?.mtimeNs ?? intent.newMtimeNs, born: intent.generation,
                            mirrorIno: UInt64(st.st_ino), lockFlags: intent.newLockFlags)
    }

    // MARK: - Verified copy

    /// What a copy is judged by. A source whose stamp moves while it is copied may have been copied torn.
    private struct SourceStamp: Equatable {
        let type: mode_t
        let size: Int64
        let mtimeNs: Int64
        let ctimeNs: Int64
        let ino: UInt64
        let dev: Int32

        init?(path: String) {
            var st = Darwin.stat()
            guard lstat(path, &st) == 0 else { return nil }
            type = st.st_mode & S_IFMT
            size = Int64(st.st_size)
            mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
            ctimeNs = Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec)
            ino = UInt64(st.st_ino)
            dev = st.st_dev
        }

        func isKind(_ kind: HistoryItemKind) -> Bool {
            switch kind {
            case .file: return type == S_IFREG
            case .symlink: return type == S_IFLNK
            case .directory: return type == S_IFDIR
            }
        }
    }

    /// Copy `source` to `temp` and return the stamp of what was copied, or nil when the copy may be torn
    /// (see the file notes). Throws, with the source gone, when it vanished.
    private func copyVerified(_ source: String, to temp: String, intent: HistoryIntent,
                              settling: Bool) throws -> SourceStamp? {
        for attempt in 1...Self.settleCopyAttempts {
            guard let before = SourceStamp(path: source) else {
                throw InfraError(operation: "lstat", path: source, code: errno)
            }
            // Something else is at the path now: the next pass plans it anew.
            guard before.isKind(intent.newKind) else { return nil }
            // Changed since the plan judged it settled: not judged again here.
            if !settling, before.size != intent.newSize || before.mtimeNs != intent.newMtimeNs { return nil }
            try Syscalls.copyItem(at: source, to: temp)
            try fault(.copying, intent.path)
            if SourceStamp(path: source) == before { return before }
            guard settling else { return nil }
            if attempt == Self.settleCopyAttempts { return before }   // kept as it is, recorded as of before
            try? FileManager.default.removeItem(atPath: temp)
        }
        return nil
    }

    /// The folder to compare again for a deferred item: its parent, as the plan records one (source, path).
    private static func carriedDirectory(of path: String) -> HistoryStore.CarriedDirectory {
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        let rel = parts.count > 1 ? parts[1] : ""
        return .init(source: parts[0], path: (rel as NSString).deletingLastPathComponent)
    }

    private func fault(_ step: Step, _ path: String) throws {
        try faultHook?(step, path)
    }

    // MARK: - Recovery

    /// Settle intents left by an interrupted pass. Returns how many there were.
    private func recover(_ store: HistoryStore) throws -> Int {
        let intents = try store.pendingIntents()
        guard !intents.isEmpty else { return 0 }
        var resolutions: [IntentResolution] = []
        var touched = Set<String>()
        for intent in intents {
            resolutions.append(try recoverOne(intent, touched: &touched))
        }
        for directory in touched where FileManager.default.fileExists(atPath: directory) {
            try Syscalls.syncToDevice(directory)
        }
        try store.resolve(resolutions)
        return intents.count
    }

    private func recoverOne(_ intent: HistoryIntent, touched: inout Set<String>) throws -> IntentResolution {
        // Refused by the mirror guard before any step: there is nothing on disk to settle.
        var mirror = MirrorGuard(layout: layout)
        guard (try? mirror.check(parentOf: intent.path)) != nil else { return .rollback(intentID: intent.id) }
        let target = layout.current(intent.path)
        let temp = layout.temp(for: intent.path, intentID: intent.id)
        let targetIno = inode(of: target)
        let targetIsOld = intent.old.map { targetIno == $0.mirrorIno } ?? false
        touched.insert((target as NSString).deletingLastPathComponent)
        let rollForward: (Bool) throws -> IntentResolution = { present in
            .applied(intentID: intent.id, path: intent.path,
                     entry: present ? try self.newEntry(intent, at: target) : nil,
                     retired: self.retiredIfKept(intent))
        }

        switch intent.op {
        case .addDirectory:
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: target, isDirectory: &isDir)
            return exists && isDir.boolValue ? try rollForward(true) : .rollback(intentID: intent.id)

        case .remove:
            if intent.old?.kind == .directory {
                return FileManager.default.fileExists(atPath: target) ? .rollback(intentID: intent.id) : try rollForward(false)
            }
            return targetIsOld ? .rollback(intentID: intent.id) : try rollForward(false)

        case .put:
            if inode(of: temp) != nil {
                if intent.old != nil && targetIno == nil {
                    // Copy finished (it precedes retiring the old item) and the old item is retired:
                    // only the final rename is missing.
                    try Syscalls.unlock(temp)
                    try Syscalls.atomicRename(temp, to: target)
                    return try rollForward(true)
                }
                if targetIno != nil && !targetIsOld && intent.old != nil {
                    // Not a state our step order produces (the old item retired yet something else at
                    // the target). Drop both: the path reads as removed and the next pass re-copies it.
                    try removeItem(temp)
                    try removeItem(target)
                    return try rollForward(false)
                }
                try removeItem(temp)       // possibly partial copy, old untouched: undo
                return .rollback(intentID: intent.id)
            }
            if targetIno != nil {
                return targetIsOld ? .rollback(intentID: intent.id) : try rollForward(true)
            }
            // No temp, no target: the source vanished and the old item was retired as a removal.
            return intent.old == nil ? .rollback(intentID: intent.id) : try rollForward(false)
        }
    }

    /// The retired old item, if it really reached versions/ (directories have nothing to move).
    private func retiredIfKept(_ intent: HistoryIntent, lockFlags: UInt32 = 0) -> RetiredVersion? {
        guard let version = retired(intent, lockFlags: lockFlags) else { return nil }
        guard let stored = version.stored else { return version }
        return inode(of: layout.version(stored)) != nil ? version : nil
    }

    /// Copies in current/ must never be locked (the engine renames and unlinks them). Catalogs from before
    /// lock flags were handled could have seeded locked copies: once per catalog, unlock them and record
    /// their flags, which restore then puts back.
    private func unlockMirror(_ store: HistoryStore) throws {
        var locks: [String: UInt32] = [:]
        try FileWalker.walk(root: URL(fileURLWithPath: layout.currentRoot, isDirectory: true),
                            exclusions: .includeEverything) { item in
            let lock = item.flags & Syscalls.lockFlags
            guard lock != 0 else { return }
            try Syscalls.unlock(item.url.path)
            locks[item.relativePath] = lock
        }
        try store.recordMirrorLocks(locks)
    }

    // MARK: - Filesystem helpers

    /// Checks that an operation's parent in current/ is itself: its realpath must be its own path under
    /// current/, so a symlink or a letter-case variant on the way can never redirect a write or removal.
    /// Checked parents are remembered until the batch puts a symlink or removes a directory.
    private struct MirrorGuard {
        private let layout: HistoryLayout
        private let root: String?
        private var checked = Set<String>()

        init(layout: HistoryLayout) {
            self.layout = layout
            root = SourceSpellings.canonical(layout.currentRoot)
        }

        /// Throws when the parent of `path` resolves anywhere but itself. A missing parent passes:
        /// nothing can be created or removed through it.
        mutating func check(parentOf path: String) throws {
            let parent = (path as NSString).deletingLastPathComponent
            guard !checked.contains(parent) else { return }
            guard let resolved = SourceSpellings.canonical(parent.isEmpty ? layout.currentRoot
                                                                          : layout.current(parent)) else { return }
            guard let root, resolved == (parent.isEmpty ? root : root + "/" + parent) else {
                throw CaptureError.pathEscapesMirror(path)
            }
            checked.insert(parent)
        }

        mutating func reset() {
            checked.removeAll()
        }
    }

    private func inode(of path: String) -> UInt64? {
        var st = Darwin.stat()
        return lstat(path, &st) == 0 ? UInt64(st.st_ino) : nil
    }

    private func createDirectoryIfNeeded(_ path: String) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    /// Remove a directory whose tracked children were already removed. Anything untracked left inside
    /// (e.g. a temp of a rolled-back intent) goes with it.
    private func removeDirectory(_ path: String) throws {
        guard inode(of: path) != nil else { return }
        if rmdir(path) == 0 { return }
        try removeItem(path)
    }

    private func removeItem(_ path: String) throws {
        try TreeRemoval.remove(path)
    }
}
