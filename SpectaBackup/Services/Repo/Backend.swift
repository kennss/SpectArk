//
//  @file        Backend.swift
//  @description Object-store abstraction for the encrypted dedup repo. Keys are repo-relative paths
//               ("config", "keys/<slot>", "data/<aa>/<packID>", "index/<id>", "snapshots/<id>",
//               "trees/<id>"). Implementations: LocalBackend now; S3-compatible / Google Drive /
//               iCloud later. Dedup and commit must rely on stat-by-id + committed index objects,
//               never on list() (which is eventually consistent on cloud backends).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-30
//  @lastUpdated 2026-09-19
//

import Foundation

struct BackendStat: Sendable {
    let size: Int
}

/// Per-backend traits so the engine can adapt (e.g. whole-pack download when range is unsupported).
struct BackendCapabilities: Sendable {
    var supportsRange: Bool
    var isStronglyConsistent: Bool
    var maxObjectSize: Int64        // .max if effectively unbounded
    var dailyUploadCap: Int64       // bytes/day; 0 = none
    var permanentDeleteRequired: Bool
}

protocol Backend: Sendable {
    var capabilities: BackendCapabilities { get }

    func put(key: String, data: Data) async throws
    func get(key: String) async throws -> Data
    /// Range read (for reading one blob out of a pack). Backends without range fetch the whole object.
    func get(key: String, range: Range<Int>) async throws -> Data
    /// Read-your-writes existence/size by key — this is the trustworthy "exists", not list().
    func stat(key: String) async throws -> BackendStat?
    func list(prefix: String) async throws -> [String]
    /// What the objects under `prefix` occupy, in bytes (their sizes, as `stat` gives them).
    func bytes(prefix: String) async throws -> Int64
    func delete(key: String) async throws
    /// Make every object put so far durable (a write barrier): what is written after it — a snapshot, the
    /// commit point — can never survive a crash without what it refers to.
    func sync() async throws
}
