//
//  @file        HistoryMaterializer.swift
//  @description Builds the state of a checkpoint (or of current/) as a real folder tree, for consumers that
//               need a directory to read — re-encrypting a job's history into its encrypted repo when
//               encryption is turned on. The tree is assembled from current/ and versions/ as the catalog
//               describes that checkpoint.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Files are cloned (APFS: no extra space), else hard-linked, else copied. The target must be on the
//    destination volume, beside current/, and is the caller's to delete. Nothing in current/ or versions/
//    is modified: clones and copies are independent, and a hard link is only ever read through.
//  - The state at checkpoint c is entries(born ≤ c) plus versions(born ≤ c < died); sorted by path, every
//    folder is created before what it contains.
//  - Must not run concurrently with a capture pass on the same job (the BackupRunner actor serialises
//    them): a pass may move a file from current/ into versions/ mid-build.
//

import Darwin
import Foundation

struct HistoryMaterializer: Sendable {

    let layout: HistoryLayout

    /// Build the state at checkpoint `seq` (current/ when nil) under `target`, which must not exist.
    /// Returns the folders built at its top — one per source the checkpoint holds, including sources
    /// since removed from the job — sorted by name.
    func materialize(at seq: Int64?, into target: URL) throws -> [URL] {
        let store = try HistoryStore(path: layout.catalogPath)
        var items: [(path: String, kind: HistoryItemKind, content: String?)] = []
        for entry in try store.allEntries().values where seq.map({ entry.born <= $0 }) ?? true {
            items.append((entry.path, entry.kind, layout.current(entry.path)))
        }
        if let seq {
            for version in try store.versions() where version.born <= seq && seq < version.died {
                items.append((version.path, version.kind, version.stored.map { layout.version($0) }))
            }
        }
        items.sort { $0.path < $1.path }

        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        for item in items {
            let destination = target.path + "/" + item.path
            if item.kind == .directory {
                try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
                continue
            }
            guard let content = item.content else { continue }
            if (try? Syscalls.cloneItem(at: content, to: destination)) != nil { continue }
            if item.kind == .file, link(content, destination) == 0 { continue }
            try Syscalls.copyItem(at: content, to: destination)
        }
        return items.filter { $0.kind == .directory && !$0.path.contains("/") }
            .map { target.appendingPathComponent($0.path, isDirectory: true) }
    }
}
