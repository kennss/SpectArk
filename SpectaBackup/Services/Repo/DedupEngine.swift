//
//  @file        DedupEngine.swift
//  @description The encrypted dedup backup/restore engine. backUp() walks the job's source trees
//               (each becomes a named subtree under one root), chunks each file (FastCDC), stores
//               chunks as deduplicated blobs (BlobStore), builds content-addressed tree objects, and
//               writes the snapshot last. restore() reads snapshot → trees → reassembles each file from
//               its blobs and writes it atomically (temp + rename), never overwriting in place.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-30
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Incremental (a pass): the previous pass's snapshot is the parent. A file whose size and exact mtime
//    match its node there keeps that node, unread. A folder FSEvents reported nothing in (SourceScope) —
//    and that is still the same folder (inode), with its subtree totals known — keeps its tree, unlisted.
//    A folder with another inode is listed, and everything below it too: a folder moved into place
//    carries no events of its own. Nodes written before inodes and exact mtimes existed lack them: those
//    folders are listed and files read once, as before.
//  - Quiet window and torn reads, as the history engine: a file modified within the window is left for a
//    later pass, and one that changes while it is read is dropped; either keeps its node from the parent
//    (or is left out if new), and its folder is listed again next pass (`carried`). A settle pass (no
//    window) reads a file that keeps changing up to three times, then keeps the last read, recorded with
//    the mtime from before it so the next pass reads it again.
//  - Without a parent or scopes (a migration re-encrypting a folder tree) everything is listed and read.
//  - Files are read whole before chunking; streaming large files through FastCDC is a later optimization.
//  - Exclusions are applied exactly as FileWalker applies them (name/glob rules, then artifact folders),
//    so a job backs up the same files either way; a migration passes `.includeEverything`.
//  - Tolerant walks (a live source) leave out entries that vanish while read and check each source root
//    is still the same folder at the end; re-encrypting a snapshot tree never tolerates anything missing.
//  - Restore puts back each file's content, permissions and modification time (as a plaintext restore's
//    copy does for files); folders are created fresh.
//

import CryptoKit
import Darwin
import Foundation

struct DedupEngine: Sendable {
    private let backend: Backend
    private let blobStore: BlobStore
    private let cipher: BlobCipher
    private let chunker: FastCDC

    init(backend: Backend, keys: RepoKeys, chunker: FastCDC) {
        self.backend = backend
        self.blobStore = BlobStore(backend: backend, keys: keys)
        self.cipher = BlobCipher(keys: keys)
        self.chunker = chunker
    }

    /// Load the blob index (needed before restoring into a freshly-opened engine).
    func open() async throws {
        try await blobStore.loadIndex()
    }

    // MARK: - Backup

    /// Reads of a file that keeps changing, in a settle pass, before the last one is kept as it is.
    static let settleReadAttempts = 3

    /// What a pass knows beyond the sources themselves.
    struct Incremental: Sendable {
        /// The snapshot the previous pass wrote.
        var parent: String?
        /// Per source name: which folders to list. A source without one is listed whole.
        var scopes: [String: SourceScope] = [:]
        /// Files modified within this many seconds are left for later; 0 = none (a settle pass, Back Up
        /// Now, a migration).
        var quietWindow: TimeInterval = 0

        /// Everything listed and read (a migration).
        static let none = Incremental()
    }

    /// The folders of one source a pass must list: those FSEvents reported (recursively, when its value
    /// says so), those a file was left for later in, and every folder on the way to them.
    struct SourceScope: Sendable, Equatable {
        private let onTheWay: Set<String>
        private let recursive: [String]

        /// `dirty`: folder (relative, "" = the source) → reported recursively. `carried`: folders to list again.
        init(dirty: [String: Bool], carried: Set<String>) {
            var onTheWay = Set<String>()
            for path in Set(dirty.keys).union(carried) {
                var current = Substring(path)
                onTheWay.insert(String(current))
                while let slash = current.lastIndex(of: "/") {
                    current = current[..<slash]
                    onTheWay.insert(String(current))
                }
                onTheWay.insert("")
            }
            self.onTheWay = onTheWay
            self.recursive = dirty.filter(\.value).map(\.key)
        }

        func mustList(_ rel: String) -> Bool {
            onTheWay.contains(rel)
                || recursive.contains { $0.isEmpty || rel == $0 || rel.hasPrefix($0 + "/") }
        }
    }

    struct BackUpResult: Sendable {
        let snapshot: Snapshot
        /// The snapshot that holds this state: the one written — or the parent, when nothing changed.
        let snapshotID: String
        /// A new snapshot was written.
        let written: Bool
        /// Files left for later: in their quiet window, or changing while read.
        let deferred: Int
        /// Per source name: the folders holding them, to list again next pass.
        let carried: [String: Set<String>]
    }

    /// Back up one or more source folders into a single snapshot. Each source becomes a named subdirectory
    /// (by `lastPathComponent`) under the snapshot's root tree. `origin`: the plaintext restore point this
    /// re-encrypts; `requested`: an explicit restore point (Snapshot). The snapshot is the commit point:
    /// written after a write barrier, so it never survives a crash without its packs and trees. A pass that
    /// finds the sources exactly as the parent has them writes none (as the history engine adds no
    /// checkpoint for an unchanged source) — unless the restore point was requested.
    @discardableResult
    func backUp(sources: [URL], snapshotID: String, now: Double, origin: String? = nil, requested: Bool = false,
                incremental: Incremental = .none,
                exclusions: BackupExclusions, toleratingVanishedEntries tolerant: Bool) async throws -> BackUpResult {
        let trees = TreeReader(backend: backend, cipher: cipher)
        // A parent that cannot be read (gone meanwhile) is no parent: everything is read.
        var parentSnapshot: Snapshot?
        var parentRoot: [String: TreeNode] = [:]
        if let parent = incremental.parent, let snapshot = try? await trees.snapshot(parent),
           let nodes = try? await trees.nodes(snapshot.rootTreeID) {
            parentSnapshot = snapshot
            for node in nodes { parentRoot[node.name] = node }
        }
        let walk = Walk(trees: trees, exclusions: exclusions, tolerant: tolerant,
                        quietWindow: incremental.quietWindow)
        var rootNodes: [TreeNode] = []
        var fileCount = 0
        var totalBytes = 0
        for source in sources {
            let name = source.lastPathComponent
            let rootIdentity = try FileWalker.identity(of: source.path)
            let scope = incremental.scopes[name]
            guard let node = try await backUpDirectory(source, name: name, source: name, rel: "",
                                                       parent: parentRoot[name], scope: scope,
                                                       listAll: scope == nil, walk: walk) else {
                throw FileWalker.WalkError.sourceRootChanged(source.path)
            }
            if tolerant { try FileWalker.verifyRootUnchanged(source.path, rootIdentity) }
            rootNodes.append(node)
            fileCount += node.fileCount ?? 0
            totalBytes += node.totalBytes ?? 0
        }
        let rootTreeID = try await writeTree(rootNodes)
        try await blobStore.flush()
        try await backend.sync()
        if let parent = incremental.parent, let parentSnapshot, parentSnapshot.rootTreeID == rootTreeID,
           !requested, origin == nil {
            return BackUpResult(snapshot: parentSnapshot, snapshotID: parent, written: false,
                                deferred: walk.deferred, carried: walk.carried)
        }

        let snapshot = Snapshot(rootTreeID: rootTreeID,
                                sourcePath: sources.map(\.path).joined(separator: ", "),
                                createdAt: now, fileCount: fileCount, totalBytes: totalBytes, origin: origin,
                                requested: requested ? true : nil)
        let sealed = try cipher.sealMetadata(try Self.canonicalEncoder.encode(snapshot),
                                             context: "snapshots/\(snapshotID)")
        try await backend.put(key: "snapshots/\(snapshotID)", data: sealed)
        try await backend.sync()
        return BackUpResult(snapshot: snapshot, snapshotID: snapshotID, written: true, deferred: walk.deferred,
                            carried: walk.carried)
    }

    /// Reads the trees of an earlier snapshot. Each folder's tree is read once per pass: nothing is kept.
    private struct TreeReader: Sendable {
        let backend: Backend
        let cipher: BlobCipher

        func nodes(_ treeID: String) async throws -> [TreeNode] {
            let key = "trees/\(treeID.prefix(2))/\(treeID)"
            return try JSONDecoder().decode(
                [TreeNode].self, from: try cipher.openMetadata(try await backend.get(key: key), context: "trees/\(treeID)"))
        }

        func snapshot(_ id: String) async throws -> Snapshot {
            let key = "snapshots/\(id)"
            return try JSONDecoder().decode(
                Snapshot.self, from: try cipher.openMetadata(try await backend.get(key: key), context: key))
        }
    }

    /// State of one pass's walk, used by one task at a time.
    private final class Walk {
        let trees: TreeReader
        let exclusions: BackupExclusions
        let tolerant: Bool
        let quietWindow: TimeInterval
        let session: CoordinatedSourceSession
        var deferred = 0
        var carried: [String: Set<String>] = [:]

        init(trees: TreeReader, exclusions: BackupExclusions, tolerant: Bool, quietWindow: TimeInterval) {
            self.trees = trees
            self.exclusions = exclusions
            self.tolerant = tolerant
            self.quietWindow = quietWindow
            self.session = CoordinatedSourceSession(rootURL: URL(fileURLWithPath: "/"), quietWindow: quietWindow)
        }

        /// A file left for later in folder `rel` of `source`.
        func leave(in source: String, rel: String) {
            deferred += 1
            carried[source, default: []].insert(rel)
        }
    }

    /// Back up one folder into a directory node (its tree, inode and subtree totals); nil if it vanished
    /// (tolerant walks only) before it could be listed. `parent`: its node in the parent snapshot.
    /// `listAll`: list it and everything below, whatever the scope says.
    private func backUpDirectory(_ dir: URL, name: String, source: String, rel: String, parent: TreeNode?,
                                 scope: SourceScope?, listAll: Bool, walk: Walk) async throws -> TreeNode? {
        var st = Darwin.stat()
        guard lstat(dir.path, &st) == 0 else {
            if walk.tolerant && FileWalker.vanished(dir.path, expectDirectory: true) { return nil }
            throw InfraError(operation: "lstat", path: dir.path, code: errno)
        }
        let ino = UInt64(st.st_ino)
        let previous = parent?.kind == .directory ? parent : nil
        let sameFolder = previous?.ino == ino

        // Nothing reported in it, and still the same folder: its tree as it was, unlisted.
        if !listAll, sameFolder, let scope, !scope.mustList(rel), let previous, previous.treeID != nil,
           previous.fileCount != nil, previous.totalBytes != nil {
            return TreeNode(kind: .directory, name: name, treeID: previous.treeID, ino: ino,
                            fileCount: previous.fileCount, totalBytes: previous.totalBytes)
        }
        // What the parent had here, by name: unchanged files keep their nodes.
        var before: [String: TreeNode] = [:]
        if let treeID = previous?.treeID, let nodes = try? await walk.trees.nodes(treeID) {   // unreadable: read all
            for node in nodes { before[node.name] = node }
        }
        // Another folder in its place: nothing below it can be reused unlisted.
        let listBelow = listAll || (previous != nil && !sameFolder)

        let listed: [URL]
        do {
            listed = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch _ where walk.tolerant && FileWalker.vanished(dir.path, expectDirectory: true) {
            return nil
        }
        let siblingNames = Set(listed.map(\.lastPathComponent))
        var entries: [(url: URL, rv: URLResourceValues)] = []
        for entry in listed {
            let entryName = entry.lastPathComponent
            let entryRel = rel.isEmpty ? entryName : rel + "/" + entryName
            if walk.exclusions.isExcluded(relativePath: entryRel, name: entryName) { continue }
            let rv = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if rv.isDirectory == true, rv.isSymbolicLink != true,
               walk.exclusions.isArtifactDirectory(at: entry, name: entryName, siblings: { siblingNames.contains($0) }) {
                continue
            }
            entries.append((entry, rv))
        }
        entries.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }

        var nodes = [TreeNode?](repeating: nil, count: entries.count)
        var fileCount = 0
        var bytes = 0
        var toRead: [(index: Int, url: URL, name: String, old: TreeNode?)] = []

        // Folders (recursion), symlinks and unchanged files inline; the files to read are collected and read,
        // chunked and sealed in parallel below (the CPU/IO-heavy part).
        for (i, (entry, rv)) in entries.enumerated() {
            let entryName = entry.lastPathComponent
            if rv.isSymbolicLink == true {
                do {
                    nodes[i] = TreeNode(kind: .symlink, name: entryName,
                                        target: try FileManager.default.destinationOfSymbolicLink(atPath: entry.path))
                } catch _ where walk.tolerant && FileWalker.vanished(entry.path) {
                    continue
                }
            } else if rv.isDirectory == true {
                let childRel = rel.isEmpty ? entryName : rel + "/" + entryName
                guard let child = try await backUpDirectory(entry, name: entryName, source: source, rel: childRel,
                                                            parent: before[entryName], scope: scope,
                                                            listAll: listBelow, walk: walk) else { continue }
                nodes[i] = child
                fileCount += child.fileCount ?? 0
                bytes += child.totalBytes ?? 0
            } else {
                let old = before[entryName].flatMap { $0.kind == .file ? $0 : nil }
                guard let stamp = FileStamp(path: entry.path) else {
                    if walk.tolerant && FileWalker.vanished(entry.path) { continue }
                    throw InfraError(operation: "lstat", path: entry.path, code: errno)
                }
                if let old, old.size == Int(stamp.size), let oldTime = old.mtimeNs, oldTime == stamp.mtimeNs {
                    nodes[i] = old   // unchanged: its blobs as they are
                    fileCount += 1
                    bytes += old.size ?? 0
                } else if walk.session.shouldDefer(modificationDate: stamp.modified) {
                    walk.leave(in: source, rel: rel)
                    if let old { nodes[i] = old; fileCount += 1; bytes += old.size ?? 0 }
                } else {
                    toRead.append((i, entry, entryName, old))
                }
            }
        }

        // Seal files in parallel (read + FastCDC + AES-GCM off the actor), with bounded concurrency so we
        // don't load too many files into memory at once. Pack append stays serial on the BlobStore.
        let cipher = self.cipher
        let chunker = self.chunker
        let settling = walk.quietWindow == 0
        let tolerant = walk.tolerant
        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var changing: [(index: Int, old: TreeNode?)] = []
        try await withThrowingTaskGroup(of: (Int, TreeNode?, SealOutcome?).self) { group in
            var next = toRead.makeIterator()
            var inFlight = 0
            func schedule() {
                guard let f = next.next() else { return }
                group.addTask {
                    do {
                        return (f.index, f.old, try Self.sealFile(at: f.url, name: f.name, settling: settling,
                                                                   cipher: cipher, chunker: chunker))
                    } catch _ where tolerant && FileWalker.vanished(f.url.path) {
                        return (f.index, nil, nil)   // deleted while we read it: not part of this snapshot
                    }
                }
                inFlight += 1
            }
            for _ in 0..<maxConcurrent { schedule() }
            while inFlight > 0 {
                guard let result = try await group.next() else { break }
                let (index, old, outcome) = result
                inFlight -= 1
                switch outcome {
                case let .sealed(sealed):
                    for blob in sealed.blobs { try await blobStore.addSealed(blobID: blob.id, ciphertext: blob.ct) }
                    nodes[index] = sealed.node
                    fileCount += 1
                    bytes += sealed.size
                case .changing:
                    changing.append((index, old))
                case nil:
                    break
                }
                schedule()
            }
        }
        // Changed while read: left for later, keeping what the parent had.
        for (index, old) in changing {
            walk.leave(in: source, rel: rel)
            if let old { nodes[index] = old; fileCount += 1; bytes += old.size ?? 0 }
        }

        let treeID = try await writeTree(nodes.compactMap { $0 })
        return TreeNode(kind: .directory, name: name, treeID: treeID, ino: ino, fileCount: fileCount, totalBytes: bytes)
    }

    private struct SealedFile: Sendable {
        let node: TreeNode
        let size: Int
        let blobs: [(id: Data, ct: Data)]
    }

    private enum SealOutcome: Sendable {
        case sealed(SealedFile)
        /// It changed while read (not in a settle pass): nothing of this read is kept.
        case changing
    }

    /// What a read is judged by: a file whose stamp moves while it is read may have been read torn.
    private struct FileStamp: Equatable, Sendable {
        let size: Int64
        let mtimeNs: Int64
        let ctimeNs: Int64
        let ino: UInt64
        let mode: UInt16

        init?(path: String) {
            var st = Darwin.stat()
            guard lstat(path, &st) == 0 else { return nil }
            size = Int64(st.st_size)
            mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
            ctimeNs = Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec)
            ino = UInt64(st.st_ino)
            mode = UInt16(st.st_mode & 0o7777)
        }

        var modified: Date { Date(timeIntervalSince1970: Double(mtimeNs) / 1_000_000_000) }
    }

    /// Read a file, chunk it, and AES-GCM-seal every chunk — pure CPU/IO with no shared state, so it's safe
    /// to run on many files concurrently. The file is looked at just before and after the read: if it moved,
    /// the read may be torn — dropped, or in a settle pass read again (see the file notes).
    private static func sealFile(at url: URL, name: String, settling: Bool,
                                 cipher: BlobCipher, chunker: FastCDC) throws -> SealOutcome {
        for attempt in 1...settleReadAttempts {
            guard let before = FileStamp(path: url.path) else {
                throw InfraError(operation: "lstat", path: url.path, code: errno)
            }
            let data = try Data(contentsOf: url)   // TODO: stream very large files through FastCDC
            var ranges: [Range<Int>] = []
            chunker.chunk(data) { ranges.append($0) }
            var blobs: [(id: Data, ct: Data)] = []
            blobs.reserveCapacity(ranges.count)
            for range in ranges {
                let (id, ct) = try cipher.seal(data.subdata(in: range))
                blobs.append((id, ct))
            }
            let stable = FileStamp(path: url.path) == before
            guard stable || settling else { return .changing }
            if stable || attempt == settleReadAttempts {
                let node = TreeNode(kind: .file, name: name, blobs: blobs.map { $0.id }, size: data.count,
                                    mode: before.mode, mtime: before.modified.timeIntervalSince1970,
                                    mtimeNs: before.mtimeNs)
                return .sealed(SealedFile(node: node, size: data.count, blobs: blobs))
            }
        }
        return .changing
    }

    /// Serialize, encrypt, and store a tree (content-addressed → an identical tree is stored once).
    private func writeTree(_ nodes: [TreeNode]) async throws -> String {
        let treeData = try Self.canonicalEncoder.encode(nodes)
        let treeID = Self.hashHex(treeData)
        let key = "trees/\(treeID.prefix(2))/\(treeID)"
        if ((try? await backend.stat(key: key)) ?? nil) == nil {
            try await backend.put(key: key, data: try cipher.sealMetadata(treeData, context: "trees/\(treeID)"))
        }
        return treeID
    }

    // MARK: - Restore

    func restore(snapshotID: String, to destination: URL) async throws {
        try await blobStore.loadIndex()
        let sealed = try await backend.get(key: "snapshots/\(snapshotID)")
        let snapshot = try JSONDecoder().decode(
            Snapshot.self, from: cipher.openMetadata(sealed, context: "snapshots/\(snapshotID)"))
        try await restoreTree(snapshot.rootTreeID, to: destination)
    }

    private func restoreTree(_ treeID: String, to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = "trees/\(treeID.prefix(2))/\(treeID)"
        let sealed = try await backend.get(key: key)
        let nodes = try JSONDecoder().decode(
            [TreeNode].self, from: cipher.openMetadata(sealed, context: "trees/\(treeID)"))

        for node in nodes {
            let target = dir.appendingPathComponent(node.name)
            switch node.kind {
            case .directory:
                try await restoreTree(node.treeID ?? "", to: target)

            case .symlink:
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(atPath: target.path,
                                                           withDestinationPath: node.target ?? "")

            case .file:
                var data = Data()
                for blobID in node.blobs ?? [] { data.append(try await blobStore.get(blobID)) }
                // Atomic: write a temp sibling then rename over — never overwrite the target in place.
                let tmp = dir.appendingPathComponent(".restore-\(UUID().uuidString)")
                try data.write(to: tmp)
                _ = try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tmp, to: target)
                if let mode = node.mode {
                    try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                                           ofItemAtPath: target.path)
                }
                Self.restoreModificationTime(of: target.path, from: node)
            }
        }
    }

    /// A restored file gets its modification time back — to the nanosecond when its node has it (older
    /// nodes: to the microsecond of their seconds value), as a plaintext restore's copy keeps it.
    private static func restoreModificationTime(of path: String, from node: TreeNode) {
        let ns: Int64
        if let exact = node.mtimeNs {
            ns = exact
        } else if let seconds = node.mtime {
            ns = Int64((seconds * 1_000_000_000).rounded())
        } else {
            return
        }
        // Floor division, so a time before 1970 keeps a non-negative nanosecond part.
        let second = ns >= 0 ? ns / 1_000_000_000 : (ns - 999_999_999) / 1_000_000_000
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(second), tv_nsec: Int(ns - second * 1_000_000_000))]
        _ = utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
    }

    /// Deterministic key order is REQUIRED for content addressing: without `.sortedKeys`, Foundation's
    /// JSONEncoder emits struct keys in an unstable order, so identical trees would hash differently
    /// and never dedup.
    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static func hashHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
