//
//  @file        SnapshotBrowser.swift
//  @description Lists a restore point one directory level per call for the restore UI, so browsing a
//               huge backup never loads the whole tree at once: SnapshotBrowser reads a legacy snapshot
//               tree from disk, HistoryBrowser reads a checkpoint (or current/) from the history catalog.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//

import Darwin
import Foundation

struct SnapshotEntry: Identifiable, Sendable, Hashable {
    /// Path relative to the snapshot's source-root (POSIX separators).
    let relPath: String
    let name: String
    let isDirectory: Bool
    var id: String { relPath }
}

/// One level of a restore point's tree at a time; paths are relative to the source folder.
protocol RestoreBrowser: Sendable {
    /// Immediate children under `relPath` ("" = the source folder), directories first, then by name.
    func children(of relPath: String) -> [SnapshotEntry]
}

extension RestoreBrowser {
    static func ordered(_ entries: [SnapshotEntry]) -> [SnapshotEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// A checkpoint of the history engine (or current/ when `seq` is nil), listed from its catalog.
struct HistoryBrowser: RestoreBrowser {
    let reader: HistoryReader
    let sourceName: String
    let seq: Int64?

    func children(of relPath: String) -> [SnapshotEntry] {
        let directory = relPath.isEmpty ? sourceName : sourceName + "/" + relPath
        let items = (try? reader.list(directory, at: seq)) ?? []
        return Self.ordered(items.map {
            SnapshotEntry(relPath: relPath.isEmpty ? $0.name : relPath + "/" + $0.name, name: $0.name,
                          isDirectory: $0.kind == .directory)
        })
    }
}

/// A 1.1.x snapshot tree (`snapshots/<dirName>/<source>`), read from disk.
struct SnapshotBrowser: RestoreBrowser {
    /// The marker 1.1.x wrote at the top of every complete snapshot tree; never a backed-up item.
    static let completeMarker = ".spectabackup-complete"

    /// .../snapshots/<dirName>/<sourceName>
    let sourceRoot: URL

    /// Immediate children under `relPath` ("" = root), directories first then case-insensitive name.
    func children(of relPath: String) -> [SnapshotEntry] {
        let dir = relPath.isEmpty ? sourceRoot : sourceRoot.appendingPathComponent(relPath)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var entries: [SnapshotEntry] = []
        for name in names where name != Self.completeMarker {
            let childRel = relPath.isEmpty ? name : relPath + "/" + name
            var st = Darwin.stat()
            guard lstat(dir.appendingPathComponent(name).path, &st) == 0 else { continue }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            entries.append(SnapshotEntry(relPath: childRel, name: name, isDirectory: isDir))
        }
        return Self.ordered(entries)
    }
}
