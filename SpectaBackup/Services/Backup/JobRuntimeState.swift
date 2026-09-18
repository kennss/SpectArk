//
//  @file        JobRuntimeState.swift
//  @description Per-job, UI-facing runtime state (not persisted): whether a pass is running, live
//               progress, when the job was last backed up, its restore points, the space its backups
//               occupy, and the most recent error.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//

import Foundation

struct JobRuntimeState: Sendable {
    var isRunning: Bool = false
    var progress: BackupProgress = BackupProgress()
    /// When a pass last brought the backup up to date; nil = never.
    var lastBackup: Date?
    var lastError: String?
    /// Restore points, newest first.
    var restorePoints: [RestorePoint] = []
    /// Bytes this job's backups occupy at the destination.
    var storageBytes: Int64 = 0
    /// Smoothed write rate while a pass runs (bytes/sec); 0 when idle.
    var throughputBytesPerSec: Double = 0
    /// Free space at the destination volume (bytes); nil if unknown / unreachable.
    var destinationFreeBytes: Int64?
    /// Total capacity of the destination volume (bytes); nil if unknown.
    var destinationTotalBytes: Int64?
    /// True while a plaintext→encrypted migration runs for this job.
    var isMigrating: Bool = false
    /// Migration progress; nil when not migrating.
    var migrationProgress: MigrationProgress?
    /// A short success note shown right after a migration finishes (cleared on the next action).
    var migrationMessage: String?
}

struct MigrationProgress: Sendable {
    var done: Int
    var total: Int
}
