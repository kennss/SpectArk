//
//  @file        HistoryRetentionTests.swift
//  @description History engine, phase 2 — retention. Planner: Time Machine thinning of checkpoints (same
//               rules as legacy snapshots), the newest checkpoint always kept, versions pruned exactly
//               when no kept checkpoint needs them, space pressure and quota dropping the oldest first,
//               and (phase 4) legacy snapshots and checkpoints thinned as one timeline.
//               Maintenance on a real history: files leave versions/, current/ is untouched, an
//               interrupted prune is swept next time, and nothing runs while a pass has pending intents.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import XCTest
@testable import SpectaBackup

final class HistoryRetentionTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    private func checkpoint(_ seq: Int64, ageHours: Double) -> HistoryCheckpoint {
        HistoryCheckpoint(seq: seq, time: now.addingTimeInterval(-ageHours * hour), files: 0, bytes: 0)
    }

    private func span(_ id: Int64, _ born: Int64, _ died: Int64, size: Int64 = 10) -> HistoryRetention.VersionSpan {
        .init(id: id, born: born, died: died, size: size)
    }

    // MARK: - Planner

    func testAutomaticThinningKeepsRecentDailyAndWeekly() {
        let checkpoints = [
            checkpoint(1, ageHours: 24 * 70),        // ~10 weeks: weekly bucket A
            checkpoint(2, ageHours: 24 * 69.5),      // same week as 1 ⇒ only the newer (2) survives
            checkpoint(3, ageHours: 24 * 5 + 2),     // 5 days: daily bucket
            checkpoint(4, ageHours: 24 * 5 + 1),     // same day ⇒ 3 dropped, 4 kept
            checkpoint(5, ageHours: 3),              // < 24 h: kept
            checkpoint(6, ageHours: 1)               // newest
        ]
        let plan = HistoryRetention.plan(policy: .automatic, checkpoints: checkpoints, versions: [],
                                         currentBytes: 0, freeBytes: .max, now: now)
        XCTAssertEqual(plan.checkpoints, [1, 3])
    }

    func testNewestCheckpointIsNeverDropped() {
        let checkpoints = [checkpoint(1, ageHours: 3), checkpoint(2, ageHours: 2), checkpoint(3, ageHours: 1)]
        let plan = HistoryRetention.plan(policy: RetentionPolicy(mode: .keepCount(1), minimumFreeBytes: .max),
                                         checkpoints: checkpoints, versions: [],
                                         currentBytes: 0, freeBytes: 0, now: now)
        XCTAssertEqual(plan.checkpoints, [1, 2], "even under impossible space pressure")
    }

    func testVersionsArePrunedExactlyWhenNoKeptCheckpointNeedsThem() {
        let checkpoints = [checkpoint(1, ageHours: 3), checkpoint(2, ageHours: 2), checkpoint(3, ageHours: 1)]
        let versions = [span(10, 1, 2),   // only checkpoint 1
                        span(11, 1, 3),   // checkpoints 1–2
                        span(12, 2, 4)]   // checkpoints 2–3
        let plan = HistoryRetention.plan(policy: RetentionPolicy(mode: .keepCount(1)), checkpoints: checkpoints,
                                         versions: versions, currentBytes: 0, freeBytes: .max, now: now)
        XCTAssertEqual(plan.checkpoints, [1, 2])
        XCTAssertEqual(plan.versions, [10, 11], "12 still makes up checkpoint 3")
    }

    func testSpacePressureDropsOldestUntilThereIsRoom() {
        let checkpoints = [checkpoint(1, ageHours: 3), checkpoint(2, ageHours: 2), checkpoint(3, ageHours: 1)]
        let versions = [span(10, 1, 2, size: 30), span(11, 2, 3, size: 30)]
        let policy = RetentionPolicy(mode: .automatic, minimumFreeBytes: 100)

        let tight = HistoryRetention.plan(policy: policy, checkpoints: checkpoints, versions: versions,
                                          currentBytes: 0, freeBytes: 50, now: now)
        XCTAssertEqual(tight.checkpoints, [1, 2], "50 + 30 is still short; 50 + 60 is enough")
        XCTAssertEqual(tight.versions, [10, 11])

        let roomy = HistoryRetention.plan(policy: policy, checkpoints: checkpoints, versions: versions,
                                          currentBytes: 0, freeBytes: 80, now: now)
        XCTAssertEqual(roomy.checkpoints, [1])
        XCTAssertEqual(roomy.versions, [10])
    }

    func testQuotaCountsCurrentPlusNeededVersions() {
        let checkpoints = [checkpoint(1, ageHours: 2), checkpoint(2, ageHours: 1)]
        let versions = [span(10, 1, 2, size: 40)]
        let policy = RetentionPolicy(mode: .automatic, maxTotalBytes: 120)
        let over = HistoryRetention.plan(policy: policy, checkpoints: checkpoints, versions: versions,
                                         currentBytes: 100, freeBytes: .max, now: now)
        XCTAssertEqual(over.checkpoints, [1])
        XCTAssertEqual(over.versions, [10])
        let under = HistoryRetention.plan(policy: policy, checkpoints: checkpoints, versions: versions,
                                          currentBytes: 80, freeBytes: .max, now: now)
        XCTAssertTrue(under.checkpoints.isEmpty && under.versions.isEmpty)
    }

    // MARK: - Legacy snapshots and checkpoints on one timeline

    private func legacy(_ id: Int64, ageHours: Double, bytes: Int64 = 100) -> HistoryRetention.LegacySnapshot {
        .init(id: id, time: now.addingTimeInterval(-ageHours * hour), bytes: bytes)
    }

    func testAKeepCountCoversLegacySnapshotsAndCheckpointsTogether() {
        let plan = HistoryRetention.plan(policy: RetentionPolicy(mode: .keepCount(3)),
                                         checkpoints: [checkpoint(1, ageHours: 2), checkpoint(2, ageHours: 1)],
                                         versions: [], currentBytes: 0,
                                         legacy: [legacy(7, ageHours: 30), legacy(8, ageHours: 20), legacy(9, ageHours: 10)],
                                         freeBytes: .max, now: now)
        XCTAssertEqual(plan.legacySnapshots, [7, 8], "the three newest restore points stay: 9, 1, 2")
        XCTAssertTrue(plan.checkpoints.isEmpty)
    }

    func testSpacePressureDropsLegacySnapshotsFirst() {
        let policy = RetentionPolicy(mode: .automatic, minimumFreeBytes: 250)
        let plan = HistoryRetention.plan(policy: policy,
                                         checkpoints: [checkpoint(1, ageHours: 2), checkpoint(2, ageHours: 1)],
                                         versions: [span(10, 1, 2, size: 1_000)], currentBytes: 0,
                                         legacy: [legacy(7, ageHours: 5), legacy(8, ageHours: 4)],
                                         freeBytes: 100, now: now)
        XCTAssertEqual(plan.legacySnapshots, [7, 8], "100 + 100 is short, + 100 is enough")
        XCTAssertTrue(plan.checkpoints.isEmpty)
        XCTAssertTrue(plan.versions.isEmpty)
    }

    func testTheNewestLegacySnapshotStaysWhileThereIsNoCheckpoint() {
        let plan = HistoryRetention.plan(policy: RetentionPolicy(mode: .keepCount(1), minimumFreeBytes: .max),
                                         checkpoints: [], versions: [], currentBytes: 0,
                                         legacy: [legacy(7, ageHours: 5), legacy(8, ageHours: 4)],
                                         freeBytes: 0, now: now)
        XCTAssertEqual(plan.legacySnapshots, [7])
    }

    // MARK: - Maintenance on a real history

    private var fixture: HistoryFixture!

    override func setUpWithError() throws { fixture = try HistoryFixture() }
    override func tearDownWithError() throws { fixture.remove() }

    /// Checkpoints 1–3 with a.txt = v1, v2, v3 (v1 and v2 kept in versions/).
    private func buildThreeCheckpoints() throws {
        try fixture.write("a.txt", "v1")
        try fixture.pass(at: 0)
        try fixture.write("a.txt", "v2-")
        try fixture.pass(at: 16)
        try fixture.write("a.txt", "v3--")
        try fixture.pass(at: 32)
    }

    func testMaintenancePrunesHistoryAndLeavesCurrentAlone() throws {
        try buildThreeCheckpoints()
        let stored = try fixture.store().versions().compactMap(\.stored)
        XCTAssertEqual(stored.count, 2)

        let result = try HistoryMaintenance(layout: fixture.layout)
            .applyRetention(policy: RetentionPolicy(mode: .keepCount(1)), freeBytes: .max, now: fixture.time(40))
        XCTAssertEqual(result.checkpointsDeleted, 2)
        XCTAssertEqual(result.versionsDeleted, 2)
        XCTAssertEqual(result.bytesFreed, 5)
        XCTAssertEqual(try fixture.store().checkpoints().map(\.seq), [3])
        for name in stored {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.version(name)))
        }
        XCTAssertEqual(fixture.mirror("a.txt"), "v3--")
        XCTAssertFalse(try fixture.store().sweepPending())
    }

    func testAnInterruptedPruneIsSweptOnTheNextRun() throws {
        try buildThreeCheckpoints()
        let store = try fixture.store()
        let versions = try store.versions()
        // Rows deleted and the sweep flagged, but the crash hit before any file was removed.
        try store.prune(checkpoints: [1], versions: [versions[0].id])
        let orphan = fixture.layout.version(try XCTUnwrap(versions[0].stored))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan))

        _ = try HistoryMaintenance(layout: fixture.layout)
            .applyRetention(policy: .automatic, freeBytes: .max, now: fixture.time(40))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan), "swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.version(try XCTUnwrap(versions[1].stored))),
                      "a referenced version is never swept")
    }

    func testMaintenanceWaitsWhileAPassHasPendingIntents() throws {
        try buildThreeCheckpoints()
        try fixture.write("a.txt", "v4---")
        let crashing = CaptureEngine(layout: fixture.layout) { step, _ in
            if step == .oldRetired { throw HistoryFixture.SimulatedCrash() }   // v3 already moved to versions/
        }
        XCTAssertThrowsError(try fixture.pass(at: 50, engine: crashing))

        let result = try HistoryMaintenance(layout: fixture.layout)
            .applyRetention(policy: RetentionPolicy(mode: .keepCount(1)), freeBytes: .max, now: fixture.time(51))
        XCTAssertTrue(result.skippedForPendingIntents)
        try fixture.pass(at: 52)                                   // recovery keeps v3 as a version
        XCTAssertEqual(try fixture.files(at: 3)["src/a.txt"], "v3--")
    }
}
