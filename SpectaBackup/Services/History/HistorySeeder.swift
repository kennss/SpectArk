//
//  @file        HistorySeeder.swift
//  @description Migration from 1.1.x: seeds a job's history engine from its newest legacy snapshot, once,
//               so the first capture pass copies only what changed since that snapshot instead of the
//               whole source. The snapshot's source folders are cloned into current/ (no extra space on
//               APFS — locally and inside a NAS sparsebundle) and recorded in the catalog as they are.
//               Design: docs/INCREMENTAL_ENGINE_DESIGN.md §6.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Runs only on a pristine catalog, and the catalog commit is its last step: an interrupted seed leaves
//    a pristine catalog, whose leftovers in current/ are cleared before the next attempt (and by the
//    capture engine, which treats anything under a pristine catalog as a leftover).
//  - A seed is an optimisation. When it fails, the caller runs the normal first pass, which copies the
//    whole source.
//  - The legacy tree is walked with the job's exclusions, so current/ starts with what the job backs up
//    now: 1.1.x snapshots predate the artifact rules and can hold several times more entries (dependency
//    folders, build output), which the first pass would otherwise remove again one intent at a time.
//  - Each item is cloned (APFS: no extra space). On a volume without clones (HFS+) files are hard-linked
//    instead: current/ never modifies a file in place (it replaces by rename, retires by rename, or
//    unlinks) and legacy trees are read-only, so a shared inode is never written through either name.
//    Anything neither can place is copied. A locked file (UF_IMMUTABLE/UF_APPEND) is never hard-linked:
//    its placed copy must drop the lock flags (recorded in the catalog), and a shared inode would drop
//    them from the legacy snapshot too.
//  - Durability follows the capture engine's rule: every seeded item is fsynced, and the catalog commit
//    (F_FULLFSYNC) comes last, so no row can point at an item that is not on stable storage.
//  - Rows come from lstat of the seeded items. Legacy snapshots keep each file's size and mtime, which is
//    what the capture pass compares, so unchanged files are not copied again. Rows are born in the
//    pending generation and are never versioned when replaced: the legacy snapshot itself remains a
//    restore point until retention ages it out. For the same reason the seed is not an unsealed change:
//    checkpoint 1 is sealed by the first pass that changes something.
//  - Only the job's current sources are seeded; the rest of the snapshot (other sources, the COMPLETE
//    marker) stays in the legacy tree.
//

import Darwin
import Foundation

struct HistorySeeder: Sendable {

    let layout: HistoryLayout

    /// Seed current/ from `snapshotRoot` (a legacy `snapshots/<dirName>` folder) if the catalog is
    /// pristine. `sourceNames` are the job's source folder names; `exclusions` the job's. Returns the
    /// number of entries recorded (0 = nothing done). On error current/ is left empty again.
    @discardableResult
    func seedIfPristine(from snapshotRoot: URL, sourceNames: [String], exclusions: BackupExclusions) throws -> Int {
        let store = try HistoryStore(path: layout.catalogPath)
        guard try store.isPristine() else { return 0 }
        try clearLeftovers()
        do {
            let generation = try store.pendingGeneration()
            var entries: [HistoryEntry] = []
            for name in sourceNames {
                let legacy = snapshotRoot.appendingPathComponent(name, isDirectory: true).path
                guard kind(of: legacy) == .directory else { continue }
                let target = layout.current(name)
                try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
                entries.append(try entry(for: name, at: target, generation: generation))
                try FileWalker.walk(root: URL(fileURLWithPath: legacy, isDirectory: true), exclusions: exclusions) { item in
                    let placed = target + "/" + item.relativePath
                    try place(item, at: placed)
                    entries.append(try entry(for: name + "/" + item.relativePath, at: placed, generation: generation,
                                             lockFlags: item.flags & Syscalls.lockFlags))
                }
            }
            guard !entries.isEmpty else { return 0 }
            for entry in entries { try Syscalls.syncToDevice(layout.current(entry.path)) }
            try Syscalls.syncToDevice(layout.currentRoot)
            try store.seed(entries)   // commit = F_FULLFSYNC
            return entries.count
        } catch {
            try? clearLeftovers()
            throw error
        }
    }

    /// Empty current/ and versions/ (only ever called while the catalog is pristine).
    func clearLeftovers() throws {
        let fm = FileManager.default
        for root in [layout.currentRoot, layout.versionsRoot] {
            if fm.fileExists(atPath: root) { try Self.removeTree(root) }
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
    }

    // MARK: - Placing the legacy tree

    /// One legacy item at `destination`: a folder is created (the walk fills it), anything else is
    /// cloned, else hard-linked (unlocked files), else copied — and the placed copy is unlocked.
    private func place(_ item: FileEntry, at destination: String) throws {
        if item.isDirectory && !item.isSymlink {
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
            return
        }
        let locked = item.flags & Syscalls.lockFlags != 0
        if (try? Syscalls.cloneItem(at: item.url.path, to: destination)) != nil {
            try Syscalls.unlock(destination)
            return
        }
        if !item.isSymlink, !locked, link(item.url.path, destination) == 0 { return }
        try Syscalls.copyItem(at: item.url.path, to: destination)
        try Syscalls.unlock(destination)
    }

    private func entry(for path: String, at location: String, generation: Int64,
                       lockFlags: UInt32 = 0) throws -> HistoryEntry {
        var st = Darwin.stat()
        guard lstat(location, &st) == 0 else { throw InfraError(operation: "lstat", path: location, code: errno) }
        let kind: HistoryItemKind
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .file
        }
        let isDirectory = kind == .directory
        return HistoryEntry(path: path, kind: kind,
                            size: isDirectory ? 0 : Int64(st.st_size),
                            mtimeNs: isDirectory ? 0 : Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                                + Int64(st.st_mtimespec.tv_nsec),
                            born: generation, mirrorIno: UInt64(st.st_ino), lockFlags: lockFlags, seeded: true)
    }

    private func kind(of path: String) -> HistoryItemKind? {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT == S_IFDIR ? .directory : .file
    }

    /// Remove a tree, clearing BSD flags (e.g. uchg copied from a source) that block deletion.
    static func removeTree(_ path: String) throws {
        try TreeRemoval.remove(path)
    }
}
