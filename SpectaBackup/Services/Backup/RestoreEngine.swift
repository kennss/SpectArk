//
//  @file        RestoreEngine.swift
//  @description Restores selected items from a snapshot's source-root into a target directory. Built
//               for safety: each file is copied to a temp name and atomically renamed into place, so
//               a failed restore can never destroy an existing file. Honors a conflict policy and
//               preserves metadata via copyfile(COPYFILE_ALL).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - NEVER writes the original in place: copy → temp → rename(over). overwrite clears uchg first.
//  - Ownership (uid/gid) cannot be restored without root; the running user becomes the owner. The UI
//    surfaces this. Symlinks are restored as links (COPYFILE_NOFOLLOW), never followed.
//  - Selected directories are expanded with FileWalker (pre-order: parents created before children).
//  - `restoreFile` / `ensureDirectory` are also used by HistoryReader to restore checkpoints.
//

import Darwin
import Foundation

struct RestoreEngine: Sendable {

    enum ConflictPolicy: String, Sendable, CaseIterable, Identifiable {
        case overwrite
        case skip
        case keepBoth
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overwrite: return "Overwrite"
            case .skip: return "Skip existing"
            case .keepBoth: return "Keep both"
            }
        }
    }

    struct Outcome: Sendable {
        var restored: Int = 0
        var skipped: Int = 0
        var failed: [String] = []
    }

    /// Restore `relPaths` (relative to `snapshotSourceRoot`) into `target`, preserving structure.
    func restore(snapshotSourceRoot: URL,
                 relPaths: [String],
                 to target: URL,
                 conflict: ConflictPolicy,
                 progress: @escaping @Sendable (Int) -> Void) throws -> Outcome {
        var outcome = Outcome()
        var processed = 0
        let fm = FileManager.default

        for rel in relPaths {
            let srcItem = snapshotSourceRoot.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: srcItem.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue && !isSymlink(srcItem.path) {
                // Recreate the directory itself, then expand its contents.
                ensureDirectory(target.appendingPathComponent(rel))
                // A snapshot tree is restored exactly as recorded — backup-time exclusions don't apply.
                try FileWalker.walk(root: srcItem, exclusions: .includeEverything) { entry in
                    let dst = target.appendingPathComponent(rel).appendingPathComponent(entry.relativePath)
                    if entry.isDirectory {
                        ensureDirectory(dst)
                    } else {
                        restoreFile(src: entry.url, dst: dst, conflict: conflict, outcome: &outcome)
                    }
                    processed += 1
                    progress(processed)
                }
            } else {
                restoreFile(src: srcItem, dst: target.appendingPathComponent(rel), conflict: conflict, outcome: &outcome)
                processed += 1
                progress(processed)
            }
        }
        return outcome
    }

    // MARK: - Per-file restore (temp + atomic rename)

    /// Restore one file or symlink from `src` to `dst` under the conflict policy. Shared with the history
    /// engine's restore, whose sources live in current/ or versions/.
    func restoreFile(src: URL, dst: URL, conflict: ConflictPolicy, outcome: inout Outcome) {
        let fm = FileManager.default
        ensureDirectory(dst.deletingLastPathComponent())

        var finalDst = dst
        if fm.fileExists(atPath: dst.path) {
            switch conflict {
            case .skip:
                outcome.skipped += 1
                return
            case .overwrite:
                try? Syscalls.clearUserFlags(dst.path)   // immutable files would block the rename
            case .keepBoth:
                finalDst = uniqueName(for: dst)
            }
        }

        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(".sbk-restore-\(UUID().uuidString)")
        do {
            try Syscalls.copyItem(at: src.path, to: tmp.path)
            try Syscalls.atomicRename(tmp.path, to: finalDst.path)   // atomic; replaces dst if present
            outcome.restored += 1
        } catch {
            try? fm.removeItem(at: tmp)
            outcome.failed.append(dst.lastPathComponent)
        }
    }

    // MARK: - Helpers

    func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func isSymlink(_ path: String) -> Bool {
        var st = Darwin.stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Produce a non-colliding "<name> (restored).<ext>" URL for the keep-both policy.
    private func uniqueName(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        func make(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            return dir.appendingPathComponent(name)
        }
        var candidate = make("(restored)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("(restored \(n))")
            n += 1
        }
        return candidate
    }
}
