//
//  @file        LocalBackend.swift
//  @description Filesystem-backed object store — the dedup engine's reference backend and the store
//               for local / external-disk / mounted-NAS encrypted repos. Strongly consistent and
//               supports Range reads, so it isolates engine bugs from cloud-backend quirks.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-30
//  @lastUpdated 2026-09-19
//

import Darwin
import Foundation

struct LocalBackend: Backend {
    let root: URL

    var capabilities: BackendCapabilities {
        BackendCapabilities(supportsRange: true, isStronglyConsistent: true,
                            maxObjectSize: .max, dailyUploadCap: 0, permanentDeleteRequired: false)
    }

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(_ key: String) -> URL { root.appendingPathComponent(key) }

    /// Written beside its name (a dot-temp, which listings skip), fsynced, then renamed into place: a
    /// crash never leaves an object half-written under its name. `sync` makes it all reach the drive.
    func put(key: String, data: Data) async throws {
        let dst = url(key)
        let dir = dst.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(dst.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            try Syscalls.syncToDevice(temp.path)
            try Syscalls.atomicRename(temp.path, to: dst.path)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// F_FULLFSYNC on the repo's volume: everything fsynced before it, renames included, reaches stable
    /// storage (drive cache included). A network share (smbfs) has no F_FULLFSYNC (ENOTSUP, measured): there
    /// every object was already flushed to the server as it was written (fsync = an SMB flush), and the
    /// folder is fsynced as well.
    func sync() async throws {
        let fd = open(root.path, O_RDONLY)
        guard fd >= 0 else { throw InfraError(operation: "open(sync)", path: root.path, code: errno) }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        let failure = errno
        guard failure == ENOTSUP || failure == EINVAL || failure == ENOTTY else {
            throw InfraError(operation: "F_FULLFSYNC", path: root.path, code: failure)
        }
        if fsync(fd) != 0, errno != ENOTSUP, errno != EINVAL {
            throw InfraError(operation: "fsync", path: root.path, code: errno)
        }
    }

    func get(key: String) async throws -> Data {
        try Data(contentsOf: url(key))
    }

    func get(key: String, range: Range<Int>) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url(key))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: range.count) ?? Data()
    }

    func stat(key: String) async throws -> BackendStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url(key).path),
              let size = attrs[.size] as? Int else { return nil }
        return BackendStat(size: size)
    }

    /// Every object under `prefix` (keys relative to the root). A folder that cannot be read throws: a
    /// listing that silently left something out would have garbage collection delete what it did not see.
    /// A prefix with no folder lists nothing. Dot-names (a put in progress, Finder's files) are skipped.
    func list(prefix: String) async throws -> [String] {
        let base = (prefix.isEmpty ? root : url(prefix)).path
        guard try Syscalls.exists(base) else { return [] }
        var keys: [String] = []
        var folders = [""]
        while let rel = folders.popLast() {
            let folder = rel.isEmpty ? base : base + "/" + rel
            for name in try FileManager.default.contentsOfDirectory(atPath: folder) where !name.hasPrefix(".") {
                let childRel = rel.isEmpty ? name : rel + "/" + name
                var st = Darwin.stat()
                guard lstat(folder + "/" + name, &st) == 0 else {
                    if errno == ENOENT { continue }   // deleted since it was listed
                    throw InfraError(operation: "lstat", path: folder + "/" + name, code: errno)
                }
                if st.st_mode & S_IFMT == S_IFDIR {
                    folders.append(childRel)
                } else {
                    keys.append(prefix.isEmpty ? childRel : prefix + "/" + childRel)
                }
            }
        }
        return keys
    }

    /// Remove an object; one already gone is fine. Any other failure throws — garbage collection relies on
    /// its deletions happening in order.
    func delete(key: String) async throws {
        if unlink(url(key).path) != 0, errno != ENOENT {
            throw InfraError(operation: "unlink", path: url(key).path, code: errno)
        }
    }
}
