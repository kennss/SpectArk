//
//  @file        RetentionPolicy.swift
//  @description Retention policy for a job's restore points. Default is Time Machine-style automatic
//               thinning; HistoryRetention applies it to the job's timeline (1.1.x snapshots, then
//               checkpoints) to decide which restore points to delete and when.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Free space is kept per disk, not per job (DiskSpace): every disk keeps 5% free — or the largest
//    `minimumFreeBytes` a job on it sets — by deleting the oldest restore points of all its jobs together,
//    regardless of age policy; each job's newest one is never deleted. Measured with live `statfs`, NOT
//    by summing backup sizes. "Keep all" jobs give up nothing for space unless they set it themselves.
//

import Foundation

struct RetentionPolicy: Codable, Sendable, Hashable {
    enum Mode: Codable, Sendable, Hashable {
        /// Time Machine style: all kept 24h, daily kept ~30d, weekly beyond (local days from 05:00).
        case automatic
        /// Keep only the most recent N restore points.
        case keepCount(Int)
        /// Keep restore points created within the last N days.
        case keepDays(Int)
        /// Never auto-delete — not even for space, unless `minimumFreeBytes` is set; backups stop (with an
        /// error) when the disk fills.
        case keepAll
    }

    var mode: Mode
    /// Free space in bytes to keep on the backup disk, deleting the oldest restore points there when less is
    /// free (0 = automatic: 5% of the disk). The largest value among a disk's jobs is the disk's.
    var minimumFreeBytes: Int64
    /// Maximum total bytes the backup may occupy (quota — e.g. a NAS share allowance); 0 = unlimited.
    /// When exceeded, the oldest restore points are deleted first.
    var maxTotalBytes: Int64

    init(mode: Mode, minimumFreeBytes: Int64 = 0, maxTotalBytes: Int64 = 0) {
        self.mode = mode
        self.minimumFreeBytes = minimumFreeBytes
        self.maxTotalBytes = maxTotalBytes
    }

    /// Default policy: TM-style automatic thinning.
    static let automatic = RetentionPolicy(mode: .automatic)

    // Backward-compatible decoding: configs written before a field existed still load (missing
    // size fields default to 0 = unlimited). Apply this pattern whenever a persisted field is added.
    enum CodingKeys: String, CodingKey { case mode, minimumFreeBytes, maxTotalBytes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        minimumFreeBytes = try c.decodeIfPresent(Int64.self, forKey: .minimumFreeBytes) ?? 0
        maxTotalBytes = try c.decodeIfPresent(Int64.self, forKey: .maxTotalBytes) ?? 0
    }
}
