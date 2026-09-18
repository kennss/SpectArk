//
//  @file        HistoryStore.swift
//  @description SQLite catalog of the history engine — one `history.sqlite` per job at the destination.
//               Holds the items currently in current/ (`entries`), superseded versions kept in
//               versions/ (`versions`), sealed checkpoints, write-ahead intents for crash recovery, and
//               small state (pending generation, unsealed-changes flag, end of the last pass).
//               Design: docs/INCREMENTAL_ENGINE_DESIGN.md §3.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Owned by one capture pass at a time (the BackupRunner actor serialises passes), so it is a plain
//    class and deliberately not Sendable.
//  - Durability: WAL + `fullfsync=ON`, so every COMMIT issues F_FULLFSYNC. The capture engine pushes a
//    batch's file writes with plain fsync and relies on that single cache flush per commit.
//  - Paths are relative to current/ and always start with the source folder's name ("Developments/a").
//    They are stored and looked up in Unicode NFC (`key(_:)`): SQLite compares bytes while Swift strings
//    and APFS/HFS+ names compare by canonical equivalence, so a name spelled NFD on disk (common for
//    Korean names made in Finder) must map to one row, or a rename that only changes normalization would
//    leave a ghost row. The file system resolves either spelling to the same file.
//  - Generations: an entry's `born` is the generation in which that version entered current/; a version
//    row covers checkpoints `born … died-1`. The pending generation is the next checkpoint's number.
//  - `parent` (derived from `path` on write; "" at the top) indexes directory listings for browsing.
//  - `source_ino` (directories): the source directory's inode as of the last pass that compared its whole
//    subtree and finished. 0 = never fully compared (e.g. added by an interrupted pass). A journal pass
//    compares a directory whose inode differs — replaced by another directory, or unverified — whole.
//  - Pruning deletes version rows before their files; `sweep_pending` marks a prune whose file deletions
//    may not have finished, so the next maintenance sweeps versions/ for files no row references.
//  - `lock_flags`: the source item's UF_IMMUTABLE/UF_APPEND. Copies in current/ and versions/ never carry
//    them (they forbid the renames the engine relies on); restore puts them back.
//  - `seeded`: rows placed by HistorySeeder — clones of a legacy snapshot tree, so their blocks are shared
//    with it for retention accounting. Any replacement clears it.
//  - Schema version (PRAGMA user_version): 1 = history engine as first shipped (1.2.0 build 8); 2 = lock
//    flags, seeded rows, NFC path keys. Older catalogs are upgraded in one transaction when opened.
//

import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum HistoryItemKind: Int64, Sendable {
    case file = 0
    case directory = 1
    case symlink = 2
}

/// An item present in current/.
struct HistoryEntry: Equatable, Sendable {
    let path: String
    let kind: HistoryItemKind
    /// Source size in bytes (0 for directories).
    let size: Int64
    /// Source modification time in ns since 1970 (0 for directories).
    let mtimeNs: Int64
    /// Generation in which this version entered current/.
    let born: Int64
    /// Inode of the item in current/ — lets recovery tell the old file from its replacement.
    let mirrorIno: UInt64
    /// Directories: inode of the source directory when its subtree was last fully compared; 0 = not yet.
    var sourceIno: UInt64 = 0
    /// The source's lock flags (UF_IMMUTABLE/UF_APPEND), re-applied on restore.
    var lockFlags: UInt32 = 0
    /// Placed by HistorySeeder (a clone of legacy snapshot data) and not replaced since.
    var seeded = false
}

/// A superseded item kept for the checkpoints `born … died-1`.
struct HistoryVersion: Equatable, Sendable {
    let id: Int64
    let path: String
    let kind: HistoryItemKind
    let size: Int64
    let mtimeNs: Int64
    let born: Int64
    let died: Int64
    /// File name in versions/ (nil for directories, which have no content to keep).
    let stored: String?
    var lockFlags: UInt32 = 0
}

/// One item as browsed at a checkpoint (or in current/). `stored` is set when its content lives in
/// versions/ rather than current/.
struct HistoryItemRecord: Equatable, Sendable {
    let path: String
    let kind: HistoryItemKind
    let size: Int64
    let mtimeNs: Int64
    let stored: String?
    /// Lock flags to put back on a restored copy.
    var lockFlags: UInt32 = 0

    var name: String { (path as NSString).lastPathComponent }
}

struct HistoryCheckpoint: Equatable, Sendable {
    let seq: Int64
    let time: Date
    let files: Int64
    let bytes: Int64
}

/// What a capture pass is about to do to one path. Logged (and durable) before current/ is touched.
struct HistoryIntent: Equatable, Sendable {
    enum Op: Int64, Sendable {
        case addDirectory = 0
        case put = 1
        case remove = 2
    }

    let id: Int64
    let op: Op
    let path: String
    /// The entry being replaced or removed, as it was when the intent was logged.
    let old: HistoryEntry?
    /// Planned kind/size/mtime of the new item (put/addDirectory), from the source.
    let newKind: HistoryItemKind
    let newSize: Int64
    let newMtimeNs: Int64
    /// Lock flags of the new item's source.
    var newLockFlags: UInt32 = 0
    /// Generation the new item is born in (the pending generation when logged).
    let generation: Int64

    /// The old item is part of a checkpoint, so it moves to versions/ instead of being unlinked.
    var retainsOld: Bool { old.map { $0.born < generation } ?? false }
    /// Its name in versions/ when retained (intent ids are never reused).
    var storedName: String { String(id) }
}

/// The catalog change that settles one intent.
enum IntentResolution: Sendable {
    /// Nothing reached current/; drop the intent.
    case rollback(intentID: Int64)
    /// current/ now holds `entry` at the intent's path (nil = the path is gone), and the old item was
    /// kept in versions/ when `retired` is set.
    case applied(intentID: Int64, path: String, entry: HistoryEntry?, retired: RetiredVersion?)
}

struct RetiredVersion: Equatable, Sendable {
    let old: HistoryEntry
    let died: Int64
    let stored: String?
}

final class HistoryStore {

    enum StoreError: Error, CustomStringConvertible {
        case open(path: String, code: Int32)
        case sql(message: String, code: Int32)

        var description: String {
            switch self {
            case let .open(path, code): return "history catalog open failed for \(path) (code \(code))"
            case let .sql(message, code): return "history catalog error: \(message) (code \(code))"
            }
        }
    }

    private var db: OpaquePointer?
    /// current/ beside the catalog (HistoryLayout), consulted only by the schema upgrade.
    private let mirrorRoot: String

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let code = handle.map { sqlite3_errcode($0) } ?? SQLITE_CANTOPEN
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError.open(path: path, code: code)
        }
        db = handle
        mirrorRoot = (path as NSString).deletingLastPathComponent + "/current"
        try exec("PRAGMA busy_timeout=5000;")   // first: even switching the journal mode can meet a lock
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA fullfsync=ON;")
        try migrate()
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    /// The stored form of a catalog path: Unicode NFC (see the notes above).
    static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    // MARK: - Schema

    static let schemaVersion: Int64 = 2

    private func migrate() throws {
        // Version 1, as first shipped; later versions are applied on top.
        try exec("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS entries (
                path      TEXT    PRIMARY KEY,
                parent    TEXT    NOT NULL,
                kind      INTEGER NOT NULL,
                size      INTEGER NOT NULL,
                mtime_ns  INTEGER NOT NULL,
                born      INTEGER NOT NULL,
                mirror_ino INTEGER NOT NULL,
                source_ino INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS versions (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                path      TEXT    NOT NULL,
                parent    TEXT    NOT NULL,
                kind      INTEGER NOT NULL,
                size      INTEGER NOT NULL,
                mtime_ns  INTEGER NOT NULL,
                born      INTEGER NOT NULL,
                died      INTEGER NOT NULL,
                stored    TEXT
            );
            CREATE INDEX IF NOT EXISTS entries_parent ON entries(parent);
            CREATE INDEX IF NOT EXISTS versions_path ON versions(path, born);
            CREATE INDEX IF NOT EXISTS versions_parent ON versions(parent, born);
            CREATE INDEX IF NOT EXISTS versions_span ON versions(born, died);
            CREATE TABLE IF NOT EXISTS checkpoints (
                seq   INTEGER PRIMARY KEY,
                time  REAL    NOT NULL,
                files INTEGER NOT NULL,
                bytes INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS intents (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                op         INTEGER NOT NULL,
                path       TEXT    NOT NULL,
                old_kind   INTEGER,
                old_size   INTEGER,
                old_mtime  INTEGER,
                old_born   INTEGER,
                old_ino    INTEGER,
                new_kind   INTEGER NOT NULL,
                new_size   INTEGER NOT NULL,
                new_mtime  INTEGER NOT NULL,
                generation INTEGER NOT NULL
            );
            """)
        guard try userVersion() < Self.schemaVersion else { return }
        let hadEntries = try exists("SELECT 1 FROM entries LIMIT 1;")
        try transaction {
            try addColumn("entries", "lock_flags INTEGER NOT NULL DEFAULT 0")
            try addColumn("entries", "seeded INTEGER NOT NULL DEFAULT 0")
            try addColumn("versions", "lock_flags INTEGER NOT NULL DEFAULT 0")
            try addColumn("intents", "old_flags INTEGER NOT NULL DEFAULT 0")
            try addColumn("intents", "new_flags INTEGER NOT NULL DEFAULT 0")
            try normalizeStoredPaths()
            // A new catalog has no mirror copies that an earlier build could have left locked.
            if !hadEntries { try setMeta("mirror_locks_checked", "1") }
            try exec("PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    private func exists(_ sql: String) throws -> Bool {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func userVersion() throws -> Int64 {
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    private func addColumn(_ table: String, _ definition: String) throws {
        let name = String(definition.prefix { $0 != " " })
        let info = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(info) }
        while sqlite3_step(info) == SQLITE_ROW {
            if columnText(info, 1) == name { return }
        }
        try exec("ALTER TABLE \(table) ADD COLUMN \(definition);")
    }

    /// Version 2 stores paths in NFC. Rewrite version-1 rows spelled otherwise (byte comparison: Swift's
    /// `==` would call them equal). Two entries for one name can only be a ghost and its successor. The
    /// live one is the row whose mirror inode is the file now in current/; failing that, the one born
    /// later (an upsert keeps a row's rowid, so insertion order proves nothing).
    private func normalizeStoredPaths() throws {
        func differs(_ a: String, _ b: String) -> Bool { !a.utf8.elementsEqual(b.utf8) }

        var entryRenames: [(rowid: Int64, key: String, born: Int64, ino: UInt64)] = []
        let entries = try prepare("SELECT rowid, path, born, mirror_ino FROM entries;")
        while sqlite3_step(entries) == SQLITE_ROW {
            let path = columnText(entries, 1) ?? ""
            if differs(Self.key(path), path) {
                entryRenames.append((sqlite3_column_int64(entries, 0), Self.key(path), sqlite3_column_int64(entries, 2),
                                     UInt64(bitPattern: sqlite3_column_int64(entries, 3))))
            }
        }
        sqlite3_finalize(entries)
        let occupant = try prepare("SELECT rowid, born, mirror_ino FROM entries WHERE path = ?;")
        let deleteRow = try prepare("DELETE FROM entries WHERE rowid = ?;")
        let renameEntry = try prepare("UPDATE entries SET path = ?, parent = ? WHERE rowid = ?;")
        defer { [occupant, deleteRow, renameEntry].forEach { sqlite3_finalize($0) } }
        for rename in entryRenames {
            sqlite3_reset(occupant)
            sqlite3_clear_bindings(occupant)
            bindText(occupant, 1, rename.key)
            if sqlite3_step(occupant) == SQLITE_ROW {
                let other = (rowid: sqlite3_column_int64(occupant, 0), born: sqlite3_column_int64(occupant, 1),
                             ino: UInt64(bitPattern: sqlite3_column_int64(occupant, 2)))
                var st = Darwin.stat()
                let onDisk: UInt64? = lstat(mirrorRoot + "/" + rename.key, &st) == 0 ? UInt64(st.st_ino) : nil
                // The disk decides when exactly one row names the file there; otherwise the later born.
                let otherMatches = onDisk == other.ino, mineMatches = onDisk == rename.ino
                let otherIsLive = otherMatches != mineMatches ? otherMatches : other.born > rename.born
                if otherIsLive {
                    try run(deleteRow) { sqlite3_bind_int64($0, 1, rename.rowid) }
                    continue
                }
                try run(deleteRow) { sqlite3_bind_int64($0, 1, other.rowid) }
            }
            try run(renameEntry) { stmt in
                self.bindText(stmt, 1, rename.key)
                self.bindText(stmt, 2, Self.parent(of: rename.key))
                sqlite3_bind_int64(stmt, 3, rename.rowid)
            }
        }

        for (table, setParent) in [("versions", true), ("intents", false)] {
            var renames: [(id: Int64, key: String)] = []
            let rows = try prepare("SELECT id, path FROM \(table);")
            while sqlite3_step(rows) == SQLITE_ROW {
                let path = columnText(rows, 1) ?? ""
                if differs(Self.key(path), path) { renames.append((sqlite3_column_int64(rows, 0), Self.key(path))) }
            }
            sqlite3_finalize(rows)
            let update = try prepare(setParent ? "UPDATE \(table) SET path = ?, parent = ? WHERE id = ?;"
                                               : "UPDATE \(table) SET path = ? WHERE id = ?;")
            defer { sqlite3_finalize(update) }
            for rename in renames {
                try run(update) { stmt in
                    self.bindText(stmt, 1, rename.key)
                    if setParent {
                        self.bindText(stmt, 2, Self.parent(of: rename.key))
                        sqlite3_bind_int64(stmt, 3, rename.id)
                    } else {
                        sqlite3_bind_int64(stmt, 2, rename.id)
                    }
                }
            }
        }

        // Journal cursors are keyed by source name.
        var cursorKeys: [String] = []
        let keys = try prepare("SELECT key FROM meta WHERE key LIKE 'journal:%';")
        while sqlite3_step(keys) == SQLITE_ROW { cursorKeys.append(columnText(keys, 0) ?? "") }
        sqlite3_finalize(keys)
        for key in cursorKeys where differs(Self.key(key), key) {
            if let value = try metaText(key) {
                try deleteMeta(key)
                try setMeta(Self.key(key), value)
            }
        }
    }

    // MARK: - State

    /// The number the next checkpoint will get; items entering current/ now are born in it.
    func pendingGeneration() throws -> Int64 {
        try metaInt("pending_generation") ?? 1
    }

    /// current/ holds changes that no checkpoint contains yet.
    func hasUnsealedChanges() throws -> Bool {
        try (metaInt("unsealed") ?? 0) != 0
    }

    func lastPassEnd() throws -> Date? {
        try metaDouble("last_pass_end").map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - Queries

    private static let entryColumns = "path, kind, size, mtime_ns, born, mirror_ino, source_ino, lock_flags, seeded"

    func allEntries() throws -> [String: HistoryEntry] {
        try entryMap("SELECT \(Self.entryColumns) FROM entries;", [])
    }

    func entry(at path: String) throws -> HistoryEntry? {
        let stmt = try prepare("SELECT \(Self.entryColumns) FROM entries WHERE path = ?;")
        defer { sqlite3_finalize(stmt) }
        bindPath(stmt, 1, path)
        return sqlite3_step(stmt) == SQLITE_ROW ? readEntry(stmt, from: 0) : nil
    }

    /// Versions of one path (or all when nil), oldest first.
    func versions(of path: String? = nil) throws -> [HistoryVersion] {
        let sql = "SELECT id, path, kind, size, mtime_ns, born, died, stored, lock_flags FROM versions"
            + (path == nil ? "" : " WHERE path = ?") + " ORDER BY born, id;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let path { bindPath(stmt, 1, path) }
        var rows: [HistoryVersion] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(HistoryVersion(id: sqlite3_column_int64(stmt, 0),
                                       path: columnText(stmt, 1) ?? "",
                                       kind: HistoryItemKind(rawValue: sqlite3_column_int64(stmt, 2)) ?? .file,
                                       size: sqlite3_column_int64(stmt, 3),
                                       mtimeNs: sqlite3_column_int64(stmt, 4),
                                       born: sqlite3_column_int64(stmt, 5),
                                       died: sqlite3_column_int64(stmt, 6),
                                       stored: columnText(stmt, 7),
                                       lockFlags: UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 8))))
        }
        return rows
    }

    /// Checkpoints, oldest first.
    func checkpoints() throws -> [HistoryCheckpoint] {
        let stmt = try prepare("SELECT seq, time, files, bytes FROM checkpoints ORDER BY seq;")
        defer { sqlite3_finalize(stmt) }
        var rows: [HistoryCheckpoint] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(HistoryCheckpoint(seq: sqlite3_column_int64(stmt, 0),
                                          time: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                          files: sqlite3_column_int64(stmt, 2),
                                          bytes: sqlite3_column_int64(stmt, 3)))
        }
        return rows
    }

    func lastCheckpoint() throws -> HistoryCheckpoint? {
        try checkpoints().last
    }

    // MARK: - Intents

    struct IntentDraft: Sendable {
        let op: HistoryIntent.Op
        let path: String
        let old: HistoryEntry?
        let newKind: HistoryItemKind
        let newSize: Int64
        let newMtimeNs: Int64
        var newLockFlags: UInt32 = 0
    }

    /// Log a batch of intents durably (one commit) and return them with their ids. Paths come back as
    /// stored (NFC).
    func logIntents(_ drafts: [IntentDraft]) throws -> [HistoryIntent] {
        let generation = try pendingGeneration()
        var logged: [HistoryIntent] = []
        try transaction {
            let stmt = try prepare("""
                INSERT INTO intents (op, path, old_kind, old_size, old_mtime, old_born, old_ino, old_flags,
                                     new_kind, new_size, new_mtime, new_flags, generation)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            for draft in drafts {
                let path = Self.key(draft.path)
                try run(stmt) { stmt in
                    sqlite3_bind_int64(stmt, 1, draft.op.rawValue)
                    self.bindText(stmt, 2, path)
                    if let old = draft.old {
                        sqlite3_bind_int64(stmt, 3, old.kind.rawValue)
                        sqlite3_bind_int64(stmt, 4, old.size)
                        sqlite3_bind_int64(stmt, 5, old.mtimeNs)
                        sqlite3_bind_int64(stmt, 6, old.born)
                        sqlite3_bind_int64(stmt, 7, Int64(bitPattern: old.mirrorIno))
                        sqlite3_bind_int64(stmt, 8, Int64(old.lockFlags))
                    } else {
                        for index in 3...7 { sqlite3_bind_null(stmt, Int32(index)) }
                        sqlite3_bind_int64(stmt, 8, 0)
                    }
                    sqlite3_bind_int64(stmt, 9, draft.newKind.rawValue)
                    sqlite3_bind_int64(stmt, 10, draft.newSize)
                    sqlite3_bind_int64(stmt, 11, draft.newMtimeNs)
                    sqlite3_bind_int64(stmt, 12, Int64(draft.newLockFlags))
                    sqlite3_bind_int64(stmt, 13, generation)
                }
                logged.append(HistoryIntent(id: sqlite3_last_insert_rowid(db), op: draft.op, path: path,
                                            old: draft.old, newKind: draft.newKind, newSize: draft.newSize,
                                            newMtimeNs: draft.newMtimeNs, newLockFlags: draft.newLockFlags,
                                            generation: generation))
            }
        }
        return logged
    }

    /// Intents left by an interrupted pass, in the order they were logged.
    func pendingIntents() throws -> [HistoryIntent] {
        let stmt = try prepare("""
            SELECT id, op, path, old_kind, old_size, old_mtime, old_born, old_ino,
                   new_kind, new_size, new_mtime, generation, old_flags, new_flags
            FROM intents ORDER BY id;
            """)
        defer { sqlite3_finalize(stmt) }
        var rows: [HistoryIntent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = columnText(stmt, 2) ?? ""
            let old: HistoryEntry? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : HistoryEntry(
                path: path,
                kind: HistoryItemKind(rawValue: sqlite3_column_int64(stmt, 3)) ?? .file,
                size: sqlite3_column_int64(stmt, 4),
                mtimeNs: sqlite3_column_int64(stmt, 5),
                born: sqlite3_column_int64(stmt, 6),
                mirrorIno: UInt64(bitPattern: sqlite3_column_int64(stmt, 7)),
                lockFlags: UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 12)))
            rows.append(HistoryIntent(id: sqlite3_column_int64(stmt, 0),
                                      op: HistoryIntent.Op(rawValue: sqlite3_column_int64(stmt, 1)) ?? .put,
                                      path: path,
                                      old: old,
                                      newKind: HistoryItemKind(rawValue: sqlite3_column_int64(stmt, 8)) ?? .file,
                                      newSize: sqlite3_column_int64(stmt, 9),
                                      newMtimeNs: sqlite3_column_int64(stmt, 10),
                                      newLockFlags: UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 13)),
                                      generation: sqlite3_column_int64(stmt, 11)))
        }
        return rows
    }

    /// Settle a batch of intents in one commit. Any applied change marks current/ as unsealed.
    func resolve(_ resolutions: [IntentResolution]) throws {
        guard !resolutions.isEmpty else { return }
        try transaction {
            let upsert = try prepare("""
                INSERT INTO entries (path, parent, kind, size, mtime_ns, born, mirror_ino, source_ino, lock_flags, seeded)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, 0)
                ON CONFLICT(path) DO UPDATE SET kind = excluded.kind, size = excluded.size,
                    mtime_ns = excluded.mtime_ns, born = excluded.born, mirror_ino = excluded.mirror_ino,
                    source_ino = 0, lock_flags = excluded.lock_flags, seeded = 0;
                """)
            let deleteEntry = try prepare("DELETE FROM entries WHERE path = ?;")
            let insertVersion = try prepare("""
                INSERT INTO versions (path, parent, kind, size, mtime_ns, born, died, stored, lock_flags)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
            let deleteIntent = try prepare("DELETE FROM intents WHERE id = ?;")
            defer { [upsert, deleteEntry, insertVersion, deleteIntent].forEach { sqlite3_finalize($0) } }

            var changed = false
            for resolution in resolutions {
                switch resolution {
                case let .rollback(intentID):
                    try run(deleteIntent) { sqlite3_bind_int64($0, 1, intentID) }
                case let .applied(intentID, path, entry, retired):
                    if let retired {
                        let oldPath = Self.key(retired.old.path)
                        try run(insertVersion) { stmt in
                            self.bindText(stmt, 1, oldPath)
                            self.bindText(stmt, 2, Self.parent(of: oldPath))
                            sqlite3_bind_int64(stmt, 3, retired.old.kind.rawValue)
                            sqlite3_bind_int64(stmt, 4, retired.old.size)
                            sqlite3_bind_int64(stmt, 5, retired.old.mtimeNs)
                            sqlite3_bind_int64(stmt, 6, retired.old.born)
                            sqlite3_bind_int64(stmt, 7, retired.died)
                            if let stored = retired.stored { self.bindText(stmt, 8, stored) } else { sqlite3_bind_null(stmt, 8) }
                            sqlite3_bind_int64(stmt, 9, Int64(retired.old.lockFlags))
                        }
                    }
                    if let entry {
                        let entryPath = Self.key(entry.path)
                        try run(upsert) { stmt in
                            self.bindText(stmt, 1, entryPath)
                            self.bindText(stmt, 2, Self.parent(of: entryPath))
                            sqlite3_bind_int64(stmt, 3, entry.kind.rawValue)
                            sqlite3_bind_int64(stmt, 4, entry.size)
                            sqlite3_bind_int64(stmt, 5, entry.mtimeNs)
                            sqlite3_bind_int64(stmt, 6, entry.born)
                            sqlite3_bind_int64(stmt, 7, Int64(bitPattern: entry.mirrorIno))
                            sqlite3_bind_int64(stmt, 8, Int64(entry.lockFlags))
                        }
                    } else {
                        try run(deleteEntry) { self.bindPath($0, 1, path) }
                    }
                    try run(deleteIntent) { sqlite3_bind_int64($0, 1, intentID) }
                    changed = true
                }
            }
            if changed { try setMeta("unsealed", "1") }
        }
    }

    // MARK: - Checkpoints

    /// Seal the pending generation as a checkpoint at `time` and open the next generation.
    @discardableResult
    func seal(at time: Date) throws -> HistoryCheckpoint {
        var checkpoint: HistoryCheckpoint?
        try transaction {
            let generation = try pendingGeneration()
            let totals = try currentTotals()
            let sealed = HistoryCheckpoint(seq: generation, time: time, files: totals.files, bytes: totals.bytes)
            let insert = try prepare("INSERT INTO checkpoints (seq, time, files, bytes) VALUES (?, ?, ?, ?);")
            defer { sqlite3_finalize(insert) }
            sqlite3_bind_int64(insert, 1, sealed.seq)
            sqlite3_bind_double(insert, 2, time.timeIntervalSince1970)
            sqlite3_bind_int64(insert, 3, sealed.files)
            sqlite3_bind_int64(insert, 4, sealed.bytes)
            try step(insert)
            try setMeta("pending_generation", String(generation + 1))
            try setMeta("unsealed", "0")
            checkpoint = sealed
        }
        return checkpoint!
    }

    // MARK: - Comparison scopes

    /// Entries directly inside `parent`, by path.
    func entryChildren(of parent: String) throws -> [String: HistoryEntry] {
        try entryMap("SELECT \(Self.entryColumns) FROM entries WHERE parent = ?;", [Self.key(parent)])
    }

    /// Entries strictly below `path` (its whole subtree), by path. A key range on the primary key:
    /// "p/" ≤ path < "p0" ('0' follows '/'), so no LIKE escaping and the index is used.
    func entries(under path: String) throws -> [String: HistoryEntry] {
        let key = Self.key(path)
        return try entryMap("SELECT \(Self.entryColumns) FROM entries WHERE path >= ? AND path < ?;",
                            [key + "/", key + "0"])
    }

    private func entryMap(_ sql: String, _ values: [String]) throws -> [String: HistoryEntry] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (index, value) in values.enumerated() { bindText(stmt, Int32(index + 1), value) }
        var result: [String: HistoryEntry] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let entry = readEntry(stmt, from: 0)
            result[entry.path] = entry
        }
        return result
    }

    // MARK: - Change-discovery state

    /// Directories to compare again next pass (they held files deferred by the quiet window).
    struct CarriedDirectory: Codable, Hashable, Sendable {
        let source: String
        let path: String
    }

    func journalCursor(for source: String) throws -> JournalCursor? {
        try metaText("journal:" + Self.key(source)).flatMap { try? JSONDecoder().decode(JournalCursor.self, from: Data($0.utf8)) }
    }

    func carriedDirectories() throws -> [CarriedDirectory] {
        try metaText("carried_dirs").flatMap { try? JSONDecoder().decode([CarriedDirectory].self, from: Data($0.utf8)) } ?? []
    }

    func lastFullScan() throws -> Date? {
        try metaDouble("last_full_scan").map { Date(timeIntervalSince1970: $0) }
    }

    func settingsFingerprint() throws -> String? {
        try metaText("settings_fingerprint")
    }

    /// Record, in one commit, where the next pass starts: per-source journal cursors (nil = none), the
    /// directories to re-compare, the settings this state was captured with, the end of this pass, the
    /// time of a full scan when this pass was one, and the source identity of every directory whose
    /// subtree this pass compared completely (catalog path → source inode).
    func finishPass(end: Date, cursors: [String: JournalCursor?], carried: [CarriedDirectory],
                    fingerprint: String, fullScanAt: Date?, verifiedDirectories: [String: UInt64] = [:]) throws {
        try transaction {
            if !verifiedDirectories.isEmpty {
                let update = try prepare("UPDATE entries SET source_ino = ? WHERE path = ? AND kind = ?;")
                defer { sqlite3_finalize(update) }
                for (path, ino) in verifiedDirectories {
                    try run(update) { stmt in
                        sqlite3_bind_int64(stmt, 1, Int64(bitPattern: ino))
                        self.bindPath(stmt, 2, path)
                        sqlite3_bind_int64(stmt, 3, HistoryItemKind.directory.rawValue)
                    }
                }
            }
            for (source, cursor) in cursors {
                let key = "journal:" + Self.key(source)
                if let cursor, let json = String(data: try JSONEncoder().encode(cursor), encoding: .utf8) {
                    try setMeta(key, json)
                } else {
                    try deleteMeta(key)
                }
            }
            let carriedJSON = String(data: try JSONEncoder().encode(carried), encoding: .utf8) ?? "[]"
            try setMeta("carried_dirs", carriedJSON)
            try setMeta("settings_fingerprint", fingerprint)
            try setMeta("last_pass_end", String(end.timeIntervalSince1970))
            if let fullScanAt { try setMeta("last_full_scan", String(fullScanAt.timeIntervalSince1970)) }
        }
    }

    // MARK: - Browsing

    /// Children of `parent` ("" = the top) as of checkpoint `seq`, or in current/ when nil. Each child
    /// appears once: a path's versions never overlap each other or its current entry.
    func children(of parent: String, at seq: Int64?) throws -> [HistoryItemRecord] {
        try items(whereClause: "parent = ?", value: Self.key(parent), at: seq)
    }

    /// One path as of checkpoint `seq` (current/ when nil).
    func item(at path: String, seq: Int64?) throws -> HistoryItemRecord? {
        try items(whereClause: "path = ?", value: Self.key(path), at: seq).first
    }

    private func items(whereClause: String, value: String, at seq: Int64?) throws -> [HistoryItemRecord] {
        let entryColumns = "path, kind, size, mtime_ns, NULL, lock_flags"
        let sql: String
        if seq == nil {
            sql = "SELECT \(entryColumns) FROM entries WHERE \(whereClause) ORDER BY path;"
        } else {
            sql = """
                SELECT \(entryColumns) FROM entries WHERE \(whereClause) AND born <= ?
                UNION ALL
                SELECT path, kind, size, mtime_ns, stored, lock_flags FROM versions
                    WHERE \(whereClause) AND born <= ? AND died > ?
                ORDER BY path;
                """
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, value)
        if let seq {
            sqlite3_bind_int64(stmt, 2, seq)
            bindText(stmt, 3, value)
            sqlite3_bind_int64(stmt, 4, seq)
            sqlite3_bind_int64(stmt, 5, seq)
        }
        var rows: [HistoryItemRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(HistoryItemRecord(path: columnText(stmt, 0) ?? "",
                                          kind: HistoryItemKind(rawValue: sqlite3_column_int64(stmt, 1)) ?? .file,
                                          size: sqlite3_column_int64(stmt, 2),
                                          mtimeNs: sqlite3_column_int64(stmt, 3),
                                          stored: columnText(stmt, 4),
                                          lockFlags: UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 5))))
        }
        return rows
    }

    // MARK: - Retention

    /// Files (not folders) in current/ and the sum of their sizes.
    func currentTotals() throws -> (files: Int64, bytes: Int64) {
        let stmt = try prepare("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM entries WHERE kind != ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, HistoryItemKind.directory.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqlError() }
        return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
    }

    /// Total size of the files and symlinks in current/.
    func currentBytes() throws -> Int64 {
        try currentTotals().bytes
    }

    /// Size of the items in current/ still as seeded — clones sharing their blocks with legacy snapshots.
    func seededBytes() throws -> Int64 {
        let stmt = try prepare("SELECT COALESCE(SUM(size), 0) FROM entries WHERE kind != ? AND seeded != 0;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, HistoryItemKind.directory.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqlError() }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Bytes of the kept versions (stored files only).
    func versionBytes() throws -> Int64 {
        let stmt = try prepare("SELECT COALESCE(SUM(size), 0) FROM versions WHERE stored IS NOT NULL;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqlError() }
        return sqlite3_column_int64(stmt, 0)
    }

    // MARK: - Seeding (migration from 1.1.x)

    /// Nothing has ever been recorded: no entries, versions, checkpoints or intents.
    func isPristine() throws -> Bool {
        let stmt = try prepare("""
            SELECT NOT EXISTS (SELECT 1 FROM entries) AND NOT EXISTS (SELECT 1 FROM versions)
               AND NOT EXISTS (SELECT 1 FROM checkpoints) AND NOT EXISTS (SELECT 1 FROM intents);
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqlError() }
        return sqlite3_column_int64(stmt, 0) != 0
    }

    /// Record items already placed in current/ (a seeded mirror) in one commit, born in the pending
    /// generation. Only valid on a pristine catalog. The seeded state is not a pending change: the legacy
    /// snapshot it came from already is its restore point, so no checkpoint is sealed for it.
    func seed(_ entries: [HistoryEntry]) throws {
        try transaction {
            let insert = try prepare("""
                INSERT INTO entries (path, parent, kind, size, mtime_ns, born, mirror_ino, source_ino, lock_flags, seeded)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, 1);
                """)
            defer { sqlite3_finalize(insert) }
            for entry in entries {
                let path = Self.key(entry.path)
                try run(insert) { stmt in
                    self.bindText(stmt, 1, path)
                    self.bindText(stmt, 2, Self.parent(of: path))
                    sqlite3_bind_int64(stmt, 3, entry.kind.rawValue)
                    sqlite3_bind_int64(stmt, 4, entry.size)
                    sqlite3_bind_int64(stmt, 5, entry.mtimeNs)
                    sqlite3_bind_int64(stmt, 6, entry.born)
                    sqlite3_bind_int64(stmt, 7, Int64(bitPattern: entry.mirrorIno))
                    sqlite3_bind_int64(stmt, 8, Int64(entry.lockFlags))
                }
            }
        }
    }

    // MARK: - Lock flags in current/

    /// Copies in current/ were checked for lock flags (see CaptureEngine.unlockMirror).
    func mirrorLocksChecked() throws -> Bool {
        try metaText("mirror_locks_checked") == "1"
    }

    /// Record lock flags found on (and lifted from) copies in current/, keyed by path below current/,
    /// and mark the check done — in one commit.
    func recordMirrorLocks(_ locks: [String: UInt32]) throws {
        try transaction {
            let update = try prepare("UPDATE entries SET lock_flags = lock_flags | ? WHERE path = ?;")
            defer { sqlite3_finalize(update) }
            for (path, flags) in locks {
                try run(update) { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(flags))
                    self.bindPath(stmt, 2, path)
                }
            }
            try setMeta("mirror_locks_checked", "1")
        }
    }

    /// A prune whose file deletions may not have finished (crash) — versions/ needs a sweep.
    func sweepPending() throws -> Bool {
        try (metaInt("sweep_pending") ?? 0) != 0
    }

    func setSweepPending(_ pending: Bool) throws {
        try setMeta("sweep_pending", pending ? "1" : "0")
    }

    /// Delete checkpoint and version rows in one commit; flags the sweep when version files must go.
    func prune(checkpoints: Set<Int64>, versions: Set<Int64>) throws {
        guard !checkpoints.isEmpty || !versions.isEmpty else { return }
        try transaction {
            let deleteCheckpoint = try prepare("DELETE FROM checkpoints WHERE seq = ?;")
            let deleteVersion = try prepare("DELETE FROM versions WHERE id = ?;")
            defer { [deleteCheckpoint, deleteVersion].forEach { sqlite3_finalize($0) } }
            for seq in checkpoints { try run(deleteCheckpoint) { sqlite3_bind_int64($0, 1, seq) } }
            for id in versions { try run(deleteVersion) { sqlite3_bind_int64($0, 1, id) } }
            if !versions.isEmpty { try setMeta("sweep_pending", "1") }
        }
    }

    /// Stored names of every kept version (for the versions/ sweep).
    func storedNames() throws -> Set<String> {
        let stmt = try prepare("SELECT stored FROM versions WHERE stored IS NOT NULL;")
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 0) { names.insert(name) }
        }
        return names
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    // MARK: - Low-level helpers

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func metaText(_ key: String) throws -> String? {
        let stmt = try prepare("SELECT value FROM meta WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        return sqlite3_step(stmt) == SQLITE_ROW ? columnText(stmt, 0) : nil
    }

    private func deleteMeta(_ key: String) throws {
        let stmt = try prepare("DELETE FROM meta WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        try step(stmt)
    }

    private func metaInt(_ key: String) throws -> Int64? { try metaText(key).flatMap { Int64($0) } }
    private func metaDouble(_ key: String) throws -> Double? { try metaText(key).flatMap { Double($0) } }

    private func setMeta(_ key: String, _ value: String) throws {
        let stmt = try prepare("""
            INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        try step(stmt)
    }

    /// Reads `entryColumns` starting at `column`.
    private func readEntry(_ stmt: OpaquePointer?, from column: Int32) -> HistoryEntry {
        HistoryEntry(path: columnText(stmt, column) ?? "",
                     kind: HistoryItemKind(rawValue: sqlite3_column_int64(stmt, column + 1)) ?? .file,
                     size: sqlite3_column_int64(stmt, column + 2),
                     mtimeNs: sqlite3_column_int64(stmt, column + 3),
                     born: sqlite3_column_int64(stmt, column + 4),
                     mirrorIno: UInt64(bitPattern: sqlite3_column_int64(stmt, column + 5)),
                     sourceIno: UInt64(bitPattern: sqlite3_column_int64(stmt, column + 6)),
                     lockFlags: UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, column + 7)),
                     seeded: sqlite3_column_int64(stmt, column + 8) != 0)
    }

    private func run(_ stmt: OpaquePointer?, bind: (OpaquePointer?) -> Void) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        bind(stmt)
        try step(stmt)
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(message: message, code: sqlite3_errcode(db))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqlError() }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
    }

    private func sqlError() -> StoreError {
        .sql(message: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db))
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    /// Bind a catalog path in its stored form.
    private func bindPath(_ stmt: OpaquePointer?, _ index: Int32, _ path: String) {
        bindText(stmt, index, Self.key(path))
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
