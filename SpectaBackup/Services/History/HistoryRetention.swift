//
//  @file        HistoryRetention.swift
//  @description Retention for the history engine. `HistoryRetention.plan` is a pure planner over one
//               timeline — the job's legacy (1.1.x) snapshots, then its checkpoints: which restore points
//               the policy drops (the same thinning as before — "Automatic" is Time Machine style), then
//               the oldest survivors dropped while space is short or the quota is exceeded, and which
//               stored versions no kept checkpoint needs any more. `HistoryMaintenance` applies a plan to
//               the catalog and versions/ and hands back the legacy snapshots to delete.
//               Design: docs/INCREMENTAL_ENGINE_DESIGN.md §3.6.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - The newest restore point is never dropped, and current/ is never touched: retention only removes
//    history. A version is needed while some kept checkpoint lies in its [born, died).
//  - Policies: Automatic (Time Machine: everything from the last 24 h, the newest per day for 30 days,
//    the newest per week after), keep the newest N, keep N days, keep all; then free-space and quota
//    pressure. Days (and weeks) are local and begin at 05:00, so a night of work counts toward the day it
//    began. Free space comes from statfs; a legacy snapshot's size is its own written blocks.
//  - One timeline, so a policy means what the user sees: "keep 10" keeps the ten newest restore points
//    whether they are checkpoints or snapshots from before the migration; space pressure drops the
//    oldest first, which are the legacy snapshots.
//  - Space accounting uses logical sizes: current/ plus the versions still needed. Dropping the oldest
//    kept checkpoint frees exactly the versions that contained it but not the next kept one.
//  - Order on disk: catalog rows first (one commit, with `sweep_pending` set), then version files. An
//    interruption can only leak unreferenced files, which the next run sweeps — never a row pointing at
//    a missing file.
//  - Maintenance refuses to run while a capture pass has unsettled intents: an interrupted pass may
//    have moved a version into versions/ before its row exists, and a sweep must not delete it.
//

import Foundation

enum HistoryRetention {

    /// The parts of a version retention needs.
    struct VersionSpan: Equatable, Sendable {
        let id: Int64
        let born: Int64
        let died: Int64
        let size: Int64
    }

    /// A legacy (1.1.x) snapshot of the same job. It predates every checkpoint.
    struct LegacySnapshot: Equatable, Sendable {
        /// Its catalog seqId.
        let id: Int64
        let time: Date
        /// What deleting it frees (its freshly written blocks).
        let bytes: Int64
    }

    struct Plan: Equatable, Sendable {
        var checkpoints: Set<Int64> = []
        var versions: Set<Int64> = []
        /// Legacy snapshots to delete (seqIds) — their trees and catalog are the caller's.
        var legacySnapshots: Set<Int64> = []
    }

    /// One restore point on the job's timeline: legacy snapshots first (older), then checkpoints.
    private enum Point {
        case legacy(LegacySnapshot)
        case checkpoint(HistoryCheckpoint)

        var time: Date {
            switch self {
            case let .legacy(snapshot): return snapshot.time
            case let .checkpoint(checkpoint): return checkpoint.time
            }
        }
    }

    static func plan(policy: RetentionPolicy,
                     checkpoints: [HistoryCheckpoint],
                     versions: [VersionSpan],
                     currentBytes: Int64,
                     seededBytes: Int64 = 0,
                     legacy: [LegacySnapshot] = [],
                     freeBytes: Int64,
                     now: Date,
                     calendar: Calendar = .autoupdatingCurrent) -> Plan {
        let timeline: [Point] = legacy.sorted { $0.id < $1.id }.map(Point.legacy)
            + checkpoints.sorted { $0.seq < $1.seq }.map(Point.checkpoint)
        guard !timeline.isEmpty else {
            return Plan(versions: Set(versions.map(\.id)))   // nothing can reach them
        }

        // 1) Age/count policy over the whole timeline (positions are its order) — never the newest.
        var dropped = thinned(by: policy.mode,
                              items: timeline.enumerated().map { .init(id: Int64($0.offset), time: $0.element.time) },
                              now: now, calendar: calendar)
        dropped.remove(Int64(timeline.count - 1))
        var kept = timeline.indices.filter { !dropped.contains(Int64($0)) }   // ascending

        func keptCheckpoints() -> [Int64] {
            kept.compactMap { if case let .checkpoint(c) = timeline[$0] { return c.seq } else { return nil } }
        }
        var needed = versions.filter { isNeeded($0, kept: keptCheckpoints()) }
        var liveFree = freeBytes
        // Seeded items are clones of legacy data: their blocks are counted with the legacy snapshots
        // while any is kept, and with current/ once the last one goes.
        var keptLegacy = kept.filter { if case .legacy = timeline[$0] { return true } else { return false } }.count
        var usage = currentBytes - (keptLegacy > 0 ? seededBytes : 0) + needed.reduce(Int64(0)) { $0 + $1.size }
            + kept.reduce(Int64(0)) { if case let .legacy(s) = timeline[$1] { return $0 + s.bytes } else { return $0 } }

        // 2) Space pressure and quota — drop the oldest kept restore points until satisfied.
        while kept.count > 1 {
            let lowFree = policy.minimumFreeBytes > 0 && liveFree < policy.minimumFreeBytes
            let overQuota = policy.maxTotalBytes > 0 && usage > policy.maxTotalBytes
            guard lowFree || overQuota else { break }
            let oldest = kept.removeFirst()
            dropped.insert(Int64(oldest))
            let freedBytes: Int64
            switch timeline[oldest] {
            case let .legacy(snapshot):
                keptLegacy -= 1
                if keptLegacy == 0 {
                    // Blocks the seeded clones still share stay allocated; they now count as current/.
                    freedBytes = max(0, snapshot.bytes - seededBytes)
                    // After the common `usage -= freedBytes` below, usage has lost the snapshot and
                    // gained the seeded bytes.
                    usage += freedBytes - snapshot.bytes + seededBytes
                } else {
                    freedBytes = snapshot.bytes
                }
            case let .checkpoint(checkpoint):
                // Legacy snapshots precede every checkpoint, so the next kept point is a checkpoint.
                guard case let .checkpoint(next) = timeline[kept[0]] else { continue }
                // Versions containing `checkpoint` but not `next` are no longer needed by anything kept.
                let freed = needed.filter { $0.born <= checkpoint.seq && checkpoint.seq < $0.died && $0.died <= next.seq }
                let freedIDs = Set(freed.map(\.id))
                needed.removeAll { freedIDs.contains($0.id) }
                freedBytes = freed.reduce(Int64(0)) { $0 + $1.size }
            }
            liveFree = liveFree > Int64.max - freedBytes ? Int64.max : liveFree + freedBytes   // saturating
            usage -= freedBytes
        }

        var plan = Plan()
        for position in dropped {
            switch timeline[Int(position)] {
            case let .legacy(snapshot): plan.legacySnapshots.insert(snapshot.id)
            case let .checkpoint(checkpoint): plan.checkpoints.insert(checkpoint.seq)
            }
        }
        plan.versions = Set(versions.map(\.id)).subtracting(needed.map(\.id))
        return plan
    }

    // MARK: - Policy thinning

    /// Anything the age/count policy can thin: a monotonic id (newer = larger) and a creation time.
    struct Dated: Sendable {
        let id: Int64
        let time: Date
    }

    /// A retention day begins at this local hour.
    static let dayStartHour = 5

    /// Ids the age/count policy deletes. Never protects the newest itself — callers do that. `calendar`
    /// sets the local days and weeks of the automatic policy.
    static func thinned(by mode: RetentionPolicy.Mode, items: [Dated], now: Date,
                        calendar: Calendar = .autoupdatingCurrent) -> Set<Int64> {
        let oldestFirst = items.sorted { $0.id < $1.id }
        switch mode {
        case .keepAll:
            return []
        case .keepCount(let n):
            guard n >= 1, oldestFirst.count > n else { return [] }
            return Set(oldestFirst.prefix(oldestFirst.count - n).map(\.id))   // drop oldest beyond n
        case .keepDays(let d):
            let cutoff = now.addingTimeInterval(-Double(d) * 86_400)
            return Set(oldestFirst.filter { $0.time < cutoff }.map(\.id))
        case .automatic:
            return automaticThinning(oldestFirst, now: now, calendar: calendar)
        }
    }

    /// A local day or week, as its calendar components.
    private struct Bucket: Hashable {
        let year: Int
        let index: Int
    }

    /// The retention day (from 05:00 to 05:00 local time) and week of `time`. Hours before 05:00 on the
    /// wall clock belong to the day before, so a daylight-saving change never moves the boundary.
    private static func buckets(of time: Date, _ calendar: Calendar) -> (day: Bucket, week: Bucket) {
        var wallDay = time
        if calendar.component(.hour, from: time) < dayStartHour,
           let dayBefore = calendar.date(byAdding: .day, value: -1, to: time) {
            wallDay = dayBefore
        }
        let day = calendar.dateComponents([.year, .month, .day], from: wallDay)
        let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: wallDay)
        return (Bucket(year: day.year ?? 0, index: (day.month ?? 0) * 32 + (day.day ?? 0)),
                Bucket(year: week.yearForWeekOfYear ?? 0, index: week.weekOfYear ?? 0))
    }

    /// Time Machine style: keep everything < 24h, newest-per-day for ~30d, newest-per-week beyond.
    private static func automaticThinning(_ items: [Dated], now: Date, calendar: Calendar) -> Set<Int64> {
        var keep = Set<Int64>()
        var dayBuckets = Set<Bucket>()
        var weekBuckets = Set<Bucket>()
        // Newest-first so the first item seen in each bucket (the newest) is the one we keep.
        for item in items.sorted(by: { $0.id > $1.id }) {
            let age = now.timeIntervalSince(item.time)
            if age < 86_400 {
                keep.insert(item.id)
            } else if age < 30 * 86_400 {
                if dayBuckets.insert(buckets(of: item.time, calendar).day).inserted { keep.insert(item.id) }
            } else {
                if weekBuckets.insert(buckets(of: item.time, calendar).week).inserted { keep.insert(item.id) }
            }
        }
        return Set(items.map(\.id)).subtracting(keep)
    }

    /// True when some kept checkpoint (ascending) lies in [born, died).
    private static func isNeeded(_ version: VersionSpan, kept: [Int64]) -> Bool {
        var low = 0, high = kept.count
        while low < high {                        // first kept checkpoint >= born
            let mid = (low + high) / 2
            if kept[mid] < version.born { low = mid + 1 } else { high = mid }
        }
        return low < kept.count && kept[low] < version.died
    }
}

/// Applies retention to one job's history at the destination.
struct HistoryMaintenance: Sendable {

    struct Result: Equatable, Sendable {
        var checkpointsDeleted = 0
        var versionsDeleted = 0
        var bytesFreed: Int64 = 0
        /// Settled intents first — run a capture pass, then maintenance.
        var skippedForPendingIntents = false
        /// Legacy snapshots the plan drops; the caller deletes their trees and catalog rows.
        var legacySnapshotsToDelete: Set<Int64> = []
    }

    let layout: HistoryLayout

    func applyRetention(policy: RetentionPolicy, legacy: [HistoryRetention.LegacySnapshot] = [],
                        freeBytes: Int64, now: Date) throws -> Result {
        let store = try HistoryStore(path: layout.catalogPath)
        guard try store.pendingIntents().isEmpty else { return Result(skippedForPendingIntents: true) }
        if try store.sweepPending() { try sweep(store) }   // an earlier prune was interrupted

        let versions = try store.versions()
        let plan = HistoryRetention.plan(
            policy: policy,
            checkpoints: try store.checkpoints(),
            versions: versions.map { .init(id: $0.id, born: $0.born, died: $0.died, size: $0.size) },
            currentBytes: try store.currentBytes(),
            seededBytes: try store.seededBytes(),
            legacy: legacy,
            freeBytes: freeBytes,
            now: now)
        guard !plan.checkpoints.isEmpty || !plan.versions.isEmpty else {
            return Result(legacySnapshotsToDelete: plan.legacySnapshots)
        }

        let doomed = versions.filter { plan.versions.contains($0.id) }
        try store.prune(checkpoints: plan.checkpoints, versions: plan.versions)
        for version in doomed {
            if let stored = version.stored { try removeIfPresent(layout.version(stored)) }
        }
        try store.setSweepPending(false)
        return Result(checkpointsDeleted: plan.checkpoints.count, versionsDeleted: doomed.count,
                      bytesFreed: doomed.reduce(Int64(0)) { $0 + $1.size },
                      legacySnapshotsToDelete: plan.legacySnapshots)
    }

    /// Delete files in versions/ that no version row references.
    private func sweep(_ store: HistoryStore) throws {
        let referenced = try store.storedNames()
        let fm = FileManager.default
        for shard in (try? fm.contentsOfDirectory(atPath: layout.versionsRoot)) ?? [] {
            let shardPath = layout.versionsRoot + "/" + shard
            for name in (try? fm.contentsOfDirectory(atPath: shardPath)) ?? [] where !referenced.contains(name) {
                try removeIfPresent(shardPath + "/" + name)
            }
        }
        try store.setSweepPending(false)
    }

    private func removeIfPresent(_ path: String) throws {
        try TreeRemoval.remove(path)
    }
}
