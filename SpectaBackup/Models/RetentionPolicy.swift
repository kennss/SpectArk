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
//  - Free-space decisions must be driven by live `statfs` at thinning time, NOT by summing backup
//    sizes. `minimumFreeBytes` is the low-water mark that forces deletion of the oldest restore points
//    regardless of age policy; the newest one is never deleted.
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
        /// Never auto-delete; stop backing up (and warn) when the disk fills.
        case keepAll
    }

    var mode: Mode
    /// Low-water free-space mark in bytes that forces oldest-first deletion (0 = disabled).
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
