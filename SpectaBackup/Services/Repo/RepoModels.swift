//
//  @file        RepoModels.swift
//  @description Object model for the encrypted dedup repo. A TreeNode is one directory entry (file
//               with its ordered chunk blob IDs, a subdirectory by content-addressed tree ID, or a
//               symlink). A Snapshot points at the root tree plus metadata and is written last.
//               Trees/snapshots are stored as encrypted metadata objects. The snapshots are the encrypted
//               job's only record of its restore points (RepoTimeline). Fields added later are optional:
//               older objects decode, and the canonical encoding leaves absent ones out.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-30
//  @lastUpdated 2026-09-19
//

import Foundation

struct TreeNode: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case file, directory, symlink }

    let kind: Kind
    let name: String

    // file
    var blobs: [Data]?      // ordered chunk blob IDs
    var size: Int?
    var mode: UInt16?       // posix permissions
    var mtime: Double?      // seconds since 1970
    /// Exact modification time (ns since 1970): what the next pass compares to reuse the node unread.
    /// Absent in nodes written before it existed (those files are read again once).
    var mtimeNs: Int64?

    // directory
    var treeID: String?     // content-addressed child tree
    /// The folder's inode when it was listed: an unchanged folder is reused unlisted only while it is still
    /// the same folder (one moved into its place carries no events of its own).
    var ino: UInt64?
    /// Files and their bytes in the whole subtree — carried over with a folder reused unlisted.
    var fileCount: Int?
    var totalBytes: Int?

    // symlink
    var target: String?
}

struct Snapshot: Codable, Sendable {
    let rootTreeID: String
    let sourcePath: String
    let createdAt: Double   // seconds since 1970
    let fileCount: Int
    let totalBytes: Int     // sum of logical file sizes
    /// The plaintext restore point it re-encrypts (a migration marker, "migrated:…"); nil for a backup of
    /// the source. Absent in snapshots written before it existed.
    var origin: String?
    /// An explicit restore point (Back Up Now, a due schedule): never thinned by the 15-minute cadence.
    var requested: Bool?
}
