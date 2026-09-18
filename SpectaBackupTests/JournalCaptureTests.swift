//
//  @file        JournalCaptureTests.swift
//  @description History engine, phase 3 — change discovery from the FSEvents journal. After the first
//               full scan a pass compares only the directories the journal reports (one changed file in a
//               tree of many folders = one listing); new, removed and renamed folders are handled from
//               the journal alone; churn inside excluded folders compares nothing yet advances the cursor;
//               a backed-up folder that becomes excluded (CACHEDIR.TAG, pyvenv.cfg) leaves current/ and
//               returns with it; a settings change, a reset journal and the daily safety scan force a full
//               walk; a file deferred by the quiet window is picked up by the next pass without a new
//               event. Journal paths are never trusted blindly: a folder replaced by a symlink, folders
//               swapped under the same name (inside the source, the source itself, a folder above it), a
//               change of letter case, and a pass interrupted halfway all end with current/ matching a
//               full walk. Also the pure mapping from events to dirty directories.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import CoreServices
import Darwin
import XCTest
@testable import SpectaBackup

final class JournalCaptureTests: XCTestCase {

    private var fixture: HistoryFixture!

    override func setUpWithError() throws { fixture = try HistoryFixture() }
    override func tearDownWithError() throws { fixture?.remove() }

    // MARK: - Passes driven by the journal

    func testOneChangedFileComparesOnlyItsFolder() throws {
        for index in 0..<20 { try fixture.write("d\(index)/f.txt", "v1") }
        XCTAssertTrue(try fixture.pass(at: 0).fullScan, "no cursor yet")

        try fixture.write("d7/f.txt", "v2-")
        let outcome = try fixture.pass(at: 16)
        XCTAssertFalse(outcome.fullScan)
        XCTAssertEqual(outcome.comparedDirectories, 1, "only d7 is listed")
        XCTAssertEqual(outcome.changedCount, 1)
        XCTAssertEqual(fixture.mirror("d7/f.txt"), "v2-")
        XCTAssertEqual(try fixture.files(at: 1)["src/d7/f.txt"], "v1")
        try fixture.assertConsistent()
    }

    func testUnchangedSourceComparesNothing() throws {
        try fixture.write("a.txt", "alpha")
        try fixture.pass(at: 0)
        let outcome = try fixture.pass(at: 30)
        XCTAssertFalse(outcome.fullScan)
        XCTAssertEqual(outcome.comparedDirectories, 0)
        XCTAssertEqual(outcome.changedCount, 0)
    }

    func testNewFolderFromTheJournalIsCopiedWhole() throws {
        try fixture.write("a.txt", "alpha")
        try fixture.pass(at: 0)
        try fixture.write("new/deep/x.txt", "x-ray")
        try fixture.write("new/y.txt", "yankee")
        let outcome = try fixture.pass(at: 16)
        XCTAssertFalse(outcome.fullScan)
        XCTAssertEqual(fixture.mirror("new/deep/x.txt"), "x-ray")
        XCTAssertEqual(fixture.mirror("new/y.txt"), "yankee")
        try fixture.assertConsistent()
    }

    func testRemovedFolderFromTheJournalLeavesCurrentButStaysInHistory() throws {
        try fixture.write("keep.txt", "kept")
        try fixture.write("old/a.txt", "alpha")
        try fixture.write("old/sub/b.txt", "bravo")
        try fixture.pass(at: 0)
        try fixture.delete("old")
        let outcome = try fixture.pass(at: 16)
        XCTAssertFalse(outcome.fullScan)
        XCTAssertNil(fixture.mirror("old/sub/b.txt"))
        XCTAssertEqual(fixture.mirror("keep.txt"), "kept")
        XCTAssertEqual(try fixture.files(at: 1)["src/old/sub/b.txt"], "bravo")
        XCTAssertNil(try fixture.files(at: 2)["src/old/a.txt"])
        try fixture.assertConsistent()
    }

    func testRenamedFolderFromTheJournal() throws {
        try fixture.write("old/a.txt", "alpha")
        try fixture.write("old/sub/b.txt", "bravo")
        try fixture.pass(at: 0)
        try fixture.move("old", to: "renamed")
        let outcome = try fixture.pass(at: 16)
        XCTAssertFalse(outcome.fullScan)
        XCTAssertNil(fixture.mirror("old/a.txt"))
        XCTAssertEqual(fixture.mirror("renamed/a.txt"), "alpha")
        XCTAssertEqual(fixture.mirror("renamed/sub/b.txt"), "bravo")
        XCTAssertEqual(try fixture.files(at: 1), ["src/old/a.txt": "alpha", "src/old/sub/b.txt": "bravo"])
        XCTAssertEqual(try fixture.files(at: 2), ["src/renamed/a.txt": "alpha", "src/renamed/sub/b.txt": "bravo"])
        try fixture.assertConsistent()
    }

    func testChurnInsideExcludedFoldersComparesNothingButAdvancesTheCursor() throws {
        try fixture.write("app.js", "code")
        try fixture.pass(at: 0)
        let before = try XCTUnwrap(try fixture.store().journalCursor(for: "src"))

        try fixture.write("node_modules/pkg/index.js", "dependency")
        let outcome = try fixture.pass(at: 16)
        XCTAssertFalse(outcome.fullScan)
        XCTAssertEqual(outcome.comparedDirectories, 0)
        XCTAssertEqual(outcome.changedCount, 0)
        XCTAssertNil(fixture.mirror("node_modules/pkg/index.js"))
        let after = try XCTUnwrap(try fixture.store().journalCursor(for: "src"))
        XCTAssertGreaterThan(after.eventID, before.eventID, "the irrelevant events are not replayed again")
    }

    func testAFolderThatBecomesExcludedLeavesCurrentAndComesBack() throws {
        try fixture.write("keep.txt", "kept")
        try fixture.write("cache/data.bin", "cached")
        try fixture.pass(at: 0)
        XCTAssertEqual(fixture.mirror("cache/data.bin"), "cached")

        // The tag's own event is hidden by the folder it excludes; the catalog still holds that folder.
        try fixture.write("cache/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n")
        let excluded = try fixture.pass(at: 16)
        XCTAssertFalse(excluded.fullScan)
        XCTAssertNil(fixture.mirror("cache/data.bin"))
        XCTAssertEqual(fixture.mirror("keep.txt"), "kept")
        XCTAssertEqual(try fixture.files(at: 1)["src/cache/data.bin"], "cached")

        try fixture.delete("cache/CACHEDIR.TAG")
        XCTAssertFalse(try fixture.pass(at: 32).fullScan)
        XCTAssertEqual(fixture.mirror("cache/data.bin"), "cached")
        try fixture.assertConsistent()
    }

    func testAVirtualenvMarkerReevaluatesItsSitePackages() throws {
        let module = "venv/lib/python3.11/site-packages/pkg/m.py"
        try fixture.write(module, "code")
        try fixture.write("venv/bin/tool.py", "script")
        try fixture.pass(at: 0)
        XCTAssertEqual(fixture.mirror(module), "code", "no pyvenv.cfg: the user's own folder")

        try fixture.write("venv/pyvenv.cfg", "home = /usr/bin\n")
        XCTAssertFalse(try fixture.pass(at: 16).fullScan)
        XCTAssertNil(fixture.mirror(module), "site-packages of a virtualenv is rebuildable")
        XCTAssertEqual(fixture.mirror("venv/bin/tool.py"), "script")

        try fixture.delete("venv/pyvenv.cfg")
        XCTAssertFalse(try fixture.pass(at: 32).fullScan)
        XCTAssertEqual(fixture.mirror(module), "code")
        try fixture.assertConsistent()
    }

    func testACarriedFolderThatBecomesExcludedLeavesCurrent() throws {
        try fixture.write("cache/data.bin", "v1")
        try fixture.pass(at: 0)
        try fixture.write("cache/data.bin", "v2--")
        XCTAssertEqual(try fixture.pass(at: 1, quietWindow: 60).deferredCount, 1)
        try fixture.write("cache/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n")

        let outcome = try fixture.pass(at: 2)                  // compares the carried folder: excluded now
        XCTAssertEqual(outcome.recoveredIntents, 0)
        XCTAssertNil(fixture.mirror("cache/data.bin"))
        XCTAssertTrue(try fixture.store().carriedDirectories().isEmpty)
        try fixture.assertConsistent()
    }

    // MARK: - Journal paths are validated against the disk

    func testAFolderReplacedBySymlinkIsNeverFollowed() throws {
        try fixture.write("d/b.txt", "alpha")
        try fixture.pass(at: 0)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let userFile = outside.appendingPathComponent("b.txt").path
        try Data("the user's file outside the source".utf8).write(to: URL(fileURLWithPath: userFile))
        let userInode = try FileWalker.identity(of: userFile).ino

        try fixture.delete("d")
        let after = FSEventsGetCurrentEventId()
        try FileManager.default.createSymbolicLink(atPath: fixture.source.appendingPathComponent("d").path,
                                                   withDestinationPath: outside.path)
        fixture.note("d", after: after)
        try fixture.pass(at: 16)
        try fixture.pass(at: 24 * 60 + 20)                     // and the daily full scan

        XCTAssertEqual(try FileWalker.identity(of: userFile).ino, userInode, "never replaced through the link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.layout.current("src/d")),
                       outside.path)
        XCTAssertEqual(try fixture.store().entry(at: "src/d")?.kind, .symlink)
        XCTAssertNil(try fixture.store().entry(at: "src/d/b.txt"))
        XCTAssertEqual(try fixture.files(at: 1)["src/d/b.txt"], "alpha")
        try fixture.assertConsistent()
    }

    func testFoldersSwappedUnderTheSameNameAreComparedWhole() throws {
        try fixture.write("a/sub/x.txt", "A")
        try fixture.write("b/sub/x.txt", "BBBB")
        try fixture.pass(at: 0)
        try fixture.move("a", to: "tmp")
        try fixture.move("b", to: "a")
        XCTAssertFalse(try fixture.pass(at: 16).fullScan)
        XCTAssertEqual(fixture.mirror("a/sub/x.txt"), "BBBB")
        XCTAssertEqual(fixture.mirror("tmp/sub/x.txt"), "A")
        XCTAssertNil(fixture.mirror("b/sub/x.txt"))
        try fixture.assertConsistent()
    }

    func testAReplacedSourceFolderIsScannedFully() throws {
        try fixture.write("sub/x.txt", "A")
        try fixture.pass(at: 0)
        let other = fixture.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("BBBB".utf8).write(to: other.appendingPathComponent("sub/x.txt"))
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("src.old"))
        try FileManager.default.moveItem(at: other, to: fixture.source)

        XCTAssertTrue(try fixture.pass(at: 16).fullScan, "the source path names another folder now")
        XCTAssertEqual(fixture.mirror("sub/x.txt"), "BBBB")
        XCTAssertFalse(try fixture.pass(at: 32).fullScan, "verified again")
    }

    func testAReplacedFolderAboveTheSourceIsScannedFully() throws {
        let fm = FileManager.default
        let parent = fixture.root.appendingPathComponent("P", isDirectory: true)
        let source = parent.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("A".utf8).write(to: source.appendingPathComponent("sub/x.txt"))
        let job = BackupJob(name: "nested", sources: [source], destination: fixture.job.destination)
        let layout = HistoryLayout(jobRoot: BackupRunner.jobRoot(for: job))
        try fm.createDirectory(at: layout.jobRoot, withIntermediateDirectories: true)
        let engine = CaptureEngine(layout: layout)
        _ = try engine.runPass(job: job, quietWindow: 0, forceCheckpoint: false, now: { self.fixture.time(0) })

        let replacement = fixture.root.appendingPathComponent("Q", isDirectory: true)
        try fm.createDirectory(at: replacement.appendingPathComponent("src/sub"), withIntermediateDirectories: true)
        try Data("BBBB".utf8).write(to: replacement.appendingPathComponent("src/sub/x.txt"))
        try fm.moveItem(at: parent, to: fixture.root.appendingPathComponent("P.old"))
        try fm.moveItem(at: replacement, to: parent)   // no event is recorded under the source's path

        let outcome = try engine.runPass(job: job, quietWindow: 0, forceCheckpoint: false, now: { self.fixture.time(16) })
        XCTAssertTrue(outcome.fullScan)
        XCTAssertEqual(try String(contentsOfFile: layout.current("src/sub/x.txt"), encoding: .utf8), "BBBB")
    }

    func testChangingOnlyTheLetterCaseOfAFolderAfterEditsInsideIt() throws {
        try fixture.write("Dir/sub/f.txt", "v1")
        try fixture.write("Dir/g.txt", "g")
        try fixture.pass(at: 0)
        try fixture.write("Dir/sub/f.txt", "v2--")
        try fixture.write("Dir/new.txt", "fresh")
        try fixture.rename("Dir", to: "dir")                   // events still name Dir/… for the edits
        try fixture.pass(at: 16)

        XCTAssertEqual(try fixture.store().allEntries().keys.filter { $0.hasPrefix("src/Dir") }, [])
        XCTAssertEqual(fixture.mirror("dir/sub/f.txt"), "v2--")
        XCTAssertEqual(fixture.mirror("dir/new.txt"), "fresh")
        XCTAssertEqual(try fixture.files(at: 1), ["src/Dir/sub/f.txt": "v1", "src/Dir/g.txt": "g"], "sealed history intact")
        XCTAssertEqual(try fixture.files(at: 2), ["src/dir/sub/f.txt": "v2--", "src/dir/g.txt": "g",
                                                  "src/dir/new.txt": "fresh"])
        try fixture.assertConsistent()
        try fixture.pass(at: 24 * 60 + 20)                     // the daily full scan finds nothing to fix
        XCTAssertEqual(fixture.mirror("dir/sub/f.txt"), "v2--")
        try fixture.assertConsistent()
    }

    func testAPassInterruptedHalfwayIsCompletedByTheRetry() throws {
        try fixture.write("keep.txt", "k")
        try fixture.pass(at: 0)
        let incoming = fixture.root.appendingPathComponent("incoming", isDirectory: true)
        for index in 0..<30 {
            let url = incoming.appendingPathComponent(String(format: "sub1/f%02d.txt", index))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("file \(index)".utf8).write(to: url)
        }
        let after = FSEventsGetCurrentEventId()
        try FileManager.default.moveItem(at: incoming, to: fixture.source.appendingPathComponent("N"))
        fixture.note("N", after: after)
        let crashing = CaptureEngine(layout: fixture.layout) { step, path in
            if step == .copied && path == "src/N/sub1/f10.txt" { throw HistoryFixture.SimulatedCrash() }
        }
        XCTAssertThrowsError(try fixture.pass(at: 16, engine: crashing))

        let retry = try fixture.pass(at: 17)                   // same journal span; N is in the catalog now
        XCTAssertFalse(retry.fullScan)
        XCTAssertEqual((0..<30).filter { fixture.mirror(String(format: "N/sub1/f%02d.txt", $0)) != nil }.count, 30)
        try fixture.assertConsistent()
    }

    func testTheDataVolumeSpellingOfTheSourceIsMapped() throws {
        let canonical = try XCTUnwrap(SourceSpellings.canonical(fixture.source.path))
        let spelled = URL(fileURLWithPath: "/System/Volumes/Data" + canonical, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spelled.path))
        let job = BackupJob(name: "data", sources: [spelled], destination: fixture.job.destination)
        let layout = HistoryLayout(jobRoot: BackupRunner.jobRoot(for: job))
        try FileManager.default.createDirectory(at: layout.jobRoot, withIntermediateDirectories: true)
        let engine = CaptureEngine(layout: layout)
        try fixture.write("a.txt", "v1")
        try fixture.pass(at: 0)                                // settles the write
        _ = try engine.runPass(job: job, quietWindow: 0, forceCheckpoint: false, now: { self.fixture.time(0) })

        try fixture.write("a.txt", "v2-changed")
        try fixture.pass(at: 1)                                // settles the write
        let outcome = try engine.runPass(job: job, quietWindow: 0, forceCheckpoint: false, now: { self.fixture.time(16) })
        XCTAssertFalse(outcome.fullScan, "events arrive as /private/var/…, the job says /System/Volumes/Data/…")
        XCTAssertEqual(try String(contentsOfFile: layout.current("src/a.txt"), encoding: .utf8), "v2-changed")
    }

    // MARK: - When the journal is not enough

    func testSettingsChangeForcesAFullScan() throws {
        try fixture.write("app.js", "code")
        try fixture.write("node_modules/pkg/index.js", "dependency")
        try fixture.pass(at: 0)
        XCTAssertNil(fixture.mirror("node_modules/pkg/index.js"))

        var everything = fixture.job
        everything.skipsBuildArtifacts = false
        let outcome = try fixture.pass(at: 16, job: everything)
        XCTAssertTrue(outcome.fullScan, "no file event announces a newly included folder")
        XCTAssertEqual(fixture.mirror("node_modules/pkg/index.js"), "dependency")
        XCTAssertFalse(try fixture.pass(at: 32, job: everything).fullScan, "then back to the journal")
    }

    func testAResetJournalForcesAFullScan() throws {
        try fixture.write("a.txt", "v1")
        try fixture.pass(at: 0)
        let cursor = try XCTUnwrap(try fixture.store().journalCursor(for: "src"))
        // As if the volume's event database had been replaced: the stored IDs mean nothing any more.
        try fixture.store().finishPass(end: fixture.time(1),
                             cursors: ["src": JournalCursor(eventID: cursor.eventID, volumeUUID: UUID().uuidString)],
                             carried: [], fingerprint: CaptureEngine.fingerprint(of: fixture.job), fullScanAt: nil)
        try fixture.write("a.txt", "v2-")
        let outcome = try fixture.pass(at: 16)
        XCTAssertTrue(outcome.fullScan)
        XCTAssertEqual(fixture.mirror("a.txt"), "v2-")
        XCTAssertEqual(try fixture.store().journalCursor(for: "src")?.volumeUUID, cursor.volumeUUID, "cursor repaired")
    }

    func testSafetyScanRunsOnceADay() throws {
        try fixture.write("a.txt", "v1")
        XCTAssertTrue(try fixture.pass(at: 0).fullScan)
        XCTAssertFalse(try fixture.pass(at: 60).fullScan)
        XCTAssertTrue(try fixture.pass(at: 24 * 60).fullScan, "a day after the last full scan")
        XCTAssertFalse(try fixture.pass(at: 24 * 60 + 1).fullScan)
    }

    // MARK: - Quiet window

    func testADeferredFileIsPickedUpWithoutANewEvent() throws {
        try fixture.write("a.txt", "v1")
        try fixture.pass(at: 0)
        try fixture.write("a.txt", "v2-")
        let deferred = try fixture.pass(at: 1, quietWindow: 60)          // still being written
        XCTAssertEqual(deferred.deferredCount, 1)
        XCTAssertEqual(fixture.mirror("a.txt"), "v1")
        XCTAssertEqual(try fixture.store().carriedDirectories(), [.init(source: "src", path: "")])

        let settled = try fixture.pass(at: 2)                           // no new event for a.txt
        XCTAssertFalse(settled.fullScan)
        XCTAssertEqual(fixture.mirror("a.txt"), "v2-")
        XCTAssertTrue(try fixture.store().carriedDirectories().isEmpty)
        try fixture.assertConsistent()
    }

    // MARK: - Events → dirty directories

    private func event(_ rel: String, _ flags: Int) -> WatchEvent {
        WatchEvent(path: rel.isEmpty ? fixture.source.path : fixture.source.appendingPathComponent(rel).path,
                   flags: FSEventStreamEventFlags(flags))
    }

    func testEventsMapToTheFoldersWhoseListingChanged() {
        let changes = ChangeJournal.directories(from: [
            event("a/file.txt", kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
            event("b/new-dir", kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir),
            event("c", kFSEventStreamEventFlagMustScanSubDirs),
            event("", kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir),
            event("", kFSEventStreamEventFlagHistoryDone)
        ], lastEventID: 42, source: fixture.source)
        XCTAssertEqual(changes, .directories(["a": false, "b": false, "b/new-dir": false, "c": true, "": false],
                                             lastEventID: 42))
    }

    func testCanonicalPathSpellingIsMapped() throws {
        let canonical = try XCTUnwrap(realpath(fixture.source.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        XCTAssertNotEqual(canonical, fixture.source.path, "temp folders live under /var → /private/var")
        let changes = ChangeJournal.directories(from: [
            WatchEvent(path: canonical + "/x/y.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile))
        ], lastEventID: 7, source: fixture.source)
        XCTAssertEqual(changes, .directories(["x": false], lastEventID: 7))
    }

    func testMarkersMarkTheFoldersTheyAffect() {
        let changes = ChangeJournal.directories(from: [], markers: [
            event("p/cache/CACHEDIR.TAG", kFSEventStreamEventFlagItemCreated),               // listing of p
            event("x/DerivedData/proj/Build/Intermediates.noindex", kFSEventStreamEventFlagItemIsDir),
            event("py/venv/pyvenv.cfg", kFSEventStreamEventFlagItemRemoved),                  // venv, whole
            event("CACHEDIR.TAG", kFSEventStreamEventFlagItemCreated)                         // clamps to ""
        ], lastEventID: 3, source: fixture.source)
        XCTAssertEqual(changes, .directories(["p": false, "x/DerivedData/proj": false, "py/venv": true, "": false],
                                             lastEventID: 3))
    }

    func testAnEventOutsideTheSourceDemandsAFullScan() {
        let changes = ChangeJournal.directories(from: [
            WatchEvent(path: "/somewhere/else/f.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile))
        ], lastEventID: 1, source: fixture.source)
        XCTAssertEqual(changes, .fullScan(reason: "event outside the source folder"))
    }

    func testBuiltInRulesArePartOfTheFingerprint() {
        XCTAssertTrue(CaptureEngine.fingerprint(of: fixture.job)
            .contains("rules=\(BackupExclusions.rulesVersion)"), "an app update that changes a rule rescans once")
    }

    func testLostEventsDemandAFullScan() {
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagEventIdsWrapped,
                     kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount] {
            let changes = ChangeJournal.directories(from: [event("a/f.txt", kFSEventStreamEventFlagItemIsFile),
                                                           event("", flag)],
                                                    lastEventID: 1, source: fixture.source)
            guard case .fullScan = changes else { return XCTFail("flag \(flag) must force a full scan") }
        }
    }

    func testForeignVolumeUUIDIsAReset() {
        let changes = ChangeJournal.changes(in: fixture.source,
                                            since: JournalCursor(eventID: 1, volumeUUID: UUID().uuidString),
                                            exclusions: BackupExclusions(job: fixture.job))
        XCTAssertEqual(changes, .fullScan(reason: "journal reset"))
    }
}
