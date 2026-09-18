//
//  @file        HistoryReader.swift
//  @description Browse and restore a job's history engine backups: list the checkpoints, list a folder
//               as it was at a checkpoint (or as it is in current/), and restore items from a checkpoint
//               into a target folder. Contents come from current/ or versions/, located via the catalog.
//               Design: docs/INCREMENTAL_ENGINE_DESIGN.md §3.8.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Nothing is materialised to browse: a checkpoint is rebuilt from `entries(born ≤ c)` and
//    `versions(born ≤ c < died)`.
//  - Restore writes each file through RestoreEngine.restoreFile (temp + atomic rename, conflict policy),
//    so an existing file is never destroyed by a failed restore, and puts the recorded lock flags back.
//    No exclusions apply to a restore. Names come back in Unicode NFC (the catalog's form).
//  - Paths given to `restore` are relative to the source folder, like the legacy restore; directories
//    are expanded as they were at the checkpoint (parents before children).
//  - Must not run concurrently with a capture pass on the same job (the BackupRunner actor serialises
//    them): a pass may move a file from current/ into versions/ mid-read.
//

import Foundation

struct HistoryReader: Sendable {

    let layout: HistoryLayout

    func checkpoints() throws -> [HistoryCheckpoint] {
        try HistoryStore(path: layout.catalogPath).checkpoints()
    }

    /// Children of catalog path `directory` ("" = the source folders) at checkpoint `seq`, or in current/
    /// when nil.
    func list(_ directory: String, at seq: Int64?) throws -> [HistoryItemRecord] {
        try HistoryStore(path: layout.catalogPath).children(of: directory, at: seq)
    }

    /// On-disk location of an item's content.
    func contentPath(of item: HistoryItemRecord) -> String {
        item.stored.map { layout.version($0) } ?? layout.current(item.path)
    }

    /// Restore `relPaths` (relative to `sourceName`) as they were at checkpoint `seq` (current/ when nil)
    /// into `target`, preserving their relative structure. A path absent at that checkpoint is reported
    /// in `failed`.
    func restore(sourceName: String,
                 relPaths: [String],
                 at seq: Int64?,
                 to target: URL,
                 conflict: RestoreEngine.ConflictPolicy,
                 progress: (Int) -> Void = { _ in }) throws -> RestoreEngine.Outcome {
        let store = try HistoryStore(path: layout.catalogPath)
        let engine = RestoreEngine()
        var outcome = RestoreEngine.Outcome()
        var processed = 0

        func restoreItem(_ item: HistoryItemRecord, rel: String) throws {
            let dst = target.appendingPathComponent(rel)
            if item.kind == .directory {
                engine.ensureDirectory(dst)
                for child in try store.children(of: item.path, at: seq) {
                    try restoreItem(child, rel: rel + "/" + child.name)
                }
            } else {
                engine.restoreFile(src: URL(fileURLWithPath: contentPath(of: item)), dst: dst,
                                   conflict: conflict, outcome: &outcome, lockFlags: item.lockFlags)
            }
            processed += 1
            progress(processed)
        }

        for rel in relPaths {
            let path = rel.isEmpty ? sourceName : sourceName + "/" + rel
            guard let item = try store.item(at: path, seq: seq) else {
                outcome.failed.append(rel)
                continue
            }
            try restoreItem(item, rel: rel.isEmpty ? sourceName : rel)
        }
        return outcome
    }
}
