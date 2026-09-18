//
//  @file        FileWalker.swift
//  @description Recursive source-tree walker built on lstat (never follows symlinks). Yields a
//               FileEntry per item with the metadata the engine needs: type, size, mtime, and the
//               (dev, ino, nlink) identity used to detect and preserve intra-source hardlinks.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Uses lstat directly (not URLResourceValues) so we get exact (st_dev, st_ino, st_nlink, st_blocks)
//    and never accidentally follow a symlink into another tree.
//  - Directories are visited before their contents (pre-order) so the engine can mkdir parents first.
//  - Symlinks are yielded as leaf entries and never descended into.
//  - Directories the exclusions classify as rebuildable artifacts are skipped entirely (neither
//    yielded nor descended into). The sibling-name set for that check is built lazily, only for a
//    directory whose listing actually contains a candidate subdirectory.
//  - Sources change while we walk them (builds, git). With `toleratingVanishedEntries` (source walks
//    only), an entry or subdirectory that is gone by the time we stat or list it is skipped instead of
//    failing the whole walk; the deletion produced an event of its own. Because an unmounted volume
//    looks exactly like "everything vanished", such a walk ends by checking that the root is still the
//    same directory (device + inode) and throws `WalkError.sourceRootChanged` otherwise.
//  - Any other stat/list failure (EACCES, I/O errors) throws: an entry that exists but cannot be read
//    must never be silently left out of a backup. Walks over snapshot trees never tolerate vanishing.
//

import Darwin
import Foundation

struct FileEntry: Sendable {
    let url: URL
    /// Path relative to the source root (POSIX separators), e.g. "Docs/a.txt".
    let relativePath: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let mtime: Date
    /// Exact modification time in ns since 1970 (for equality checks; `mtime` is a rounded Double).
    let mtimeNs: Int64
    let dev: dev_t
    let ino: ino_t
    let nlink: nlink_t
    /// Allocated 512-byte blocks (st_blocks) — used for honest "added bytes" accounting.
    let blocks: Int64

    /// True when this is a regular file referenced by more than one path (a hardlink).
    var isHardlinked: Bool { !isDirectory && !isSymlink && nlink > 1 }
}

enum FileWalker {

    enum WalkError: Error, CustomStringConvertible {
        /// The walked root disappeared or was replaced mid-walk (e.g. its volume was ejected).
        case sourceRootChanged(String)

        var description: String {
            switch self {
            case let .sourceRootChanged(path): return "source folder disappeared during the walk: \(path)"
            }
        }
    }

    /// Walk `root` recursively, invoking `visit` for every non-excluded entry (pre-order). `relBase` is
    /// `root`'s own path relative to the source folder when walking a subtree: relative paths and
    /// exclusion rules then stay relative to the source folder, exactly as in a full walk.
    static func walk(root: URL,
                     relBase: String = "",
                     exclusions: BackupExclusions,
                     toleratingVanishedEntries: Bool = false,
                     visit: (FileEntry) throws -> Void) throws {
        let rootIdentity = toleratingVanishedEntries ? try identity(of: root.path) : nil
        try recurse(dir: root, relBase: relBase, exclusions: exclusions, tolerant: toleratingVanishedEntries,
                    visit: visit)
        if let rootIdentity { try verifyRootUnchanged(root.path, rootIdentity) }
    }

    /// The non-excluded entries directly inside `dir` (one level), with relative paths under `relBase`.
    /// Returns nil when `dir` is gone and `toleratingVanishedEntries` is set.
    static func list(_ dir: URL,
                     relBase: String,
                     exclusions: BackupExclusions,
                     toleratingVanishedEntries: Bool = false) throws -> [FileEntry]? {
        try entries(of: dir, relBase: relBase, exclusions: exclusions, tolerant: toleratingVanishedEntries)
    }

    /// Device + inode of a directory, used to notice it being unmounted or replaced.
    struct Identity: Equatable, Sendable {
        let dev: dev_t
        let ino: ino_t
    }

    static func identity(of path: String) throws -> Identity {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { throw InfraError(operation: "lstat", path: path, code: errno) }
        return Identity(dev: st.st_dev, ino: st.st_ino)
    }

    /// Throws when `path` is gone or is no longer the directory identified at the start. Entries that
    /// "vanished" during such a walk were not really deleted, so its result must not be published.
    static func verifyRootUnchanged(_ path: String, _ expected: Identity) throws {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0, st.st_dev == expected.dev, st.st_ino == expected.ino else {
            throw WalkError.sourceRootChanged(path)
        }
    }

    /// True when `path` no longer exists (or is no longer a directory) — i.e. it vanished mid-walk.
    static func vanished(_ path: String, expectDirectory: Bool = false) -> Bool {
        var st = Darwin.stat()
        if lstat(path, &st) != 0 { return errno == ENOENT || errno == ENOTDIR }
        return expectDirectory && (st.st_mode & S_IFMT) != S_IFDIR
    }

    private static func recurse(dir: URL,
                                relBase: String,
                                exclusions: BackupExclusions,
                                tolerant: Bool,
                                visit: (FileEntry) throws -> Void) throws {
        guard let entries = try entries(of: dir, relBase: relBase, exclusions: exclusions, tolerant: tolerant) else {
            return   // vanished mid-walk (tolerant walks only)
        }
        for entry in entries {
            try visit(entry)
            if entry.isDirectory && !entry.isSymlink {
                try recurse(dir: entry.url, relBase: entry.relativePath, exclusions: exclusions,
                            tolerant: tolerant, visit: visit)
            }
        }
    }

    /// The non-excluded entries directly inside `dir` (relative paths under `relBase`), or nil when a
    /// tolerant listing finds `dir` gone. Shared by the recursive walk and `list`.
    private static func entries(of dir: URL, relBase: String, exclusions: BackupExclusions,
                                tolerant: Bool) throws -> [FileEntry]? {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            if tolerant && !relBase.isEmpty && vanished(dir.path, expectDirectory: true) { return nil }
            throw error
        }
        var siblingSet: Set<String>?
        let hasSibling: (String) -> Bool = { candidate in
            if siblingSet == nil { siblingSet = Set(names) }
            return siblingSet!.contains(candidate)
        }
        var result: [FileEntry] = []
        for name in names {
            let rel = relBase.isEmpty ? name : relBase + "/" + name
            if exclusions.isExcluded(relativePath: rel, name: name) { continue }
            let childURL = dir.appendingPathComponent(name)
            guard let entry = try statEntry(url: childURL, relativePath: rel, tolerant: tolerant) else { continue }
            if entry.isDirectory && !entry.isSymlink
                && exclusions.isArtifactDirectory(at: childURL, name: name, siblings: hasSibling) {
                continue
            }
            result.append(entry)
        }
        return result
    }

    private static func statEntry(url: URL, relativePath: String, tolerant: Bool) throws -> FileEntry? {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0 else {
            let code = errno
            if tolerant && (code == ENOENT || code == ENOTDIR) { return nil }
            throw InfraError(operation: "lstat", path: url.path, code: code)
        }
        let kind = st.st_mode & S_IFMT
        let mtime = Date(timeIntervalSince1970:
            Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileEntry(
            url: url,
            relativePath: relativePath,
            isDirectory: kind == S_IFDIR,
            isSymlink: kind == S_IFLNK,
            size: Int64(st.st_size),
            mtime: mtime,
            mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
            dev: st.st_dev,
            ino: st.st_ino,
            nlink: st.st_nlink,
            blocks: Int64(st.st_blocks)
        )
    }
}
