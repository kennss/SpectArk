//
//  @file        BlobStore.swift
//  @description Content-addressed blob storage for the dedup repo. Encrypts each blob (BlobCipher),
//               aggregates blobs into pack objects (data/<aa>/<id>) to avoid one-object-per-chunk
//               overhead, and records blobID→(pack,offset,len) in an encrypted per-pack index object
//               (index/<aa>/<id>). put() deduplicates against the in-memory index; get() does a Range
//               read of just the blob's slice and verifies it. The index is rebuildable from packs.
//               PackFormat writes and reads packs and their index objects — for BlobStore, and for the
//               garbage collector's repacking (RepoMaintenance).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-30
//  @lastUpdated 2026-09-19
//

import Foundation

enum BlobStoreError: Error, CustomStringConvertible {
    case blobNotFound
    var description: String { "blob not found in index" }
}

/// One blob's location inside a pack.
struct PackEntry: Codable, Sendable, Equatable {
    let blobID: Data
    let offset: Int
    let length: Int
}

/// Packs and their index objects as the repo stores them: `data/<aa>/<id>` holds the ciphertexts back to
/// back, `index/<aa>/<id>` the encrypted list of its entries.
enum PackFormat {

    /// One pack as its index object describes it.
    struct IndexedPack: Sendable {
        let packID: String      // "data/<aa>/<id>"
        let indexKey: String    // "index/<aa>/<id>"
        let entries: [PackEntry]
    }

    /// Write `blobs` as one new pack, then its index object. Returns what was written.
    static func write(_ blobs: [(blobID: Data, ciphertext: Data)], backend: Backend,
                      cipher: BlobCipher) async throws -> IndexedPack {
        let id = UUID().uuidString.lowercased()
        let shard = String(id.prefix(2))
        let packID = "data/\(shard)/\(id)"
        var packData = Data()
        var entries: [PackEntry] = []
        for (blobID, ciphertext) in blobs {
            entries.append(PackEntry(blobID: blobID, offset: packData.count, length: ciphertext.count))
            packData.append(ciphertext)
        }
        try await backend.put(key: packID, data: packData)
        let indexKey = "index/\(shard)/\(id)"
        try await backend.put(key: indexKey, data: try cipher.sealMetadata(try JSONEncoder().encode(entries), context: packID))
        return IndexedPack(packID: packID, indexKey: indexKey, entries: entries)
    }

    /// Every pack the repo's index objects describe.
    static func readIndex(backend: Backend, cipher: BlobCipher) async throws -> [IndexedPack] {
        var packs: [IndexedPack] = []
        for key in try await backend.list(prefix: "index") {
            let packID = "data/" + String(key.dropFirst("index/".count))    // "<aa>/<id>"
            let plaintext = try cipher.openMetadata(try await backend.get(key: key), context: packID)
            packs.append(IndexedPack(packID: packID, indexKey: key,
                                     entries: try JSONDecoder().decode([PackEntry].self, from: plaintext)))
        }
        return packs
    }
}

actor BlobStore {
    private let backend: Backend
    private let cipher: BlobCipher
    private let packTargetSize: Int

    struct Location: Sendable { let packID: String; let offset: Int; let length: Int }

    private var index: [Data: Location] = [:]
    private var pending: [(blobID: Data, ciphertext: Data)] = []
    private var pendingIDs: Set<Data> = []
    private var pendingSize = 0

    init(backend: Backend, keys: RepoKeys, packTargetSize: Int = 32 * 1024 * 1024) {
        self.backend = backend
        self.cipher = BlobCipher(keys: keys)
        self.packTargetSize = packTargetSize
    }

    var pendingCount: Int { pending.count }
    var indexCount: Int { index.count }

    /// Rebuild the in-memory index from committed per-pack index objects.
    func loadIndex() async throws {
        for pack in try await PackFormat.readIndex(backend: backend, cipher: cipher) {
            for entry in pack.entries {
                index[entry.blobID] = Location(packID: pack.packID, offset: entry.offset, length: entry.length)
            }
        }
    }

    /// Store a plaintext blob; returns its content-addressed ID. Deduplicates: an already-stored or
    /// already-pending blob is not re-buffered.
    @discardableResult
    func put(_ plaintext: Data) async throws -> Data {
        let (blobID, ciphertext) = try cipher.seal(plaintext)
        if index[blobID] != nil || pendingIDs.contains(blobID) { return blobID }
        pending.append((blobID, ciphertext))
        pendingIDs.insert(blobID)
        pendingSize += ciphertext.count
        if pendingSize >= packTargetSize { try await flush() }
        return blobID
    }

    /// Store a blob whose sealing was done off-actor (parallel encryption). Deduplicates against the
    /// index/pending, then appends to the current pack — same persistence path as `put`, minus the seal.
    func addSealed(blobID: Data, ciphertext: Data) async throws {
        if index[blobID] != nil || pendingIDs.contains(blobID) { return }
        pending.append((blobID, ciphertext))
        pendingIDs.insert(blobID)
        pendingSize += ciphertext.count
        if pendingSize >= packTargetSize { try await flush() }
    }

    /// Fetch and decrypt a blob by ID (Range read from its pack, or from the pending buffer).
    func get(_ blobID: Data) async throws -> Data {
        if let loc = index[blobID] {
            let ciphertext = try await backend.get(key: loc.packID,
                                                   range: loc.offset ..< (loc.offset + loc.length))
            return try cipher.open(blobID: blobID, ciphertext: ciphertext)
        }
        if let buffered = pending.first(where: { $0.blobID == blobID }) {
            return try cipher.open(blobID: blobID, ciphertext: buffered.ciphertext)
        }
        throw BlobStoreError.blobNotFound
    }

    func contains(_ blobID: Data) -> Bool {
        index[blobID] != nil || pendingIDs.contains(blobID)
    }

    /// Write the pending buffer as one pack + its encrypted index object, then commit to the index.
    func flush() async throws {
        guard !pending.isEmpty else { return }
        let pack = try await PackFormat.write(pending, backend: backend, cipher: cipher)
        for entry in pack.entries {
            index[entry.blobID] = Location(packID: pack.packID, offset: entry.offset, length: entry.length)
        }
        pending.removeAll()
        pendingIDs.removeAll()
        pendingSize = 0
    }
}
