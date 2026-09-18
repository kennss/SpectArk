//
//  @file        Syscalls.swift
//  @description Thin, safe Swift wrappers over the BSD/POSIX primitives the backup engine relies on
//               for correctness: clonefile, copyfile, link, rename (atomic publish), fcntl(F_FULLFSYNC)
//               durability, chflags (clear immutable), and statfs (volume type / free space).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
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
    static func atomicRename(_ src: String, to dst: String) throws {
        if rename(src, dst) != 0 {
            throw InfraError(operation: "rename", path: src, code: errno)
        }
    }

    // MARK: - BSD flags

    /// Clear all BSD user flags (e.g. UF_IMMUTABLE/uchg) so a path can be deleted or overwritten.
    static func clearUserFlags(_ path: String) throws {
        if chflags(path, 0) != 0 {
            throw InfraError(operation: "chflags", path: path, code: errno)
        }
    }

    // MARK: - Volume info

    struct VolumeInfo: Sendable {
        let fsTypeName: String
        let freeBytes: Int64
        let totalBytes: Int64
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
                          totalBytes: Int64(s.f_blocks) * blockSize)
    }
}
