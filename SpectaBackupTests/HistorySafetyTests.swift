//
//  @file        HistorySafetyTests.swift
//  @description Data-safety cases found by reviewing the engine against real data: a locked copy in
//               current/ (Finder, or seeded by an earlier build) never stops a job, and an old catalog's
//               locked copies are unlocked once with their flags kept; removing a dropped tree never
//               touches an inode a kept tree shares, nor any flag but the lock (a compressed file whose
//               UF_COMPRESSED is cleared reads as empty); a failed overwrite restore leaves the original
//               untouched; the schema upgrade keeps the live row of a ghost pair; the reaper reports what it
//               is about to free; this process's leftover NAS lock does not block its next attach; the
//               05:00 day boundary follows the wall clock across daylight saving; a migration never
//               discards history it could not read; a published tree whose row failed is adopted; a
//               migration request is not left behind; and a copy whose source changed while it was copied
//               is never recorded, while a file that never stops changing is still backed up; and what a
//               pass that never finished left in current/ is never sealed as an earlier state.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//

import Darwin
import SQLite3
import XCTest
@testable import SpectaBackup

final class HistorySafetyTests: XCTestCase {

    private var fixture: HistoryFixture!

    override func setUpWithError() throws { fixture = try HistoryFixture() }
    override func tearDownWithError() throws { fixture?.remove() }

    private let immutable = UInt32(UF_IMMUTABLE)

    private func size(_ path: String) -> Int {
        (try? Data(contentsOf: URL(fileURLWithPath: path)).count) ?? -1
    }

    /// A file stored with HFS compression (UF_COMPRESSED): clearing that flag would empty it.
    private func compressedFile(at path: String, text: String) throws {
        let staging = fixture.root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(String(repeating: text, count: 4000).utf8).write(to: staging.appendingPathComponent("f"))
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--hfsCompression", staging.appendingPathComponent("f").path, path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertNotEqual(try Syscalls.flags(of: path) & UInt32(UF_COMPRESSED), 0, "fixture: compressed")
    }

    // MARK: - Locked copies in current/

    func testALockedCopyInCurrentNeverStopsTheJob() throws {
        try fixture.write("doc.txt", "v1")
        try fixture.pass(at: 0)
        let mirror = fixture.layout.current("src/doc.txt")
        XCTAssertEqual(lchflags(mirror, immutable), 0)            // locked in Finder, say
        try fixture.write("doc.txt", "v2-")
        try fixture.pass(at: 16)                                  // retires the locked v1
        XCTAssertEqual(fixture.mirror("doc.txt"), "v2-")
        XCTAssertEqual(try fixture.store().versions(of: "src/doc.txt").first?.lockFlags, immutable,
                       "the lock stays with the version")
        try fixture.delete("doc.txt")
        try fixture.pass(at: 32)
        try fixture.assertConsistent()
    }

    func testAnOldCatalogsLockedCopiesAreUnlockedOnceAndTheirFlagsKept() throws {
        try fixture.write("doc.txt", "seeded locked")
        try fixture.pass(at: 0)
        let mirror = fixture.layout.current("src/doc.txt")
        XCTAssertEqual(lchflags(mirror, immutable), 0)
        // As a catalog from before lock flags were handled: the check has never run.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.layout.catalogPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM meta WHERE key = 'mirror_locks_checked';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        try fixture.pass(at: 16)
        XCTAssertEqual(try Syscalls.flags(of: mirror) & Syscalls.lockFlags, 0)
        XCTAssertEqual(try fixture.store().entry(at: "src/doc.txt")?.lockFlags, immutable)
        XCTAssertTrue(try fixture.store().mirrorLocksChecked())
    }

    // MARK: - Flags are never cleared beyond the lock

    func testRemovingADroppedTreeNeverTouchesAKeptTreesInode() throws {
        let kept = fixture.root.appendingPathComponent("snapshots/20260101-000000-2/src", isDirectory: true)
        let doomed = fixture.root.appendingPathComponent("snapshots/.deleting-20260101-000000-1/src", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: doomed.appendingPathComponent("m"), withIntermediateDirectories: true)
        let shared = kept.appendingPathComponent("app.bin").path
        try compressedFile(at: shared, text: "shared data block ")
        XCTAssertEqual(link(shared, doomed.appendingPathComponent("m/shared").path), 0)   // HFS+ hard-link trees
        let lockedShared = kept.appendingPathComponent("locked.bin").path
        try Data("kept lock".utf8).write(to: URL(fileURLWithPath: lockedShared))
        XCTAssertEqual(link(lockedShared, doomed.appendingPathComponent("m/locked-link").path), 0)
        XCTAssertEqual(lchflags(lockedShared, immutable), 0)
        let before = size(shared)

        try TreeRemoval.remove(doomed.deletingLastPathComponent().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.deletingLastPathComponent().path))
        XCTAssertEqual(size(shared), before, "UF_COMPRESSED untouched")
        XCTAssertEqual(try Syscalls.flags(of: lockedShared) & Syscalls.lockFlags, immutable, "the kept name stays locked")
        XCTAssertEqual(lchflags(lockedShared, 0), 0)
    }

    func testAFailedOverwriteRestoreLeavesTheOriginalUntouched() throws {
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let original = target.appendingPathComponent("doc.txt")
        try compressedFile(at: original.path, text: "precious ")
        XCTAssertEqual(lchflags(original.path, try Syscalls.flags(of: original.path) | immutable), 0)
        let before = size(original.path)
        var outcome = RestoreEngine.Outcome()
        RestoreEngine().restoreFile(src: fixture.root.appendingPathComponent("missing-version"), dst: original,
                                    conflict: .overwrite, outcome: &outcome)
        XCTAssertEqual(outcome.failed, ["doc.txt"])
        XCTAssertEqual(size(original.path), before)
        XCTAssertNotEqual(try Syscalls.flags(of: original.path) & immutable, 0, "still locked")
        XCTAssertEqual(lchflags(original.path, 0), 0)
    }

    func testAnOverwriteRestoreReplacesALockedFileAndKeepsItsOtherNameLocked() throws {
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let existing = target.appendingPathComponent("doc.txt").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: existing))
        let otherName = target.appendingPathComponent("doc-link.txt").path
        XCTAssertEqual(link(existing, otherName), 0)
        XCTAssertEqual(lchflags(existing, immutable), 0)
        let source = fixture.root.appendingPathComponent("version.txt")
        try Data("restored".utf8).write(to: source)

        var outcome = RestoreEngine.Outcome()
        RestoreEngine().restoreFile(src: source, dst: URL(fileURLWithPath: existing), conflict: .overwrite,
                                    outcome: &outcome, lockFlags: 0)
        XCTAssertEqual(outcome.restored, 1)
        XCTAssertEqual(try String(contentsOfFile: existing, encoding: .utf8), "restored")
        XCTAssertEqual(try String(contentsOfFile: otherName, encoding: .utf8), "old")
        XCTAssertEqual(try Syscalls.flags(of: otherName) & immutable, immutable, "the other name keeps its lock")
        XCTAssertEqual(lchflags(otherName, 0), 0)
    }

    // MARK: - Schema upgrade

    func testTheGhostPairKeepsTheLiveRowEvenWhenItsRowidIsSmaller() throws {
        let path = fixture.root.appendingPathComponent("ghost.sqlite").path
        let nfd = "src/é.txt".decomposedStringWithCanonicalMapping
        let nfc = "src/é.txt".precomposedStringWithCanonicalMapping
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let sql = """
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
            INSERT INTO entries VALUES ('\(nfd)', 'src', 0, 3, 3, 1, 11, 0);
            INSERT INTO entries VALUES ('\(nfc)', 'src', 0, 4, 4, 2, 12, 0);
            INSERT INTO entries (path, parent, kind, size, mtime_ns, born, mirror_ino) VALUES ('\(nfd)', 'src', 0, 5, 5, 3, 13)
                ON CONFLICT(path) DO UPDATE SET size = excluded.size, mtime_ns = excluded.mtime_ns,
                born = excluded.born, mirror_ino = excluded.mirror_ino;
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        sqlite3_close(db)
        let kept = try XCTUnwrap(try HistoryStore(path: path).entry(at: nfc))
        XCTAssertEqual(kept.born, 3, "an upsert keeps the rowid: the live row can be the older one")
    }

    // MARK: - Torn copies

    /// An engine that changes `rel` in the source each time it has just copied it — a writer mid-copy.
    private func engineWriting(_ rel: String, _ text: @escaping @Sendable () -> String) -> CaptureEngine {
        let url = fixture.source.appendingPathComponent(rel)
        return CaptureEngine(layout: fixture.layout) { step, path in
            guard step == .copying, path == "src/" + rel else { return }
            try Data(text().utf8).write(to: url)
        }
    }

    /// `rel` last modified long ago: out of any quiet window.
    private func age(_ rel: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: fixture.source.appendingPathComponent(rel).path)
    }

    func testACopyWhoseSourceChangedWhileItWasCopiedIsNeverRecorded() throws {
        try fixture.write("a.txt", "one")
        try age("a.txt")
        try fixture.pass(at: 0, quietWindow: 3)
        try fixture.write("a.txt", "two---")
        try age("a.txt")
        let changes = FSEventsGetCurrentEventId()
        let outcome = try fixture.pass(at: 1, engine: engineWriting("a.txt") { "three!!!" }, quietWindow: 3)
        XCTAssertEqual(outcome.deferredCount, 1, "deferred like a file in its quiet window")
        XCTAssertEqual(fixture.mirror("a.txt"), "one", "the old copy stays")
        XCTAssertEqual(try fixture.store().entry(at: "src/a.txt")?.size, 3)

        fixture.note("a.txt", after: changes)
        try fixture.pass(at: 1.1)   // the settle pass
        XCTAssertEqual(fixture.mirror("a.txt"), "three!!!")
        XCTAssertEqual(try fixture.store().entry(at: "src/a.txt")?.size, 8, "what was copied is what is recorded")
        try fixture.assertConsistent()
    }

    func testAFileThatNeverStopsChangingIsStillBackedUpAndCopiedAgainOnceItStops() throws {
        try fixture.write("log.txt", "0")
        let writes = WriteCounter()
        let changes = FSEventsGetCurrentEventId()
        let outcome = try fixture.pass(at: 0, engine: engineWriting("log.txt") { "\(writes.next())-changed" })
        XCTAssertEqual(outcome.deferredCount, 0, "a settle pass keeps its last copy")
        XCTAssertEqual(fixture.mirror("log.txt"), "2-changed", "as of just before that copy")

        fixture.note("log.txt", after: changes)
        try fixture.pass(at: 1)   // it stopped changing: seen as changed, copied again
        XCTAssertEqual(fixture.mirror("log.txt"), "3-changed")
        try fixture.assertConsistent()
    }

    // MARK: - Reaper, NAS lock, day boundary

    func testAPassThatNeverFinishedLeavesNoRestorePointOfWhatItLeft() throws {
        try fixture.write("a.txt", "one")
        try fixture.pass(at: 0)                         // sealed: the first state
        try fixture.write("a.txt", "two")
        try fixture.pass(at: 5)                         // within the spacing: left unsealed, ended at minute 5
        // The next pass began changing current/ and died between batches — no intent left to recover.
        try fixture.store().beginPass()

        let outcome = try fixture.pass(at: 20)
        XCTAssertEqual(outcome.sealed.map(\.time), [fixture.time(20)],
                       "sealed at the end of a pass that finished, never as of minute 5")
    }

    func testTheReaperReportsWhatItIsAboutToFree() {
        let queue = DispatchQueue(label: "test.reaper")
        queue.suspend()
        let reaper = TreeReaper(queue: queue)
        let root = fixture.root.appendingPathComponent("snapshots").path
        reaper.reap(URL(fileURLWithPath: root + "/.deleting-a"), bytes: 700)
        reaper.reap(URL(fileURLWithPath: root + "/.deleting-a"), bytes: 700)   // queued once
        XCTAssertEqual(reaper.pendingBytes(under: root), 700)
        XCTAssertEqual(reaper.pendingBytes(under: "/elsewhere"), 0)
        queue.resume()
        reaper.drain()
        XCTAssertEqual(reaper.pendingBytes(under: root), 0)
    }

    func testThisProcessesLeftoverLockDoesNotBlockItsNextAttach() throws {
        let destination = fixture.root.appendingPathComponent("nas", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent(SparsebundleManager.imageName),
                                                withIntermediateDirectories: true)
        let owner = try XCTUnwrap(SparsebundleManager.currentLockOwner())
        try JSONEncoder().encode(owner).write(to: destination.appendingPathComponent(SparsebundleManager.lockName))
        do {
            let attachment = try SparsebundleManager.attach(at: destination, readOnly: false)
            SparsebundleManager.detach(attachment)
        } catch SparsebundleManager.SBError.locked {
            XCTFail("a lock none of this process's attachments holds is not live")
        } catch {
            // hdiutil refuses the stand-in image; getting that far is the point.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SparsebundleManager.lockName).path),
                       "a failed attach releases the lock it took")
    }

    func testTheDayBoundaryFollowsTheWallClockAcrossDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        // 2026-03-08 is the US daylight-saving start: 23:00 on the 7th and 05:30 on the 8th are two days.
        let springItems = [HistoryRetention.Dated(id: 1, time: local(3, 7, 23, 0)),
                           HistoryRetention.Dated(id: 2, time: local(3, 8, 5, 30))]
        XCTAssertTrue(HistoryRetention.thinned(by: .automatic, items: springItems, now: local(3, 18, 12, 0),
                                               calendar: calendar).isEmpty)
        // 2026-11-01 is its end: 04:30 still belongs to October 31, 05:10 to November 1.
        let fallItems = [HistoryRetention.Dated(id: 1, time: local(11, 1, 4, 30)),
                         HistoryRetention.Dated(id: 2, time: local(11, 1, 5, 10))]
        XCTAssertTrue(HistoryRetention.thinned(by: .automatic, items: fallItems, now: local(11, 12, 12, 0),
                                               calendar: calendar).isEmpty)
    }

    // MARK: - Migration and adoption

    func testAMigrationNeverDiscardsHistoryItCouldNotRead() async throws {
        let job = fixture.job
        try fixture.write("a.txt", "alpha")
        try fixture.pass(at: 0)
        try fixture.write("a.txt", "beta!")
        try fixture.pass(at: 16)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.layout.catalogPath))
        try handle.write(contentsOf: Data(repeating: 0x41, count: 100))   // a damaged header
        try handle.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: fixture.layout.catalogPath + suffix) }

        let repo = BackupRunner.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true)
        _ = try await RepoManager.create(backend: try LocalBackend(root: repo), password: Data("pw".utf8))
        let runner = BackupRunner()
        do {
            try await runner.migrateToEncrypted(job: job, password: "pw") { _, _ in }
            XCTFail("an unreadable history must stop the migration")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.currentRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.versionsRoot))
        let count = await runner.plaintextSnapshotCount(for: job)
        XCTAssertGreaterThan(count, 0, "still reported as plaintext to migrate")
    }

    func testAPublishedTreeWhoseRowFailedIsAdoptedOnce() async throws {
        let job = fixture.job
        try fixture.write("a.txt", "alpha")
        let jobRoot = BackupRunner.jobRoot(for: job)
        let catalog = try CatalogStore(path: jobRoot.appendingPathComponent("catalog.sqlite").path)
        let seq = try await catalog.beginSnapshot(jobID: job.id, timestamp: Date(), sourceSnapshotID: nil)
        try await catalog.markFailed(seqId: seq)   // the tree was renamed into place, recording it failed
        let tree = jobRoot.appendingPathComponent("snapshots/20260101-000000-\(seq)", isDirectory: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tree.appendingPathComponent("src/x.txt"))
        try Data().write(to: tree.appendingPathComponent(SnapshotBrowser.completeMarker))

        _ = try await BackupRunner().run(job: job) { _ in }
        let row = try await catalog.snapshots(jobID: job.id).first { $0.seqId == seq }
        XCTAssertEqual(row?.status, .complete)
        XCTAssertEqual(row?.dirName, tree.lastPathComponent)
        XCTAssertEqual(row?.fileCount, 1)
    }

    func testAMigrationRequestIsNotLeftBehind() {
        var s = PassScheduler()
        s.workStarted(.migration)
        XCTAssertEqual(s.migrationRequested(), .none)
        _ = s.migrationFinished(now: Date())
        s.workStarted(.pass(quietWindow: 0, requested: true))
        XCTAssertNotEqual(s.passFinished(now: Date(), duration: 1, deferredCount: 0, succeeded: true), .startMigration)
    }
}

/// Numbers the writes a test makes from the engine's thread.
private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
