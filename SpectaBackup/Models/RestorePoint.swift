//
//  @file        RestorePoint.swift
//  @description One entry of a job's backup timeline, whatever stores it: the latest state of the history
//               engine (current/, protected but not yet sealed into a checkpoint), a checkpoint, a legacy
//               1.1.x snapshot tree, or a snapshot in the encrypted repo. The dashboard timeline and the
//               restore sheet list these; `BackupHistory` is what the dashboard shows about a job.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - `fileCount` and `bytes` are logical: files (not folders) and the sum of their sizes at that point.
//  - `BackupHistory.lastBackup` is when a pass last brought the backup up to date — for the history
//    engine that is the end of the last successful pass, which is usually newer than its last checkpoint.
//

import Foundation

struct RestorePoint: Identifiable, Hashable, Sendable {

    enum Source: Hashable, Sendable {
        /// current/ as of the last pass: protected, not yet sealed into a checkpoint.
        case latest
        /// A sealed checkpoint of the history engine.
        case checkpoint(seq: Int64)
        /// A 1.1.x snapshot tree, `snapshots/<dirName>`.
        case legacySnapshot(dirName: String)
        /// A snapshot in the encrypted repo.
        case encryptedSnapshot(id: String)
    }

    let source: Source
    let time: Date
    let fileCount: Int64
    let bytes: Int64

    var id: String {
        switch source {
        case .latest: return "latest"
        case let .checkpoint(seq): return "checkpoint-\(seq)"
        case let .legacySnapshot(dirName): return "legacy-\(dirName)"
        case let .encryptedSnapshot(id): return "encrypted-\(id)"
        }
    }

    /// Browsable item by item; the encrypted repo restores whole snapshots.
    var isBrowsable: Bool {
        if case .encryptedSnapshot = source { return false }
        return true
    }
}

/// What the dashboard shows about a job's backups.
struct BackupHistory: Sendable {
    /// Newest first.
    var points: [RestorePoint] = []
    /// When a pass last brought the backup up to date; nil = never.
    var lastBackup: Date?
    /// Bytes the job's backups occupy at the destination (legacy snapshots: their own written blocks).
    var storageBytes: Int64 = 0
}
