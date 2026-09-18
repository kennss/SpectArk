//
//  @file        TreeReaper.swift
//  @description Removes garbage trees — legacy snapshots retention already dropped (`.deleting-*`) — at
//               background priority, one at a time, so deleting a 700 k-entry tree never holds up a backup
//               pass. Also the one tree-removal routine the engine uses (`TreeRemoval`).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Only for trees that are garbage by construction: nothing lists or reads a `.deleting-` tree, so it may
//    go at any time, and one left behind by a quit is found and queued again by the next retention run.
//  - Not for trees inside a NAS sparsebundle: the image is detached once nothing uses it (ImageLease),
//    so those are deleted within the pass (their runner is separate and holds up no local job).
//  - Background QoS: the kernel throttles its I/O behind everything else on the disk.
//  - Retention measures free space before the reaper has caught up, so it asks `pendingBytes(under:)`
//    how much the queue is about to free — otherwise a free-space rule would drop restore point after
//    restore point for space already on its way back.
//  - Removal never clears flags other than the lock flags, and never through another hard link: a
//    dropped HFS+ snapshot tree shares inodes with trees that are kept (see Syscalls.unlinkLocked).
//

import Foundation

/// Removing a tree that may hold locked items (uchg copied from a source).
enum TreeRemoval {

    /// Remove `path` and everything below it; a missing path is fine.
    static func remove(_ path: String) throws {
        let fm = FileManager.default
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { return }
        if (try? fm.removeItem(atPath: path)) != nil { return }
        // Something is locked. Folders are unlocked before their contents (pre-order); locked files are
        // unlinked one by one with their inode's other names left as they were.
        if st.st_mode & S_IFMT == S_IFDIR {
            if st.st_flags & Syscalls.lockFlags != 0 { try? Syscalls.unlock(path) }
            try? FileWalker.walk(root: URL(fileURLWithPath: path, isDirectory: true), exclusions: .includeEverything) { item in
                guard item.flags & Syscalls.lockFlags != 0 else { return }
                if item.isDirectory && !item.isSymlink {
                    try? Syscalls.unlock(item.url.path)
                } else {
                    try? Syscalls.unlinkLocked(item.url.path)
                }
            }
            try fm.removeItem(atPath: path)
        } else {
            try Syscalls.unlinkLocked(path)
        }
    }
}

final class TreeReaper: @unchecked Sendable {

    static let shared = TreeReaper()

    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "ai.calidalab.spectabackup.reaper", qos: .background)) {
        self.queue = queue
    }
    private let lock = NSLock()
    private var queued: [String: Int64] = [:]   // tree path → bytes it will free (estimate)

    /// Delete `tree` soon; a tree already queued is not queued twice. `bytes` is what it will free.
    func reap(_ tree: URL, bytes: Int64 = 0) {
        lock.lock()
        let isNew = queued[tree.path] == nil
        if isNew { queued[tree.path] = bytes }
        lock.unlock()
        guard isNew else { return }
        queue.async {
            try? TreeRemoval.remove(tree.path)
            self.lock.lock()
            self.queued[tree.path] = nil
            self.lock.unlock()
        }
    }

    /// Bytes still to be freed by queued trees below `root`.
    func pendingBytes(under root: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return queued.filter { $0.key.hasPrefix(root + "/") }.values.reduce(0, +)
    }

    /// Wait until every tree queued so far is gone (tests).
    func drain() {
        queue.sync {}
    }
}
