//
//  @file        HistoryLayout.swift
//  @description Where the history engine keeps things inside a job root at the destination: the mirror
//               (current/), the version store (versions/), the catalog (history.sqlite), and the temp
//               names used while a file is being replaced. Design: docs/INCREMENTAL_ENGINE_DESIGN.md §3.1.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Catalog paths are relative to current/ ("Developments/a/b.txt"); `current(_:)` maps them to disk.
//  - versions/ is sharded by the low byte of the stored name (an intent id) so no directory grows huge.
//  - A temp file sits beside its target (same directory ⇒ same volume ⇒ rename is atomic). Its name
//    carries the intent id, so recovery finds exactly the temp an interrupted intent created.
//

import Foundation

struct HistoryLayout: Sendable {
    let jobRoot: URL

    static let tempPrefix = ".spectark-tmp-"

    var currentRoot: String { jobRoot.appendingPathComponent("current", isDirectory: true).path }
    var versionsRoot: String { jobRoot.appendingPathComponent("versions", isDirectory: true).path }
    var catalogPath: String { jobRoot.appendingPathComponent("history.sqlite").path }

    /// On-disk path of a catalog path inside current/.
    func current(_ relativePath: String) -> String {
        currentRoot + "/" + relativePath
    }

    /// Shard directory holding a stored version.
    func versionShard(_ stored: String) -> String {
        versionsRoot + "/" + String(format: "%02x", (Int64(stored) ?? 0) & 0xff)
    }

    /// On-disk path of a stored version.
    func version(_ stored: String) -> String {
        versionShard(stored) + "/" + stored
    }

    /// Temp path used while intent `intentID` replaces `relativePath`.
    func temp(for relativePath: String, intentID: Int64) -> String {
        (current(relativePath) as NSString).deletingLastPathComponent + "/" + Self.tempPrefix + String(intentID)
    }
}
