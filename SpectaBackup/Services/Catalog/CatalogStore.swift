//
//  @file        CatalogStore.swift
//  @description SQLite-backed index of a job's snapshots (one DB per job, at the destination job root).
//               Records seqId (authoritative monotonic identity, via AUTOINCREMENT), status, and stats.
//               The on-disk snapshot tree is the source of truth; this catalog is a rebuildable accelerator.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - actor-isolated: the sqlite3 handle is single-threaded; all access is serialized through the actor.
//  - Durability: WAL journal + `PRAGMA fullfsync=ON` so commits use F_FULLFSYNC (true power-loss safety).
//  - A snapshot is only a valid restore point when its row reaches status `complete` AND its on-disk
//    COMPLETE marker exists (the engine enforces the marker; the catalog enforces the row).
//

import Foundation
import SQLite3

/// SQLite wants a destructor sentinel meaning "copy this buffer"; Swift can't import the C macro.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor CatalogStore {

    enum CatalogError: Error, CustomStringConvertible {
        case open(path: String, code: Int32)
        case sql(message: String, code: Int32)

        var description: String {
            switch self {
            case let .open(path, code): return "sqlite open failed for \(path) (code \(code))"
            case let .sql(message, code): return "sqlite error: \(message) (code \(code))"
            }
        }
    }

    // The sqlite handle is only ever touched inside this actor's serialized context (and in deinit,
    // when no other reference exists), so its access is safe; nonisolated(unsafe) silences the
    // Sendable check that `isolated deinit` would otherwise require (macOS 15.4+ only).
    nonisolated(unsafe) private var db: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let code = handle.map { sqlite3_errcode($0) } ?? SQLITE_CANTOPEN
            if let handle { sqlite3_close_v2(handle) }
            throw CatalogError.open(path: path, code: code)
        }
        db = handle
        try Self.execRaw(handle, "PRAGMA journal_mode=WAL;")
        try Self.execRaw(handle, "PRAGMA fullfsync=ON;")
        try Self.execRaw(handle, "PRAGMA busy_timeout=5000;")
        try Self.migrate(handle)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Schema

    private static func migrate(_ db: OpaquePointer?) throws {
        try execRaw(db, """
            CREATE TABLE IF NOT EXISTS snapshots (
                seqId            INTEGER PRIMARY KEY AUTOINCREMENT,
                jobID            TEXT    NOT NULL,
                timestamp        REAL    NOT NULL,
                dirName          TEXT    NOT NULL DEFAULT '',
                status           TEXT    NOT NULL,
                fileCount        INTEGER NOT NULL DEFAULT 0,
                logicalBytes     INTEGER NOT NULL DEFAULT 0,
                addedBlocks      INTEGER NOT NULL DEFAULT 0,
                durationMs       INTEGER NOT NULL DEFAULT 0,
                sourceSnapshotID TEXT
            );
            """)
        try execRaw(db, "CREATE INDEX IF NOT EXISTS idx_job_status_seq ON snapshots(jobID, status, seqId);")
    }

    // MARK: - Mutations

    /// Insert an in-progress snapshot row and return its assigned authoritative seqId.
    func beginSnapshot(jobID: UUID, timestamp: Date, sourceSnapshotID: String?) throws -> Int64 {
        let stmt = try prepare("""
            INSERT INTO snapshots (jobID, timestamp, status, sourceSnapshotID)
            VALUES (?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, jobID.uuidString)
        sqlite3_bind_double(stmt, 2, timestamp.timeIntervalSince1970)
        bindText(stmt, 3, SnapshotStatus.inProgress.rawValue)
        if let sourceSnapshotID { bindText(stmt, 4, sourceSnapshotID) } else { sqlite3_bind_null(stmt, 4) }
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    /// Promote a snapshot to `complete` and record its final stats.
    func markComplete(seqId: Int64, dirName: String, fileCount: Int, logicalBytes: Int64, addedBlocks: Int64, durationMs: Int) throws {
        let stmt = try prepare("""
            UPDATE snapshots
            SET status = ?, dirName = ?, fileCount = ?, logicalBytes = ?, addedBlocks = ?, durationMs = ?
            WHERE seqId = ?;
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, SnapshotStatus.complete.rawValue)
        bindText(stmt, 2, dirName)
        sqlite3_bind_int64(stmt, 3, Int64(fileCount))
        sqlite3_bind_int64(stmt, 4, logicalBytes)
        sqlite3_bind_int64(stmt, 5, addedBlocks)
        sqlite3_bind_int64(stmt, 6, Int64(durationMs))
        sqlite3_bind_int64(stmt, 7, seqId)
        try step(stmt)
    }

    /// Mark a snapshot failed (its on-disk `.inprogress` tree should be discarded by the engine).
    func markFailed(seqId: Int64) throws {
        let stmt = try prepare("UPDATE snapshots SET status = ? WHERE seqId = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, SnapshotStatus.failed.rawValue)
        sqlite3_bind_int64(stmt, 2, seqId)
        try step(stmt)
    }

    /// Re-register a complete snapshot tree that lost its row (1.1.x launch cleanup could drop the row of
    /// a snapshot it was still publishing), or whose row never became complete (the publish renamed the
    /// tree, then recording it failed). It keeps the seqId its directory name carries, so it takes its old
    /// place in the timeline; a complete row with that id wins.
    func adoptSnapshot(seqId: Int64, jobID: UUID, timestamp: Date, dirName: String, fileCount: Int,
                       logicalBytes: Int64) throws {
        let stmt = try prepare("""
            INSERT INTO snapshots (seqId, jobID, timestamp, dirName, status, fileCount, logicalBytes,
                                   addedBlocks, durationMs, sourceSnapshotID)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, NULL)
            ON CONFLICT(seqId) DO UPDATE SET timestamp = excluded.timestamp, dirName = excluded.dirName,
                status = excluded.status, fileCount = excluded.fileCount, logicalBytes = excluded.logicalBytes
            WHERE snapshots.status != excluded.status;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, seqId)
        bindText(stmt, 2, jobID.uuidString)
        sqlite3_bind_double(stmt, 3, timestamp.timeIntervalSince1970)
        bindText(stmt, 4, dirName)
        bindText(stmt, 5, SnapshotStatus.complete.rawValue)
        sqlite3_bind_int64(stmt, 6, Int64(fileCount))
        sqlite3_bind_int64(stmt, 7, logicalBytes)
        try step(stmt)
    }

    func deleteSnapshot(seqId: Int64) throws {
        let stmt = try prepare("DELETE FROM snapshots WHERE seqId = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, seqId)
        try step(stmt)
    }

    // MARK: - Queries

    /// The newest COMPLETE snapshot for a job — the base for the next incremental pass.
    /// Ordered by seqId (authoritative), never by timestamp.
    func latestComplete(jobID: UUID) throws -> SnapshotRecord? {
        let stmt = try prepare("""
            \(selectColumns)
            WHERE jobID = ? AND status = ?
            ORDER BY seqId DESC LIMIT 1;
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, jobID.uuidString)
        bindText(stmt, 2, SnapshotStatus.complete.rawValue)
        return sqlite3_step(stmt) == SQLITE_ROW ? readRow(stmt) : nil
    }

    /// All snapshots for a job, newest first (by seqId).
    func snapshots(jobID: UUID) throws -> [SnapshotRecord] {
        let stmt = try prepare("\(selectColumns) WHERE jobID = ? ORDER BY seqId DESC;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, jobID.uuidString)
        var rows: [SnapshotRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(readRow(stmt)) }
        return rows
    }

    // MARK: - Row mapping

    private let selectColumns = """
        SELECT seqId, jobID, timestamp, dirName, status, fileCount, logicalBytes, addedBlocks, durationMs, sourceSnapshotID
        FROM snapshots
        """

    private func readRow(_ stmt: OpaquePointer?) -> SnapshotRecord {
        SnapshotRecord(
            seqId: sqlite3_column_int64(stmt, 0),
            jobID: UUID(uuidString: columnText(stmt, 1) ?? "") ?? UUID(),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            dirName: columnText(stmt, 3) ?? "",
            status: SnapshotStatus(rawValue: columnText(stmt, 4) ?? "") ?? .failed,
            fileCount: Int(sqlite3_column_int64(stmt, 5)),
            logicalBytes: sqlite3_column_int64(stmt, 6),
            addedBlocks: sqlite3_column_int64(stmt, 7),
            durationMs: Int(sqlite3_column_int64(stmt, 8)),
            sourceSnapshotID: columnText(stmt, 9)
        )
    }

    // MARK: - Low-level helpers

    private static func execRaw(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw CatalogError.sql(message: message, code: sqlite3_errcode(db))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CatalogError.sql(message: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db))
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CatalogError.sql(message: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db))
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
