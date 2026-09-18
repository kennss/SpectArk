//
//  @file        Syscalls.swift
//  @description Thin, safe Swift wrappers over the BSD/POSIX primitives the backup engine relies on
//               for correctness: clonefile, copyfile, link, rename (atomic publish), fcntl(F_FULLFSYNC)
//               durability, chflags (clear immutable), and statfs (volume type / free space).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - clonefile is APFS-local CoW; `dst` MUST NOT pre-exist (EEXIST otherwise). CLONE_NOOWNERCOPY is
//    required because the app is non-root. Used only for snapshot→snapshot reuse within a destination.
//  - copyItem uses COPYFILE_ALL|COPYFILE_NOFOLLOW: full metadata (perms/ACL/xattr/stat/BSD flags) and
//    copies symlinks as links, never following them. Source→destination is always a real byte copy.
//  - Durability uses fcntl(F_FULLFSYNC) — plain fsync() does NOT flush the drive's write cache on macOS.
//    `syncToDevice` is the cheap half (push a file or directory to the drive); batch writers call it per
//    item and then issue ONE F_FULLFSYNC (e.g. an SQLite commit with fullfsync=ON) to flush the cache.
//  - atomicRename relies on rename(2) being atomic within a single volume; it replaces an existing dst.
//

import Darwin
import Foundation

enum Syscalls {

    // MARK: - Clone (snapshot → snapshot, APFS CoW)

    /// Recursively clone a file or directory tree via APFS copy-on-write. `dst` must not exist.
    static func cloneItem(at src: String, to dst: String) throws {
        let flags = UInt32(CLONE_NOFOLLOW) | UInt32(CLONE_NOOWNERCOPY)
        if clonefile(src, dst, flags) != 0 {
            throw InfraError(operation: "clonefile", path: src, code: errno)
        }
    }

    // MARK: - Copy (source → destination, metadata-faithful)

    /// Copy a single file (or symlink) with full metadata. Does not follow symlinks — copies the
    /// link itself. `dst` should not pre-exist; call sites unlink first for changed files.
    static func copyItem(at src: String, to dst: String) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL) | copyfile_flags_t(COPYFILE_NOFOLLOW)
        if copyfile(src, dst, nil, flags) != 0 {
            throw InfraError(operation: "copyfile", path: src, code: errno)
        }
    }

    // MARK: - Hardlink (snapshot → snapshot, unchanged files)

    /// Create a hardlink `newLink` pointing at the same inode as `existing`.
    static func hardlink(from existing: String, to newLink: String) throws {
        if link(existing, newLink) != 0 {
            throw InfraError(operation: "link", path: newLink, code: errno)
        }
    }

    // MARK: - Durability & atomic publish

    /// Flush a file descriptor's data all the way to stable storage (drive cache included).
    static func fullFsync(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == -1 {
            throw InfraError(operation: "F_FULLFSYNC", path: nil, code: errno)
        }
    }

    /// Push a file's (or directory's) data and metadata to the device with plain fsync — NOT through the
    /// drive's cache. Pair it with one later F_FULLFSYNC per batch. Symlinks are synced as links.
    static func syncToDevice(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_SYMLINK)
        if fd == -1 { throw InfraError(operation: "open(sync)", path: path, code: errno) }
        defer { close(fd) }
        if fsync(fd) == -1 { throw InfraError(operation: "fsync", path: path, code: errno) }
    }

    /// fsync a directory (so a rename/create within it is durable). Opens read-only, fsyncs, closes.
    static func syncDirectory(_ path: String) throws {
        let fd = open(path, O_RDONLY)
        if fd == -1 { throw InfraError(operation: "open(dir)", path: path, code: errno) }
        defer { close(fd) }
        try fullFsync(fd)
    }

    /// Atomic publish within a single volume; replaces `dst` if it exists.
    /// Whether an item exists at `path` (not following a symlink). Only "there is none" is false: any other
    /// failure to look — a share that stopped answering — throws, so it is never taken for absence.
    static func exists(_ path: String) throws -> Bool {
        var st = Darwin.stat()
        if lstat(path, &st) == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw InfraError(operation: "lstat", path: path, code: errno)
    }

    static func atomicRename(_ src: String, to dst: String) throws {
        if rename(src, dst) != 0 {
            throw InfraError(operation: "rename", path: src, code: errno)
        }
    }

    // MARK: - BSD flags

    /// Flags that forbid renaming, replacing or unlinking an item (Finder's "Locked" is UF_IMMUTABLE).
    /// Backup copies never carry them — the catalog records them and restore puts them back. They are the
    /// only flags SpectArk ever changes: clearing others would damage data (a file whose UF_COMPRESSED is
    /// cleared reads as empty), and a flag change reaches every hard link of the inode.
    static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)

    /// The item's BSD flags (not following a symlink).
    static func flags(of path: String) throws -> UInt32 {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { throw InfraError(operation: "lstat", path: path, code: errno) }
        return st.st_flags
    }

    /// Remove the lock flags from an item we own (a temp or mirror copy); other flags stay.
    static func unlock(_ path: String) throws {
        let flags = try flags(of: path)
        guard flags & lockFlags != 0 else { return }
        if lchflags(path, flags & ~lockFlags) != 0 {
            throw InfraError(operation: "lchflags", path: path, code: errno)
        }
    }

    /// Remove one non-directory item even if it is locked, leaving every other name of its inode as it
    /// was: the lock is lifted through a file descriptor for the unlink and put back on the inode, which
    /// lives on when it has other hard links (a legacy snapshot tree on HFS+).
    static func unlinkLocked(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_SYMLINK | O_NONBLOCK)
        guard fd >= 0 else { throw InfraError(operation: "open(unlink)", path: path, code: errno) }
        defer { close(fd) }
        var st = Darwin.stat()
        guard fstat(fd, &st) == 0 else { throw InfraError(operation: "fstat", path: path, code: errno) }
        let locked = st.st_flags & lockFlags != 0
        if locked, fchflags(fd, st.st_flags & ~lockFlags) != 0 {
            throw InfraError(operation: "fchflags", path: path, code: errno)
        }
        let result = unlink(path)
        let code = errno
        if locked { _ = fchflags(fd, st.st_flags) }   // back on the inode, whatever became of this name
        if result != 0 { throw InfraError(operation: "unlink", path: path, code: code) }
    }

    /// rename(2) `src` over `dst`, even if `dst` is locked: its lock is lifted only for the rename and put
    /// back on its inode afterwards (it may live on under another hard link). Nothing else is changed.
    static func replace(_ src: String, over dst: String) throws {
        let fd = open(dst, O_RDONLY | O_SYMLINK | O_NONBLOCK)
        guard fd >= 0 else { return try atomicRename(src, to: dst) }   // nothing there (or unreadable)
        defer { close(fd) }
        var st = Darwin.stat()
        let locked = fstat(fd, &st) == 0 && st.st_flags & lockFlags != 0
        if locked, fchflags(fd, st.st_flags & ~lockFlags) != 0 {
            throw InfraError(operation: "fchflags", path: dst, code: errno)
        }
        let result = rename(src, dst)
        let code = errno
        if locked { _ = fchflags(fd, st.st_flags) }
        if result != 0 { throw InfraError(operation: "rename", path: src, code: code) }
    }

    /// Put lock flags back on a restored item.
    static func lock(_ path: String, flags lock: UInt32) throws {
        guard lock & lockFlags != 0 else { return }
        if lchflags(path, try flags(of: path) | (lock & lockFlags)) != 0 {
            throw InfraError(operation: "lchflags", path: path, code: errno)
        }
    }

    // MARK: - Volume info

    struct VolumeInfo: Sendable {
        let fsTypeName: String
        let freeBytes: Int64
        let totalBytes: Int64
        /// A local file system (MNT_LOCAL), not a network share (SMB, NFS, AFP, WebDAV).
        let isLocal: Bool
    }

    /// Query the filesystem type name and free/total space for the volume containing `path`.
    static func volumeInfo(at path: String) throws -> VolumeInfo {
        var s = statfs()
        if statfs(path, &s) != 0 {
            throw InfraError(operation: "statfs", path: path, code: errno)
        }
        let fsType = withUnsafeBytes(of: &s.f_fstypename) { raw -> String in
            let bound = raw.bindMemory(to: CChar.self)
            return String(cString: bound.baseAddress!)
        }
        let blockSize = Int64(s.f_bsize)
        return VolumeInfo(fsTypeName: fsType,
                          freeBytes: Int64(s.f_bavail) * blockSize,
                          totalBytes: Int64(s.f_blocks) * blockSize,
                          isLocal: s.f_flags & UInt32(MNT_LOCAL) != 0)
    }
}
