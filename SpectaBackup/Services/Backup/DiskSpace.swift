//
//  @file        DiskSpace.swift
//  @description Keeping room on a backup disk. Every disk keeps a reserve free — 5% of it, or the largest
//               "Keep free space" a job there sets — and when less is free, the oldest restore points go,
//               of every job on the disk together, oldest first, until the reserve is back (Time Machine
//               deletes its oldest backups the same way). Pure: the plan, the reserve, which jobs may give
//               up restore points for space, and which disk a destination is on. BackupRunner measures and
//               carries the plan out (keepDiskReserve).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - A job's side is its ladder: what dropping each of its oldest restore points frees, in order, given the
//    ones before it went (HistoryRetention.ladder, RepoMaintenance.ladder) — after its own policy and quota
//    have had their say. An encrypted repo also brings its garbage: collected under pressure, it frees space
//    without losing a restore point, so it counts first. The newest restore point of a job never goes.
//  - The plan takes the oldest next step across all ladders until the target is reached — a job's own steps
//    always in their order — so the disk loses its oldest history first, whichever job it belongs to.
//  - "Keep all" means nothing is removed for space — unless that job sets "Keep free space" itself.
//  - Making room takes room: a disk that is really full cannot even open a catalog (SQLite writes as it
//    opens — measured: SQLITE_FULL with 5 MB still reported free on a small APFS volume, whose last few MB
//    only small writes may use). So each destination keeps a ballast file of `ballastBytes`, counted as
//    free, removed first whenever room must be made, and put back once the reserve is.
//  - A pass never writes a batch that does not fit (BackupRunner.room): a NAS image whose share is full takes
//    writes without an error and loses them (measured), so no error would ever say the disk was full.
//  - The disk of a destination is the volume it is on, told from the mount table (MNT_NOWAIT): nothing waits
//    on a share that stopped answering. Jobs on one disk share one BackupRunner, so a reclamation never
//    runs beside another job's pass on the same disk.
//  - Sizes are bytes.
//

import Darwin
import Foundation
import SQLite3

enum DiskSpace {

    /// The share of a disk kept free when no job there sets "Keep free space".
    static let reserveFraction = 0.05

    /// What must stay free on a disk of `capacity` bytes holding `jobs`' backups.
    static func reserve(capacity: Int64, jobs: [BackupJob]) -> Int64 {
        let explicit = jobs.map(\.retention.minimumFreeBytes).filter { $0 > 0 }
        if let largest = explicit.max() { return largest }
        return Int64((Double(max(0, capacity)) * reserveFraction).rounded())
    }

    /// The room set aside on a disk (BackupRunner's ballast) for making room once it is full: 64 MB, never
    /// more than half the reserve.
    static func ballastBytes(reserve: Int64) -> Int64 {
        min(64 << 20, max(0, reserve) / 2)
    }

    /// Whether `job`'s restore points may be removed to keep a disk's reserve.
    static func givesUpSpace(_ job: BackupJob) -> Bool {
        if case .keepAll = job.retention.mode { return job.retention.minimumFreeBytes > 0 }
        return true
    }

    // MARK: - Plan

    /// What dropping one restore point frees: the point's time, and the bytes (given the earlier steps went).
    struct Step: Equatable, Sendable {
        let time: Date
        let freed: Int64
    }

    /// One job's side of a reclamation.
    struct Ladder: Equatable, Sendable {
        let jobID: UUID
        /// Freed with no restore point lost (an encrypted repo's garbage, collected under pressure).
        var garbage: Int64 = 0
        /// Its oldest restore points, oldest first, never its newest.
        var steps: [Step] = []
    }

    struct Plan: Equatable, Sendable {
        /// Per job: how many of its oldest restore points go (jobs losing none are absent).
        var drops: [UUID: Int] = [:]
        /// Bytes free once the plan is carried out (its own estimate).
        var freeAfter: Int64
        let target: Int64

        /// Even with everything that may go gone, less than the target is free.
        var short: Bool { freeAfter < target }
        var dropsAnything: Bool { !drops.isEmpty }
    }

    /// The oldest restore points across `ladders` that bring `free` bytes up to `target`, oldest first.
    static func plan(free: Int64, target: Int64, ladders: [Ladder]) -> Plan {
        var plan = Plan(freeAfter: ladders.reduce(max(0, free)) { saturatingAdd($0, $1.garbage) }, target: target)
        var next = [Int](repeating: 0, count: ladders.count)
        while plan.freeAfter < target {
            // The job whose next restore point is the oldest (ties: the job ID, so the plan is repeatable).
            var chosen: Int?
            for (index, ladder) in ladders.enumerated() where next[index] < ladder.steps.count {
                guard let best = chosen else { chosen = index; continue }
                let candidate = ladder.steps[next[index]].time, current = ladders[best].steps[next[best]].time
                if candidate < current || (candidate == current && ladder.jobID.uuidString < ladders[best].jobID.uuidString) {
                    chosen = index
                }
            }
            guard let chosen else { break }
            plan.freeAfter = saturatingAdd(plan.freeAfter, ladders[chosen].steps[next[chosen]].freed)
            next[chosen] += 1
            plan.drops[ladders[chosen].jobID] = next[chosen]
        }
        return plan
    }

    static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        a > Int64.max - b ? Int64.max : a + b
    }

    // MARK: - Out of space

    /// The failure is a disk that ran out of room (ENOSPC — from a catalog too, whatever SQLite called it —
    /// or SQLITE_FULL), wherever in the error it is carried.
    static func isOutOfSpace(_ error: Error) -> Bool {
        if case CaptureError.outOfSpace = error { return true }
        if let infra = error as? InfraError { return infra.code == ENOSPC }
        if case let HistoryStore.StoreError.sql(_, code, systemErrno) = error {
            return code & 0xff == SQLITE_FULL || systemErrno == ENOSPC
        }
        if case let HistoryStore.StoreError.open(_, code) = error { return code & 0xff == SQLITE_FULL }
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == NSPOSIXErrorDomain, e.code == Int(ENOSPC) { return true }
            if e.domain == NSCocoaErrorDomain, e.code == NSFileWriteOutOfSpaceError { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    // MARK: - Which disk

    /// The disk `destination` is on: the mount point of the deepest mounted volume holding its path, as the
    /// kernel last knew them (never waiting on a share); the destination's own path when none does.
    static func diskKey(for destination: URL,
                        volumes: [URL] = DestinationIdentity.mountedVolumes().map(\.url)) -> String {
        let path = destination.standardizedFileURL.path
        var best: String?
        for volume in volumes {
            let root = volume.standardizedFileURL.path
            let holds = root == "/" || path == root || path.hasPrefix(root + "/")
            if holds, root.count > (best?.count ?? -1) { best = root }
        }
        return best ?? path
    }
}

/// A pass the disk has no room for, with nothing left that may be removed to make some — or a disk so full
/// that not even that can be done (its catalogs cannot be opened: no ballast was set aside before it filled).
struct DiskFullError: Error, CustomStringConvertible {
    var tooFullToMakeRoom = false

    var description: String {
        tooFullToMakeRoom
            ? "The backup disk is completely full — too full even to remove old restore points. Free up a little space on it (100 MB is enough); from then on SpectArk keeps room by removing the oldest restore points itself."
            : "The backup disk is full, and no older restore points can be removed to make room. Free up space on it, or back up to a larger disk."
    }
}
