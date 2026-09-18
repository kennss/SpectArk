//
//  @file        HistoryStoreSchemaTests.swift
//  @description The history catalog's schema upgrade: a version-1 catalog (as SpectArk 1.2.0 build 8
//               wrote it) opens as version 2 — lock-flag and seeded columns added, paths stored in Unicode
//               NFC, and of two rows that name one file in different normalizations only the one recorded
//               last (the live one) kept. A name spelled NFD is one catalog row however it is spelled.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
//

import SQLite3
import XCTest
@testable import SpectaBackup

final class HistoryStoreSchemaTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sbk-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    func testAVersion1CatalogIsUpgraded() throws {
        let path = tmp.appendingPathComponent("history.sqlite").path
        let nfd = "src/\u{D55C}\u{AE00}.txt".decomposedStringWithCanonicalMapping
        let nfc = "src/\u{D55C}\u{AE00}.txt".precomposedStringWithCanonicalMapping
        let dirNFD = "src/\u{BB38}\u{C11C}".decomposedStringWithCanonicalMapping
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        exec(db, """
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE entries (path TEXT PRIMARY KEY, parent TEXT NOT NULL, kind INTEGER NOT NULL,
                size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, born INTEGER NOT NULL,
                mirror_ino INTEGER NOT NULL, source_ino INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE versions (id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL, parent TEXT NOT NULL,
                kind INTEGER NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, born INTEGER NOT NULL,
                died INTEGER NOT NULL, stored TEXT);
            CREATE TABLE checkpoints (seq INTEGER PRIMARY KEY, time REAL NOT NULL, files INTEGER NOT NULL,
                bytes INTEGER NOT NULL);
            CREATE TABLE intents (id INTEGER PRIMARY KEY AUTOINCREMENT, op INTEGER NOT NULL, path TEXT NOT NULL,
                old_kind INTEGER, old_size INTEGER, old_mtime INTEGER, old_born INTEGER, old_ino INTEGER,
                new_kind INTEGER NOT NULL, new_size INTEGER NOT NULL, new_mtime INTEGER NOT NULL,
                generation INTEGER NOT NULL);
            INSERT INTO entries VALUES ('src', '', 1, 0, 0, 1, 10, 0);
            INSERT INTO entries VALUES ('\(nfd)', 'src', 0, 3, 5, 1, 11, 0);
            INSERT INTO entries VALUES ('\(nfc)', 'src', 0, 4, 6, 2, 12, 0);
            INSERT INTO entries VALUES ('\(dirNFD)', 'src', 1, 0, 0, 1, 13, 0);
            INSERT INTO entries VALUES ('\(dirNFD)/a.txt', '\(dirNFD)', 0, 1, 1, 1, 14, 0);
            INSERT INTO versions (path, parent, kind, size, mtime_ns, born, died, stored)
                VALUES ('\(nfd)', 'src', 0, 2, 4, 1, 2, '7');
            """)
        sqlite3_close(db)

        let store = try HistoryStore(path: path)
        let entries = try store.allEntries()
        XCTAssertEqual(entries.count, 4, "the ghost of the Korean-named file is gone")
        for key in entries.keys {
            XCTAssertTrue(key.utf8.elementsEqual(HistoryStore.key(key).utf8), "\(key) stored in NFC")
        }
        XCTAssertEqual(try store.entry(at: nfd)?.mirrorIno, 12, "the row recorded last is the live one")
        XCTAssertEqual(try store.entryChildren(of: dirNFD).count, 1, "children follow their folder's new key")
        XCTAssertEqual(try store.versions(of: nfc).map(\.stored), ["7"])
        XCTAssertEqual(try store.entry(at: nfc)?.lockFlags, 0)
        XCTAssertEqual(try store.entry(at: nfc)?.seeded, false)

        var check: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &check), SQLITE_OK)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(stmt, 0), HistoryStore.schemaVersion)
        sqlite3_finalize(stmt)
        sqlite3_close(check)
    }
}
