//
//  @file        CaptureEngineTests.swift
//  @description History engine, phase 1: the mirror follows the source; checkpoint sealing (15-minute
//               spacing, sealing a state left standing, Back Up Now); only versions that a checkpoint
//               contains are kept and every checkpoint reconstructs exactly; deletions, kind changes and
//               newly excluded artifacts; a source file vanishing mid-pass; and crash recovery at every
//               filesystem step of put/add/remove, after which disk and catalog agree.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import Darwin
import XCTest
@testable import SpectaBackup

final class CaptureEngineTests: XCTestCase {

    private var fixture: HistoryFixture!
    private var layout: HistoryLayout { fixture.layout }
    private var source: URL { fixture.source }
    private var job: BackupJob { fixture.job }
    private var t0: Date { fixture.t0 }

    private typealias SimulatedCrash = HistoryFixture.SimulatedCrash

    override func setUpWithError() throws { fixture = try HistoryFixture() }
    override func tearDownWithError() throws { fixture?.remove() }

    // MARK: - Helpers (thin wrappers over HistoryFixture)

    private func write(_ rel: String, _ text: String) throws { try fixture.write(rel, text) }
    private func delete(_ rel: String) throws { try fixture.delete(rel) }

    @discardableResult
    private func pass(at minutes: Double, force: Bool = false,
                      engine: CaptureEngine? = nil, job: BackupJob? = nil) throws -> CaptureOutcome {
        try fixture.pass(at: minutes, force: force, engine: engine, job: job)
    }

    private func store() throws -> HistoryStore { try fixture.store() }
    private func mirror(_ rel: String) -> String? { fixture.mirror(rel) }
    private func files(at seq: Int64) throws -> [String: String] { try fixture.files(at: seq) }

    private func assertConsistent(file: StaticString = #filePath, line: UInt = #line) throws {
        try fixture.assertConsistent(file: file, line: line)
    }

    // MARK: - Mirror and checkpoints

    func testFirstPassMirrorsTheSourceAndSealsCheckpoint1() throws {
        try write("a.txt", "alpha")
        try write("sub/b.txt", "bravo")
        let outcome = try pass(at: 0)

        XCTAssertEqual(outcome.sealed.map(\.seq), [1])
        XCTAssertEqual(outcome.sealed.first?.files, 2)
        XCTAssertEqual(outcome.sealed.first?.bytes, 10)
        XCTAssertEqual(mirror("a.txt"), "alpha")
        XCTAssertEqual(mirror("sub/b.txt"), "bravo")
        XCTAssertEqual(try files(at: 1), ["src/a.txt": "alpha", "src/sub/b.txt": "bravo"])
        try assertConsistent()
    }

    func testUnchangedPassChangesNothing() throws {
        try write("a.txt", "alpha")
        try pass(at: 0)
        let outcome = try pass(at: 30)
        XCTAssertEqual(outcome.changedCount, 0)
        XCTAssertTrue(outcome.sealed.isEmpty, "nothing changed ⇒ no checkpoint")
        try assertConsistent()
    }

    func testOnlyVersionsAnyCheckpointContainsAreKept() throws {
        try write("a.txt", "v1")
        try pass(at: 0)                                   // checkpoint 1: v1
        try write("a.txt", "v2-")
        XCTAssertTrue(try pass(at: 1).sealed.isEmpty)     // within 15 min: not sealed
        XCTAssertEqual(mirror("a.txt"), "v2-", "protection is immediate")
        try write("a.txt", "v3--")
        try pass(at: 2)                                   // v2 was never in a checkpoint ⇒ not kept

        let versions = try store().versions(of: "src/a.txt")
        XCTAssertEqual(versions.map(\.born), [1], "only v1 (checkpoint 1) is history")
        XCTAssertEqual(versions.first?.died, 2)

        let later = try pass(at: 20)                      // no change, but v3 has stood for 18 min
        XCTAssertEqual(later.sealed.map(\.seq), [2])
        XCTAssertEqual(later.sealed.first?.time, t0.addingTimeInterval(2 * 60), "sealed at the end of the pass that produced it")
        XCTAssertEqual(try files(at: 1)["src/a.txt"], "v1")
        XCTAssertEqual(try files(at: 2)["src/a.txt"], "v3--")
        try assertConsistent()
    }

    func testEndOfPassSealsOnceSpacingElapsed() throws {
        try write("a.txt", "v1")
        try pass(at: 0)
        try write("a.txt", "v2-")
        let outcome = try pass(at: 16)
        XCTAssertEqual(outcome.sealed.map(\.seq), [2])
        XCTAssertEqual(outcome.sealed.first?.time, t0.addingTimeInterval(16 * 60))
        XCTAssertEqual(try files(at: 1)["src/a.txt"], "v1")
        XCTAssertEqual(try files(at: 2)["src/a.txt"], "v2-")
    }

    func testAStateLeftStandingIsSealedBeforeTheNextChange() throws {
        try write("a.txt", "v1")
        try pass(at: 0)                                   // 10:00 checkpoint 1
        try write("a.txt", "v2-")
        try pass(at: 5)                                   // 10:05 edit, too soon to seal
        try write("a.txt", "v3--")
        let outcome = try pass(at: 60)                    // 11:00 next edit
        XCTAssertEqual(outcome.sealed.map(\.seq), [2, 3], "10:05 state sealed first, then 11:00")
        XCTAssertEqual(outcome.sealed.first?.time, t0.addingTimeInterval(5 * 60))
        XCTAssertEqual(try files(at: 1)["src/a.txt"], "v1")
        XCTAssertEqual(try files(at: 2)["src/a.txt"], "v2-")
        XCTAssertEqual(try files(at: 3)["src/a.txt"], "v3--")
        try assertConsistent()
    }

    func testBackUpNowSealsRegardlessOfSpacing() throws {
        try write("a.txt", "v1")
        try pass(at: 0)
        try write("a.txt", "v2-")
        XCTAssertEqual(try pass(at: 1, force: true).sealed.map(\.seq), [2])
    }

    // MARK: - Removals, kind changes, exclusions

    func testDeletedFileLeavesCurrentButStaysInHistory() throws {
        try write("a.txt", "alpha")
        try write("b.txt", "bravo")
        try pass(at: 0)
        try delete("b.txt")
        try pass(at: 16)

        XCTAssertNil(mirror("b.txt"))
        XCTAssertEqual(try files(at: 1)["src/b.txt"], "bravo")
        XCTAssertNil(try files(at: 2)["src/b.txt"])
        try assertConsistent()
    }

    func testKindChangesBothWays() throws {
        try write("x", "file first")
        try write("y/inner.txt", "dir first")
        try pass(at: 0)
        try delete("x")
        try write("x/now-a-dir.txt", "dir now")
        try delete("y")
        try write("y", "file now")
        try pass(at: 16)

        XCTAssertEqual(mirror("x/now-a-dir.txt"), "dir now")
        XCTAssertEqual(mirror("y"), "file now")
        XCTAssertEqual(try files(at: 1)["src/x"], "file first")
        XCTAssertEqual(try files(at: 1)["src/y/inner.txt"], "dir first")
        XCTAssertEqual(try files(at: 2)["src/y"], "file now")
        try assertConsistent()
    }

    func testNewlyExcludedArtifactsLeaveCurrentButStayInHistory() throws {
        try write("app.js", "code")
        try write("node_modules/pkg/index.js", "dependency")
        var everything = job
        everything.skipsBuildArtifacts = false
        try pass(at: 0, job: everything)
        XCTAssertEqual(mirror("node_modules/pkg/index.js"), "dependency")

        try pass(at: 16)                                  // the job's default skips artifacts
        XCTAssertNil(mirror("node_modules/pkg/index.js"))
        XCTAssertEqual(mirror("app.js"), "code")
        XCTAssertEqual(try files(at: 1)["src/node_modules/pkg/index.js"], "dependency")
        try assertConsistent()
    }

    func testSourceFileVanishingMidPassIsTreatedAsDeleted() throws {
        try write("a.txt", "v1")
        try pass(at: 0)
        try write("a.txt", "v2-")
        let path = source.appendingPathComponent("a.txt").path
        let engine = CaptureEngine(layout: layout) { step, rel in
            if step == .logged && rel == "src/a.txt" { unlink(path) }   // deleted between plan and copy
        }
        try pass(at: 16, engine: engine)
        XCTAssertNil(mirror("a.txt"))
        XCTAssertEqual(try files(at: 1)["src/a.txt"], "v1")
        try assertConsistent()
    }

    // MARK: - Crash recovery

    /// Start over with an empty source and destination (for tests that loop over crash points).
    private func freshFixture() throws {
        fixture.remove()
        fixture = try HistoryFixture()
    }

    private func crashing(at step: CaptureEngine.Step, on rel: String) -> CaptureEngine {
        CaptureEngine(layout: layout) { s, path in
            if s == step && path == rel { throw SimulatedCrash() }
        }
    }

    func testRecoveryAfterACrashAtEveryStepOfAReplace() throws {
        for step in [CaptureEngine.Step.logged, .copied, .oldRetired, .renamed] {
            try freshFixture()
            try write("a.txt", "v1")
            try pass(at: 0)
            try write("a.txt", "v2-")
            XCTAssertThrowsError(try pass(at: 16, engine: crashing(at: step, on: "src/a.txt")), "\(step)")

            let recovered = try pass(at: 17)
            XCTAssertEqual(recovered.recoveredIntents, 1, "\(step)")
            XCTAssertEqual(mirror("a.txt"), "v2-", "\(step)")
            XCTAssertEqual(try files(at: 1)["src/a.txt"], "v1", "history intact after a crash at \(step)")
            try assertConsistent()
        }
    }

    func testRecoveryAfterACrashAtEveryStepOfAnAdd() throws {
        for step in [CaptureEngine.Step.logged, .copied, .oldRetired, .renamed] {
            try freshFixture()
            try write("a.txt", "v1")
            try pass(at: 0)
            try write("new.txt", "fresh")
            XCTAssertThrowsError(try pass(at: 16, engine: crashing(at: step, on: "src/new.txt")), "\(step)")

            try pass(at: 17)
            XCTAssertEqual(mirror("new.txt"), "fresh", "\(step)")
            try assertConsistent()
        }
    }

    func testRecoveryOfAFinishedRemovalWhoseCatalogUpdateWasLost() throws {
        try write("a.txt", "alpha")
        try write("b.txt", "bravo")
        try pass(at: 0)
        try delete("b.txt")
        try write("c.txt", "charlie")
        // The removal of b (first in the batch) completes on disk; the crash hits before the commit.
        XCTAssertThrowsError(try pass(at: 16, engine: crashing(at: .logged, on: "src/c.txt")))

        let recovered = try pass(at: 17)
        XCTAssertGreaterThanOrEqual(recovered.recoveredIntents, 2)
        XCTAssertNil(mirror("b.txt"))
        XCTAssertEqual(mirror("c.txt"), "charlie")
        XCTAssertEqual(try files(at: 1)["src/b.txt"], "bravo", "the removed file is still in checkpoint 1")
        try assertConsistent()
    }
}
