//
//  @file        RetentionSchedulerTests.swift
//  @description Unit tests for the retention policies and the interval scheduler: keepCount / keepDays /
//               automatic thinning, quota (maxTotalBytes) and minimum-free-space pressure dropping the
//               oldest first, the newest restore point never being dropped (on a timeline of legacy
//               snapshots — the same planner covers checkpoints, see HistoryRetentionTests), and
//               schedule due/next-due math.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//

import XCTest
@testable import SpectaBackup

final class RetentionSchedulerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A legacy snapshot whose own footprint is `blocks` 512-byte blocks.
    private func snap(_ seq: Int64, ageSec: Double, blocks: Int64 = 0) -> HistoryRetention.LegacySnapshot {
        .init(id: seq, time: now.addingTimeInterval(-ageSec), bytes: blocks * 512)
    }

    private func plan(_ policy: RetentionPolicy, _ snaps: [HistoryRetention.LegacySnapshot], free: Int64) -> Set<Int64> {
        HistoryRetention.plan(policy: policy, checkpoints: [], versions: [], currentBytes: 0, legacy: snaps,
                              freeBytes: free, now: now).legacySnapshots
    }

    // MARK: - Policy

    func testKeepCountDropsOldest() {
        let snaps = (1...5).map { snap(Int64($0), ageSec: Double(6 - $0) * 3600) }
        let deleted = plan(RetentionPolicy(mode: .keepCount(2)), snaps, free: .max)
        XCTAssertEqual(deleted, [1, 2, 3])   // keep newest 2 (seq 4,5)
    }

    func testKeepDaysDropsOld() {
        let snaps = [snap(1, ageSec: 10 * 86_400), snap(2, ageSec: 8 * 86_400),
                     snap(3, ageSec: 3 * 86_400), snap(4, ageSec: 1 * 86_400)]
        let deleted = plan(RetentionPolicy(mode: .keepDays(7)), snaps, free: .max)
        XCTAssertEqual(deleted, [1, 2])      // older than 7 days
    }

    func testAutomaticKeepsRecent() {
        let snaps = [snap(1, ageSec: 3 * 3600), snap(2, ageSec: 2 * 3600), snap(3, ageSec: 1 * 3600)]
        let deleted = plan(RetentionPolicy(mode: .automatic), snaps, free: .max)
        XCTAssertTrue(deleted.isEmpty)       // all within 24h → all kept
    }

    // MARK: - Space pressure

    func testQuotaDropsOldestUntilUnderLimit() {
        // 5 snapshots, ~512 KB each; quota 1.1 MB → keep newest 2.
        let snaps = (1...5).map { snap(Int64($0), ageSec: Double(6 - $0) * 3600, blocks: 1000) }
        let deleted = plan(RetentionPolicy(mode: .keepAll, maxTotalBytes: 1_100_000), snaps, free: .max)
        XCTAssertEqual(deleted, [1, 2, 3])
    }

    func testMinimumFreeSpaceDropsOldest() {
        // 5 snapshots ~5 MB each; free 1 MB, want >= 11 MB free → drop 2 oldest.
        let snaps = (1...5).map { snap(Int64($0), ageSec: Double(6 - $0) * 3600, blocks: 10_000) }
        let deleted = plan(RetentionPolicy(mode: .keepAll, minimumFreeBytes: 11_000_000), snaps, free: 1_000_000)
        XCTAssertEqual(deleted, [1, 2])
    }

    func testNewestNeverDropped() {
        let snaps = (1...4).map { snap(Int64($0), ageSec: Double(5 - $0) * 3600, blocks: 10) }
        let deleted = plan(RetentionPolicy(mode: .keepAll, maxTotalBytes: 1), snaps, free: .max)
        XCTAssertEqual(deleted.count, 3)
        XCTAssertFalse(deleted.contains(4))  // newest survives even under an impossible quota
    }

    func testSingleSnapshotNeverDeleted() {
        let deleted = plan(RetentionPolicy(mode: .keepAll, maxTotalBytes: 1), [snap(1, ageSec: 0, blocks: 999)], free: 1)
        XCTAssertTrue(deleted.isEmpty)
    }

    // MARK: - Scheduler

    func testScheduleDue() {
        let spec = IntervalSpec(unit: .hours, count: 6)
        XCTAssertTrue(Scheduler.isDue(spec: spec, lastBackup: nil, now: now))                          // never run
        XCTAssertTrue(Scheduler.isDue(spec: spec, lastBackup: now.addingTimeInterval(-7 * 3600), now: now))
        XCTAssertFalse(Scheduler.isDue(spec: spec, lastBackup: now.addingTimeInterval(-3 * 3600), now: now))
    }

    func testScheduleNextDue() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Scheduler.nextDue(spec: IntervalSpec(unit: .days, count: 1), lastBackup: last),
                       last.addingTimeInterval(86_400))
        XCTAssertNil(Scheduler.nextDue(spec: IntervalSpec(unit: .days, count: 1), lastBackup: nil))
    }
}
