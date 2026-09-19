//
//  @file        DiskSpaceTests.swift
//  @description Keeping room on a backup disk, the pure part (DiskSpace): the plan takes the oldest restore
//               point across every job's ladder until the target is free, a job's own in order, garbage
//               first; it says when even everything that may go is not enough; the reserve is 5% of the disk
//               unless a job there sets its own (the largest wins); "Keep all" gives up nothing unless it
//               sets one; a destination's disk is the deepest mounted volume holding it; a full disk is told
//               from ENOSPC wherever it is carried, SQLITE_FULL, and the capture's own error.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//

import Darwin
import SQLite3
import XCTest
@testable import SpectaBackup

final class DiskSpaceTests: XCTestCase {

    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60) }

    private func ladder(_ id: UUID, garbage: Int64 = 0, _ steps: [(Double, Int64)]) -> DiskSpace.Ladder {
        DiskSpace.Ladder(jobID: id, garbage: garbage, steps: steps.map { DiskSpace.Step(time: at($0.0), freed: $0.1) })
    }

    // MARK: - Plan

    func testTheOldestRestorePointsOfTheDiskGoFirstWhicheverJobTheyBelongTo() {
        let ladders = [ladder(a, [(0, 10), (30, 10), (60, 10)]), ladder(b, [(10, 10), (20, 10)])]
        let plan = DiskSpace.plan(free: 5, target: 40, ladders: ladders)
        XCTAssertEqual(plan.drops, [a: 2, b: 2], "a@0, b@10, b@20 — 35 is still short, so a@30 too; never a@60 first")
        XCTAssertEqual(plan.freeAfter, 45)
    }

    func testThePlanStopsOnceTheTargetIsFree() {
        let ladders = [ladder(a, [(0, 10), (30, 10), (60, 10)]), ladder(b, [(10, 10), (20, 10)])]
        let plan = DiskSpace.plan(free: 5, target: 34, ladders: ladders)
        XCTAssertEqual(plan.drops, [a: 1, b: 2])
        XCTAssertEqual(plan.freeAfter, 35)
        XCTAssertFalse(plan.short)
        XCTAssertTrue(DiskSpace.plan(free: 50, target: 34, ladders: ladders).drops.isEmpty, "enough already")
    }

    func testGarbageCountsFirst() {
        let plan = DiskSpace.plan(free: 5, target: 30, ladders: [ladder(a, garbage: 30, [(0, 10)]), ladder(b, [(10, 10)])])
        XCTAssertTrue(plan.drops.isEmpty, "collecting it costs no restore point")
        XCTAssertEqual(plan.freeAfter, 35)
    }

    func testAJobsOwnStepsGoInTheirOrder() {
        // Out of order in time (clock changes): a job's second step never goes before its first.
        let plan = DiskSpace.plan(free: 0, target: 15, ladders: [ladder(a, [(50, 10), (5, 10)]), ladder(b, [(20, 10)])])
        XCTAssertEqual(plan.drops, [b: 1, a: 1])
    }

    func testTiesGoByJobSoThePlanIsRepeatable() {
        let plan = DiskSpace.plan(free: 0, target: 10, ladders: [ladder(b, [(0, 10)]), ladder(a, [(0, 10)])])
        XCTAssertEqual(plan.drops, [a: 1])
    }

    func testEvenEverythingMayNotBeEnough() {
        let plan = DiskSpace.plan(free: 5, target: 100, ladders: [ladder(a, [(0, 10)]), ladder(b, [])])
        XCTAssertEqual(plan.drops, [a: 1])
        XCTAssertTrue(plan.short)
        XCTAssertEqual(plan.freeAfter, 15)
    }

    // MARK: - Reserve

    private func job(_ retention: RetentionPolicy) -> BackupJob {
        var job = BackupJob(name: "j", sources: [URL(fileURLWithPath: "/tmp/src")], destination: URL(fileURLWithPath: "/tmp/dst"))
        job.retention = retention
        return job
    }

    func testTheReserveIsFivePercentUnlessAJobSetsItsOwn() {
        let tb: Int64 = 1_000_000_000_000
        XCTAssertEqual(DiskSpace.reserve(capacity: tb, jobs: [job(.automatic), job(RetentionPolicy(mode: .keepCount(3)))]),
                       50_000_000_000)
        XCTAssertEqual(DiskSpace.reserve(capacity: tb, jobs: [job(.automatic),
                                                              job(RetentionPolicy(mode: .automatic, minimumFreeBytes: 20)),
                                                              job(RetentionPolicy(mode: .keepAll, minimumFreeBytes: 70))]),
                       70, "the largest a job there sets")
    }

    func testKeepAllGivesUpNothingUnlessItSetsFreeSpace() {
        XCTAssertTrue(DiskSpace.givesUpSpace(job(.automatic)))
        XCTAssertTrue(DiskSpace.givesUpSpace(job(RetentionPolicy(mode: .keepDays(7)))))
        XCTAssertFalse(DiskSpace.givesUpSpace(job(RetentionPolicy(mode: .keepAll))))
        XCTAssertTrue(DiskSpace.givesUpSpace(job(RetentionPolicy(mode: .keepAll, minimumFreeBytes: 1 << 30))))
    }

    // MARK: - Which disk

    func testADestinationsDiskIsTheDeepestMountedVolumeHoldingIt() {
        let volumes = ["/", "/Volumes/Backup", "/Volumes/Backup 1", "/Volumes/home"].map { URL(fileURLWithPath: $0) }
        func key(_ path: String) -> String { DiskSpace.diskKey(for: URL(fileURLWithPath: path), volumes: volumes) }
        XCTAssertEqual(key("/Volumes/Backup"), "/Volumes/Backup")
        XCTAssertEqual(key("/Volumes/Backup/jobs/a"), "/Volumes/Backup")
        XCTAssertEqual(key("/Volumes/Backup 1/x"), "/Volumes/Backup 1", "not the volume whose name it starts with")
        XCTAssertEqual(key("/Volumes/home/Backup"), "/Volumes/home")
        XCTAssertEqual(key("/Users/me/Backups"), "/")
        XCTAssertEqual(key("/Volumes/gone/Backup"), "/", "an unmounted share's old path is the startup disk's")
        XCTAssertEqual(DiskSpace.diskKey(for: URL(fileURLWithPath: "/x"), volumes: []), "/x")
    }

    // MARK: - Out of space

    func testAFullDiskIsToldWhereverTheErrorCarriesIt() {
        XCTAssertTrue(DiskSpace.isOutOfSpace(InfraError(operation: "write", path: "/x", code: ENOSPC)))
        XCTAssertFalse(DiskSpace.isOutOfSpace(InfraError(operation: "write", path: "/x", code: EIO)))
        XCTAssertTrue(DiskSpace.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertTrue(DiskSpace.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(DiskSpace.isOutOfSpace(wrapped))
        XCTAssertTrue(DiskSpace.isOutOfSpace(HistoryStore.StoreError.sql(message: "database or disk is full", code: SQLITE_FULL)))
        XCTAssertFalse(DiskSpace.isOutOfSpace(HistoryStore.StoreError.sql(message: "busy", code: SQLITE_BUSY)))
        XCTAssertTrue(DiskSpace.isOutOfSpace(HistoryStore.StoreError.sql(message: "disk I/O error", code: SQLITE_IOERR,
                                                                         systemErrno: ENOSPC)), "a full disk as an I/O error")
        XCTAssertFalse(DiskSpace.isOutOfSpace(HistoryStore.StoreError.sql(message: "disk I/O error", code: SQLITE_IOERR,
                                                                          systemErrno: EIO)))
        XCTAssertTrue(DiskSpace.isOutOfSpace(CaptureError.outOfSpace(needed: 1)))
        XCTAssertEqual(BackupErrorMessage.describe(CaptureError.outOfSpace(needed: 1)), "The backup disk is full.")
    }
}
