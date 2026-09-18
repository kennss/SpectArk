//
//  @file        DestinationCapabilities.swift
//  @description Probed capabilities of a destination volume and where the backup is written: directly on
//               the volume, or inside an APFS sparsebundle on it. Established by DestinationProbe before
//               each pass.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Direct only on a local volume with full file-system semantics — clonefile (APFS) or hard links that
//    persist across a remount (HFS+). Everything else (SMB shares, exFAT/FAT drives) gets a sparsebundle:
//    the history engine's SQLite catalog must not live on a network file system, and xattrs, BSD flags
//    and permissions must survive (docs/INCREMENTAL_ENGINE_DESIGN.md §3.1).
//  - `isCaseSensitive` matters for data safety: a case-insensitive destination can silently clobber
//    two source names differing only in case — the probe flags it so the engine can refuse/rename.
//

import Foundation

enum FileSystemKind: String, Codable, Sendable, Hashable {
    case apfs
    case hfsPlus
    case smb
    case other
}

enum MTimeResolution: String, Codable, Sendable, Hashable {
    case nanosecond
    case second
}

/// Where a destination's backups are written.
enum BackupStrategy: String, Codable, Sendable, Hashable {
    /// On the volume itself (local APFS or HFS+) — current/ is browsable in Finder.
    case direct
    /// Inside an APFS sparsebundle image on the volume (NAS shares, exFAT/FAT drives).
    case sparsebundle

    static func select(from caps: DestinationCapabilities) -> BackupStrategy {
        if caps.supportsClone || (caps.supportsHardlink && caps.hardlinkPersistsRemount) { return .direct }
        return .sparsebundle
    }
}

struct DestinationCapabilities: Codable, Sendable, Hashable {
    var fileSystem: FileSystemKind
    var supportsClone: Bool
    var supportsHardlink: Bool
    var hardlinkPersistsRemount: Bool
    var xattrRoundTrip: Bool
    var isCaseSensitive: Bool
    var mtimeResolution: MTimeResolution
    var freeBytes: Int64
    var probedAt: Date

    /// The strategy selected from these capabilities.
    var strategy: BackupStrategy { BackupStrategy.select(from: self) }
}
