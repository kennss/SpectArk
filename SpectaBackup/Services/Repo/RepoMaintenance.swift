//
//  @file        RepoMaintenance.swift
//  @description Retention and garbage collection for an encrypted repo. The job's retention policy thins
//               its snapshots — the restore points (RepoTimeline) — as it thins plaintext history:
//               Automatic (Time Machine), keep N, keep N days, keep all, then the oldest dropped while the
//               quota is exceeded — and as many more as a disk short of space asks for (DiskSpace; `ladder`
//               tells it what each would free). Dropping a snapshot deletes its object; the data
//               only it referenced is reclaimed by collecting garbage: packs nothing references go, packs
//               partly dead are rewritten with their live blobs only, and trees nothing references go.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Never the newest snapshot. Every pass writes a snapshot (its changes are protected at once); the
//    history engine's 15-minute cadence then keeps a restore point at most every 15 minutes, plus each state
//    that was left alone (cadenceThinned), before the policy applies.
//  - What dropping a snapshot frees is exact: the blobs no kept snapshot references any more, counted per
//    distinct snapshot. Blobs and trees are numbered and each snapshot's references kept as a bitset, so a
//    large repo costs a few MB rather than a copy of every ID per snapshot. Sizes are ciphertext lengths.
//  - Order on disk, so an interruption leaks garbage at worst and never loses a referenced blob: the dropped
//    snapshots' objects (barrier); then what takes no writing — the index objects of packs nothing live is
//    in (barrier), those packs, packs no index lists, dead trees (barrier) — so a full disk gets space back
//    first; then packs partly dead: their live blobs into new packs (barrier), their index objects
//    (barrier), the packs. A blob found in two packs (a repack interrupted before the old pack went) counts
//    once; the other copy is garbage.
//  - A snapshot that cannot be read (its object or a tree of it) stops the collection and the space rules
//    — what it references is unknown — while the age, count and cadence rules go on; the caller tells the
//    user. It is never deleted on its own: it may only be unreadable for now.
//  - A pack no index object lists holds nothing any snapshot can reach (a snapshot is written only after
//    its packs' index): garbage.
//  - Blobs a tree references but no index lists (damage) are left to restore to report.
//  - Repacking rewrites a pack when at least a quarter of it is dead — or, under space pressure, when any of
//    it is. Live ciphertexts are copied as they are: a blob's ciphertext does not depend on its pack.
//  - Collecting reads every live tree, so the caller runs it at most once a day unless space is short;
//    until then a dropped snapshot's data stays on disk, unreachable.
//  - Free space is not a per-job rule: the disk keeps its reserve across all its jobs (DiskSpace). Under
//    pressure a run collects at once, its garbage counted first (it costs no restore point), then drops the
//    oldest snapshots it is asked for. The ladder and the run share one survey: the graph is read once.
//  - Runs with nothing else writing the repo (BackupRunner's turn).
//

import Foundation

struct RepoMaintenance: Sendable {

    /// Points where a test interrupts a collection.
    enum Step: Sendable {
        case snapshotsDropped, garbageRemoved, packsRewritten, indexesRemoved
    }

    /// Target size of a rewritten pack (as BlobStore's).
    static let packTargetSize = 32 * 1024 * 1024

    let backend: Backend
    let cipher: BlobCipher
    var faultHook: (@Sendable (Step) throws -> Void)?

    init(backend: Backend, keys: RepoKeys, faultHook: (@Sendable (Step) throws -> Void)? = nil) {
        self.backend = backend
        self.cipher = BlobCipher(keys: keys)
        self.faultHook = faultHook
    }

    struct Outcome: Equatable, Sendable {
        /// Snapshot IDs whose objects were deleted.
        var dropped: Set<String> = []
        /// Garbage was collected.
        var collected = false
        /// Pack bytes deleted, less the bytes rewritten.
        var reclaimedBytes: Int64 = 0
        /// Snapshots that could not be read: while any is there, nothing is collected and the space rules
        /// wait (what they reference is unknown). The age, count and cadence rules still apply.
        var unreadable: [String] = []
    }

    /// The disk is short of space (DiskSpace): collect now, rewriting every pack any part of which is dead,
    /// and drop `drops` more of the oldest snapshots the policy and the quota leave.
    struct Pressure: Equatable, Sendable {
        var drops = 0
    }

    /// What a run reads before deciding: the snapshot objects present, the index, and — when the space rules
    /// need it — every snapshot's references. Taken once for a ladder and the run that follows it.
    struct Survey: Sendable {
        let present: [String]
        let index: [PackFormat.IndexedPack]
        let graph: Graph?
    }

    func survey(needsGraph: Bool, needsIndex: Bool) async throws -> Survey {
        let prefix = "snapshots/"
        let present = try await backend.list(prefix: "snapshots").map { String($0.dropFirst(prefix.count)) }
        let index = needsGraph || needsIndex ? try await PackFormat.readIndex(backend: backend, cipher: cipher) : []
        return Survey(present: present, index: index, graph: needsGraph ? try await loadGraph(present, index: index) : nil)
    }

    /// Apply `policy` to the repo's `snapshots` (those the timeline could read). Garbage is collected when
    /// `collect` (the caller's schedule) — and always under `pressure`. What is kept is every snapshot object
    /// in the repo the plan did not drop, whether or not the caller listed it: one it could not read makes the
    /// collection stop, never lose its data. `protecting`: packs a failed pass wrote — kept whole, so the pass
    /// tried again reuses what it stored. `survey`: taken already (for the ladder), with the graph.
    func run(policy: RetentionPolicy, snapshots: [RepoSnapshotSummary], pressure: Pressure? = nil, collect: Bool,
             protecting protected: Set<String> = [], survey taken: Survey? = nil, now: Date,
             calendar: Calendar = .autoupdatingCurrent) async throws -> Outcome {
        let hasSpaceRules = policy.maxTotalBytes > 0 || pressure != nil
        let survey: Survey
        if let taken { survey = taken } else { survey = try await self.survey(needsGraph: hasSpaceRules, needsIndex: collect) }
        let present = survey.present, index = survey.index
        var graph = survey.graph
        let listed = Set(present)
        let candidates = snapshots.filter { listed.contains($0.id) }
        let blocked = graph?.unreadable ?? []
        // The space rules need every snapshot's references.
        let decision = Self.plan(policy: policy, snapshots: candidates, graph: blocked.isEmpty ? graph : nil,
                                 pressureDrops: pressure?.drops, now: now, calendar: calendar)

        var outcome = Outcome(dropped: decision.drop)
        for id in decision.drop.sorted() { try await backend.delete(key: "snapshots/\(id)") }
        if !decision.drop.isEmpty { try await backend.sync() }
        try faultHook?(.snapshotsDropped)

        let kept = present.filter { !decision.drop.contains($0) }
        // An unreadable snapshot the plan dropped no longer matters; one that stays blocks the collection.
        outcome.unreadable = blocked.filter { !decision.drop.contains($0) }
        guard collect || decision.spacePressure, outcome.unreadable.isEmpty else { return outcome }
        // Nothing kept: nothing to protect, and a listing that came back empty is no reason to delete everything.
        guard !kept.isEmpty else { return outcome }
        let packIndex = index.isEmpty ? try await PackFormat.readIndex(backend: backend, cipher: cipher) : index
        if graph == nil { graph = try await loadGraph(kept, index: packIndex) }
        guard let graph else { return outcome }
        let unreadableKept = graph.unreadable.filter { kept.contains($0) }
        guard unreadableKept.isEmpty else {
            outcome.unreadable = unreadableKept
            return outcome
        }
        outcome.reclaimedBytes = try await collectGarbage(graph: graph, kept: kept, index: packIndex,
                                                          repackAll: decision.spacePressure, protecting: protected)
        outcome.collected = true
        return outcome
    }

    /// The repo's side of a disk-wide reclamation (DiskSpace.Ladder): its garbage — what collecting now frees
    /// with no snapshot lost, the snapshots the policy and the quota drop included — then what dropping each
    /// of the oldest snapshots left would free, oldest first. nil when a snapshot cannot be read: what it
    /// references is unknown, so nothing is counted on.
    static func ladder(policy: RetentionPolicy, snapshots: [RepoSnapshotSummary], survey: Survey,
                       protecting protected: Set<String> = [], now: Date,
                       calendar: Calendar = .autoupdatingCurrent) -> (garbage: Int64, steps: [DiskSpace.Step])? {
        guard let graph = survey.graph, graph.unreadable.isEmpty else { return nil }
        let listed = Set(survey.present)
        var thinning = Thinning(policy: policy, snapshots: snapshots.filter { listed.contains($0.id) }, graph: graph,
                                now: now, calendar: calendar)
        // What protected packs hold that nothing kept references stays: it is no garbage to count on.
        var numbers: [Data: Int] = [:]
        for (number, id) in graph.blobIDs.enumerated() { numbers[id] = number }
        var kept: Int64 = 0
        for pack in survey.index where protected.contains(pack.packID) {
            for entry in pack.entries {
                if let number = numbers[entry.blobID], thinning.references[number] == 0 { kept += Int64(entry.length) }
            }
        }
        let garbage = max(0, thinning.garbage - kept)
        var steps: [DiskSpace.Step] = []
        while let step = thinning.dropOldest() { steps.append(step) }
        return (garbage, steps)
    }

    // MARK: - Plan

    struct Decision: Equatable, Sendable {
        var drop: Set<String> = []
        /// The quota is exceeded or the disk is short of space (before dropping): collect, repacking fully.
        var spacePressure = false
    }

    /// Which snapshots `policy` drops — and, for a disk short of space, `pressureDrops` more of the oldest.
    /// Pure: `graph` tells what each frees (needed only for the quota and the pressure drops).
    static func plan(policy: RetentionPolicy, snapshots: [RepoSnapshotSummary], graph: Graph?,
                     pressureDrops: Int? = nil, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Decision {
        guard !snapshots.isEmpty else { return Decision() }
        var thinning = Thinning(policy: policy, snapshots: snapshots, graph: graph, now: now, calendar: calendar)
        var decision = Decision()
        if let graph {
            // Pressure is what the disk says now: garbage not yet collected occupies it all the same.
            decision.spacePressure = pressureDrops != nil
                || (policy.maxTotalBytes > 0 && graph.packBytes > policy.maxTotalBytes)
            for _ in 0..<max(0, pressureDrops ?? 0) {
                guard thinning.dropOldest() != nil else { break }
            }
        }
        decision.drop = Set(thinning.dropped.map { thinning.ordered[$0].id })
        return decision
    }

    /// Snapshots being thinned: the cadence and the policy (at init), then the quota, then — one by one — the
    /// oldest kept, each time accounting for the blobs no kept snapshot references any more.
    private struct Thinning {
        let ordered: [RepoSnapshotSummary]
        /// Positions in `ordered` dropped, and kept (ascending).
        var dropped: Set<Int>
        var kept: [Int]
        let graph: Graph?
        /// Per blob: how many kept snapshots reference it.
        var references: [Int32] = []
        /// Bytes of the blobs kept snapshots reference.
        var usage: Int64 = 0

        init(policy: RetentionPolicy, snapshots: [RepoSnapshotSummary], graph: Graph?, now: Date, calendar: Calendar) {
            let ordered = snapshots.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            self.ordered = ordered
            self.graph = graph
            // 0) The history engine's cadence: a restore point at most every 15 minutes.
            var dropped = RepoMaintenance.cadenceThinned(ordered)
            // 1) Age/count policy over what is left — never the newest.
            let survivors = ordered.indices.filter { !dropped.contains($0) }
            let thinned = HistoryRetention.thinned(
                by: policy.mode,
                items: survivors.enumerated().map {
                    .init(id: Int64($0.offset), time: Date(timeIntervalSince1970: ordered[$0.element].createdAt))
                },
                now: now, calendar: calendar)
            for position in thinned where Int(position) < survivors.count - 1 { dropped.insert(survivors[Int(position)]) }
            self.dropped = dropped
            kept = ordered.indices.filter { !dropped.contains($0) }
            guard let graph else { return }
            references = [Int32](repeating: 0, count: graph.blobSizes.count)
            for position in kept {
                graph.blobs[ordered[position].id]?.forEach { references[$0] += 1 }
            }
            for (blob, count) in references.enumerated() where count > 0 { usage += graph.blobSizes[blob] }
            // 2) Quota — judged on what the collection leaves: garbage is reclaimed with it.
            while policy.maxTotalBytes > 0, usage > policy.maxTotalBytes, dropOldest() != nil {}
        }

        /// What collecting now frees with no further snapshot dropped.
        var garbage: Int64 {
            graph.map { max(0, $0.packBytes - usage) } ?? 0
        }

        /// Drop the oldest kept snapshot — never the last one — and say what that frees.
        mutating func dropOldest() -> DiskSpace.Step? {
            guard kept.count > 1 else { return nil }
            let oldest = kept.removeFirst()
            dropped.insert(oldest)
            var freed: Int64 = 0
            if let graph {
                graph.blobs[ordered[oldest].id]?.forEach { blob in
                    references[blob] -= 1
                    if references[blob] == 0 { freed += graph.blobSizes[blob] }
                }
            }
            usage -= freed
            return DiskSpace.Step(time: Date(timeIntervalSince1970: ordered[oldest].createdAt), freed: freed)
        }
    }

    /// The history engine's cadence (docs §3.3): of the snapshots passes wrote, kept are the first once
    /// `spacing` has elapsed since the last one kept, the last before the source was left alone for
    /// `spacing` (a state that stood), and the newest; the others — intermediate states of a burst of work —
    /// go. Explicit restore points (Back Up Now) and migrated ones are never thinned here. Positions in
    /// `ordered` (oldest first).
    static func cadenceThinned(_ ordered: [RepoSnapshotSummary],
                               spacing: TimeInterval = CaptureEngine.checkpointSpacing) -> Set<Int> {
        var dropped = Set<Int>()
        var lastKept: Double?
        for (index, snapshot) in ordered.enumerated() {
            let exempt = snapshot.requested == true || snapshot.origin != nil || index == ordered.count - 1
            let stood = index + 1 < ordered.count && ordered[index + 1].createdAt - snapshot.createdAt >= spacing
            let spaced = lastKept.map { snapshot.createdAt - $0 >= spacing } ?? true
            if exempt || stood || spaced { lastKept = snapshot.createdAt } else { dropped.insert(index) }
        }
        return dropped
    }

    // MARK: - Graph

    /// What each snapshot references, by number.
    struct Graph: Sendable {
        /// Snapshot ID → the blobs it references.
        var blobs: [String: Bitset] = [:]
        /// Snapshot ID → the trees it references.
        var trees: [String: Bitset] = [:]
        /// Blob number → its ID and its size (ciphertext length; 0 when no index lists it).
        var blobIDs: [Data] = []
        var blobSizes: [Int64] = []
        /// Tree number → its ID.
        var treeIDs: [String] = []
        /// Bytes of every pack the index lists.
        var packBytes: Int64 = 0
        /// Snapshots whose object or trees could not be read: their references are unknown.
        var unreadable: [String] = []
    }

    /// Read every snapshot in `ids` and walk its trees. One that cannot be read is listed as unreadable.
    func loadGraph(_ ids: [String], index: [PackFormat.IndexedPack]) async throws -> Graph {
        var graph = Graph()
        var blobNumbers: [Data: Int] = [:]
        func number(_ blob: Data, size: Int64 = 0) -> Int {
            if let known = blobNumbers[blob] { return known }
            blobNumbers[blob] = graph.blobIDs.count
            graph.blobIDs.append(blob)
            graph.blobSizes.append(size)
            return graph.blobIDs.count - 1
        }
        for pack in index {
            for entry in pack.entries {
                graph.packBytes += Int64(entry.length)
                _ = number(entry.blobID, size: Int64(entry.length))
            }
        }

        var treeNumbers: [String: Int] = [:]
        var nodes: [String: [TreeNode]] = [:]   // each tree decrypted once
        for id in ids {
            let key = "snapshots/\(id)"
            guard let sealed = try? await backend.get(key: key),
                  let plaintext = try? cipher.openMetadata(sealed, context: key),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: plaintext) else {
                graph.unreadable.append(id)
                continue
            }
            var blobs = Bitset()
            var trees = Bitset()
            var pending = [snapshot.rootTreeID]
            do {
                while let treeID = pending.popLast() {
                    let treeNumber: Int
                    if let known = treeNumbers[treeID] {
                        treeNumber = known
                    } else {
                        treeNumber = graph.treeIDs.count
                        treeNumbers[treeID] = treeNumber
                        graph.treeIDs.append(treeID)
                    }
                    guard trees.insert(treeNumber) else { continue }   // already walked for this snapshot
                    if nodes[treeID] == nil {
                        let treeKey = "trees/\(treeID.prefix(2))/\(treeID)"
                        nodes[treeID] = try JSONDecoder().decode(
                            [TreeNode].self, from: try cipher.openMetadata(try await backend.get(key: treeKey),
                                                                           context: "trees/\(treeID)"))
                    }
                    for node in nodes[treeID] ?? [] {
                        switch node.kind {
                        case .directory: if let child = node.treeID { pending.append(child) }
                        case .file: for blob in node.blobs ?? [] { _ = blobs.insert(number(blob)) }
                        case .symlink: break
                        }
                    }
                }
            } catch {
                graph.unreadable.append(id)   // a tree of it could not be read: what it references is unknown
                continue
            }
            graph.blobs[id] = blobs
            graph.trees[id] = trees
        }
        return graph
    }

    // MARK: - Collect

    /// Delete what the `kept` snapshots do not reference — except the `protected` packs, kept whole; returns
    /// the pack bytes reclaimed.
    private func collectGarbage(graph: Graph, kept: [String], index: [PackFormat.IndexedPack],
                                repackAll: Bool, protecting protected: Set<String>) async throws -> Int64 {
        var liveBlobs = Bitset()
        var liveTrees = Bitset()
        for id in kept {
            if let blobs = graph.blobs[id] { liveBlobs.formUnion(blobs) }
            if let trees = graph.trees[id] { liveTrees.formUnion(trees) }
        }
        var blobNumbers: [Data: Int] = [:]
        for (number, id) in graph.blobIDs.enumerated() { blobNumbers[id] = number }

        // Which packs go: those nothing live is in, and those partly dead enough to rewrite.
        var placed = Bitset()                        // live blobs already kept in some pack
        var emptied: [PackFormat.IndexedPack] = []
        var rewritten: [PackFormat.IndexedPack] = []
        var moving: [(pack: String, entry: PackEntry)] = []
        var reclaimed: Int64 = 0
        // A protected pack keeps every blob in it: a copy of one elsewhere is the spare.
        for pack in index where protected.contains(pack.packID) {
            for entry in pack.entries {
                if let number = blobNumbers[entry.blobID] { _ = placed.insert(number) }
            }
        }
        for pack in index.sorted(by: { $0.packID < $1.packID }) where !protected.contains(pack.packID) {
            var live: [PackEntry] = []
            var total = 0, dead = 0
            for entry in pack.entries {
                total += entry.length
                if let number = blobNumbers[entry.blobID], liveBlobs.contains(number), placed.insert(number) {
                    live.append(entry)
                } else {
                    dead += entry.length
                }
            }
            if live.isEmpty {
                emptied.append(pack)
                reclaimed += Int64(total)
            } else if dead > 0 && (repackAll || dead * 4 >= total) {
                rewritten.append(pack)
                moving += live.map { (pack.packID, $0) }
                reclaimed += Int64(total)
            }
        }

        // 1) What takes no writing — so a full disk gets space back before anything is written: packs nothing
        //    live is in (index objects first, so no index lists a missing pack), packs no index lists, trees
        //    nothing references.
        for pack in emptied { try await backend.delete(key: pack.indexKey) }
        if !emptied.isEmpty { try await backend.sync() }
        for pack in emptied { try await backend.delete(key: pack.packID) }
        let indexed = Set(index.map(\.packID))
        for key in try await backend.list(prefix: "data") where !indexed.contains(key) {
            reclaimed += Int64((try? await backend.stat(key: key))?.size ?? 0)
            try await backend.delete(key: key)
        }
        var treeNumbers: [String: Int] = [:]
        for (number, id) in graph.treeIDs.enumerated() { treeNumbers[id] = number }
        for key in try await backend.list(prefix: "trees") {
            let id = (key as NSString).lastPathComponent
            if let number = treeNumbers[id], liveTrees.contains(number) { continue }
            try await backend.delete(key: key)
        }
        try await backend.sync()
        try faultHook?(.garbageRemoved)

        // 2) Packs partly dead: their live blobs into new packs (barrier), then their index objects (barrier),
        //    then the packs.
        var buffer: [(blobID: Data, ciphertext: Data)] = []
        var buffered = 0
        for (pack, entry) in moving {
            let ciphertext = try await backend.get(key: pack, range: entry.offset ..< entry.offset + entry.length)
            buffer.append((entry.blobID, ciphertext))
            buffered += ciphertext.count
            reclaimed -= Int64(ciphertext.count)
            if buffered >= Self.packTargetSize {
                _ = try await PackFormat.write(buffer, backend: backend, cipher: cipher)
                buffer.removeAll()
                buffered = 0
            }
        }
        if !buffer.isEmpty { _ = try await PackFormat.write(buffer, backend: backend, cipher: cipher) }
        if !moving.isEmpty { try await backend.sync() }
        try faultHook?(.packsRewritten)
        for pack in rewritten { try await backend.delete(key: pack.indexKey) }
        if !rewritten.isEmpty { try await backend.sync() }
        try faultHook?(.indexesRemoved)
        for pack in rewritten { try await backend.delete(key: pack.packID) }
        if !rewritten.isEmpty { try await backend.sync() }
        return reclaimed
    }
}

/// A set of small non-negative integers, one bit each.
struct Bitset: Sendable, Equatable {
    private var words: [UInt64] = []

    func contains(_ value: Int) -> Bool {
        let word = value >> 6
        return word < words.count && words[word] & (1 << UInt64(value & 63)) != 0
    }

    /// Insert `value`; false when it was there already.
    @discardableResult
    mutating func insert(_ value: Int) -> Bool {
        let word = value >> 6
        if word >= words.count { words += [UInt64](repeating: 0, count: word - words.count + 1) }
        let bit: UInt64 = 1 << UInt64(value & 63)
        guard words[word] & bit == 0 else { return false }
        words[word] |= bit
        return true
    }

    mutating func formUnion(_ other: Bitset) {
        if other.words.count > words.count { words += [UInt64](repeating: 0, count: other.words.count - words.count) }
        for (index, word) in other.words.enumerated() { words[index] |= word }
    }

    func forEach(_ body: (Int) -> Void) {
        for (index, word) in words.enumerated() where word != 0 {
            var remaining = word
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                body(index << 6 + bit)
                remaining &= remaining - 1
            }
        }
    }
}
