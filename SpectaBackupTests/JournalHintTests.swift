//
//  @file        JournalHintTests.swift
//  @description Journal hints (BackupCoordinator): a replay starts at a hint only on the same journal, only
//               when it is later than the stored cursor, and only when the stored cursor is at or after the
//               base the hint vouches from (a rolled-back store or another engine's state is not), and a pass given one does start there — so a
//               hint must vouch that nothing the backup would act on happened before it. A replay moves a
//               quiet source's cursor up to its own start; a quiet check moves an idle job's hints up only
//               while nothing the backup would act on happened — this process's own writes (a restore)
//               included.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//

import CoreServices
import XCTest
@testable import SpectaBackup

final class JournalHintTests: XCTestCase {

    private var fixture: HistoryFixture!

    override func setUpWithError() throws { fixture = try HistoryFixture() }
    override func tearDownWithError() throws { fixture?.remove() }

    private func hint(base: UInt64, to cursor: UInt64, _ volume: String = "A") -> JournalHint {
        JournalHint(base: JournalCursor(eventID: base, volumeUUID: volume),
                    cursor: JournalCursor(eventID: cursor, volumeUUID: volume))
    }

    func testAHintCountsOnlyFromItsBaseOnTheSameJournalAndWhenLater() {
        let stored = JournalCursor(eventID: 100, volumeUUID: "A")
        XCTAssertEqual(stored.advanced(to: hint(base: 100, to: 200)).eventID, 200)
        XCTAssertEqual(stored.advanced(to: hint(base: 80, to: 200)).eventID, 200, "a store ahead of the base")
        XCTAssertEqual(stored.advanced(to: hint(base: 150, to: 200)), stored,
                       "a store behind the base (rolled back, a copy, another engine's state): nothing vouched")
        XCTAssertEqual(stored.advanced(to: hint(base: 100, to: 50)), stored, "never back")
        XCTAssertEqual(stored.advanced(to: hint(base: 100, to: 200, "B")), stored, "another journal")
        XCTAssertEqual(stored.advanced(to: nil), stored)
    }

    func testAPassStartsItsReplayAtTheHint() throws {
        try fixture.write("a.txt", "one")
        try fixture.pass(at: 0)
        try fixture.write("b.txt", "two")
        fixture.waitForEvents()
        let hint = try XCTUnwrap(ChangeJournal.cursorNow(for: fixture.source))

        let stored = try XCTUnwrap(try fixture.store().journalCursor(for: "src"))
        _ = try CaptureEngine(layout: fixture.layout).runPass(job: fixture.job, quietWindow: 0, forceCheckpoint: false,
                                                             journalHints: ["src": JournalHint(base: stored, cursor: hint)],
                                                             now: { self.fixture.time(1) })
        XCTAssertNil(fixture.mirror("b.txt"), "a hint vouches that nothing happened before it")
    }

    func testAReplayMovesAQuietSourcesCursorUpToItsStart() throws {
        try fixture.write("a.txt", "one")
        try fixture.pass(at: 0)
        let stored = try XCTUnwrap(try fixture.store().journalCursor(for: "src"))
        try Data("x".utf8).write(to: fixture.root.appendingPathComponent("elsewhere.txt"))   // the volume moves on
        let before = FSEventsGetCurrentEventId()
        guard case let .directories(dirty, lastEventID) = ChangeJournal.changes(in: fixture.source, since: stored,
                                                                               exclusions: .includeEverything)
        else { return XCTFail("replayed") }
        XCTAssertTrue(dirty.isEmpty)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(lastEventID), before, "not stuck at the source's last change")
    }

    func testAQuietCheckMovesHintsOnlyPastAQuietStretch() throws {
        try fixture.write("a.txt", "one")
        try fixture.pass(at: 0)
        let stored = try XCTUnwrap(try fixture.store().journalCursor(for: "src"))

        let quiet = BackupCoordinator.quietCursors(fixture.job, from: ["src": JournalHint(stored: stored)])
        XCTAssertGreaterThan(try XCTUnwrap(quiet["src"]).cursor.eventID, stored.eventID)
        XCTAssertEqual(quiet["src"]?.base, stored, "what it vouches from never moves")

        // Written by this process, as a restore writes: a replay sees it, and the hint stays.
        try fixture.write("restored.txt", "back")
        fixture.waitForEvents()
        let busy = BackupCoordinator.quietCursors(fixture.job, from: quiet)
        XCTAssertEqual(busy["src"], quiet["src"], "a change since: the next pass must replay it")
    }
}
