//
//  @file        RepoMaintenance.swift
//  @description Retention and garbage collection for an encrypted repo. The job's retention policy thins
//               its snapshots — the restore points (RepoTimeline) — as it thins plaintext history:
//               Automatic (Time Machine), keep N, keep N days, keep all, then the oldest dropped while the
//               quota is exceeded or free space is short. Dropping a snapshot deletes its object; the data
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

    /// Apply `policy` to the repo's `snapshots` (those the timeline could read). Garbage is collected when
    /// `collect` (the caller's schedule) — and always under space pressure. What is kept is every snapshot
    /// object in the repo the plan did not drop, whether or not the caller listed it: one it could not read
    /// makes the collection stop, never lose its data.
    func run(policy: RetentionPolicy, snapshots: [RepoSnapshotSummary], freeBytes: Int64, collect: Bool,
             now: Date, calendar: Calendar = .autoupdatingCurrent) async throws -> Outcome {
        let prefix = "snapshots/"
        let present = try await backend.list(prefix: "snapshots").map { String($0.dropFirst(prefix.count)) }
        let listed = Set(present)
        let candidates = snapshots.filter { listed.contains($0.id) }
        let hasSpaceRules = policy.maxTotalBytes > 0 || policy.minimumFreeBytes > 0
        let index = hasSpaceRules || collect ? try await PackFormat.readIndex(backend: backend, cipher: cipher) : []
        var graph = hasSpaceRules ? try await loadGraph(present, index: index) : nil
        let blocked = graph?.unreadable ?? []
        // The space rules need every snapshot's references.
        let decision = Self.plan(policy: policy, snapshots: candidates, graph: blocked.isEmpty ? graph : nil,
                                 freeBytes: freeBytes, now: now, calendar: calendar)

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
        if graph == nil { graph = try await loadGraph(kept, index: index) }
        guard let graph else { return outcome }
        let unreadableKept = graph.unreadable.filter { kept.contains($0) }
        guard unreadableKept.isEmpty else {
            outcome.unreadable = unreadableKept
            return outcome
        }
        outcome.reclaimedBytes = try await collectGarbage(graph: graph, kept: kept, index: index,
                                                          repackAll: decision.spacePressure)
        outcome.collected = true
        return outcome
    }

    // MARK: - Plan

    struct Decision: Equatable, Sendable {
        var drop: Set<String> = []
        /// The quota is exceeded or free space is short (before dropping): collect, repacking fully.
        var spacePressure = false
    }

    /// Which snapshots `policy` drops. Pure: `graph` tells what each frees (needed only for space rules).
    static func plan(policy: RetentionPolicy, snapshots: [RepoSnapshotSummary], graph: Graph?,
                     freeBytes: Int64, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Decision {
        let ordered = snapshots.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        guard !ordered.isEmpty else { return Decision() }
        // 0) The history engine's cadence: a restore point at most every 15 minutes.
        var dropped = Set(cadenceThinned(ordered).map(Int64.init))
        // 1) Age/count policy over what is left — never the newest.
        let survivors = ordered.indices.filter { !dropped.contains(Int64($0)) }
        let thinned = HistoryRetention.thinned(
            by: policy.mode,
            items: survivors.enumerated().map {
                .init(id: Int64($0.offset), time: Date(timeIntervalSince1970: ordered[$0.element].createdAt))
            },
            now: now, calendar: calendar)
        for position in thinned where Int(position) < survivors.count - 1 { dropped.insert(Int64(survivors[Int(position)])) }
        var decision = Decision()

        // 2) Space: the oldest kept go while the quota is exceeded or free space is short.
        if let graph, policy.maxTotalBytes > 0 || policy.minimumFreeBytes > 0 {
            var kept = ordered.indices.filter { !dropped.contains(Int64($0)) }
            var references = [Int32](repeating: 0, count: graph.blobSizes.count)
            for position in kept {
                graph.blobs[ordered[position].id]?.forEach { references[$0] += 1 }
            }
            var usage: Int64 = 0
            for (blob, count) in references.enumerated() where count > 0 { usage += graph.blobSizes[blob] }
            // Pressure is what the disk says now: garbage not yet collected occupies it all the same.
            decision.spacePressure = (policy.minimumFreeBytes > 0 && freeBytes < policy.minimumFreeBytes)
                || (policy.maxTotalBytes > 0 && graph.packBytes > policy.maxTotalBytes)
            // What to drop is judged on what the collection leaves: garbage is reclaimed with it.
            var free = saturatingAdd(freeBytes, max(0, graph.packBytes - usage))
            func pressed() -> Bool {
                (policy.minimumFreeBytes > 0 && free < policy.minimumFreeBytes)
                    || (policy.maxTotalBytes > 0 && usage > policy.maxTotalBytes)
            }
            while kept.count > 1, pressed() {
                let oldest = kept.removeFirst()
                dropped.insert(Int64(oldest))
                var freed: Int64 = 0
                graph.blobs[ordered[oldest].id]?.forEach { blob in
                    references[blob] -= 1
                    if references[blob] == 0 { freed += graph.blobSizes[blob] }
                }
                usage -= freed
                free = saturatingAdd(free, freed)
            }
        }
        decision.drop = Set(dropped.map { ordered[Int($0)].id })
        return decision
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

    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        a > Int64.max - b ? Int64.max : a + b
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

    /// Delete what the `kept` snapshots do not reference; returns the pack bytes reclaimed.
    private func collectGarbage(graph: Graph, kept: [String], index: [PackFormat.IndexedPack],
                                repackAll: Bool) async throws -> Int64 {
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
        for pack in index.sorted(by: { $0.packID < $1.packID }) {
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
