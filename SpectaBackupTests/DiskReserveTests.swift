//
//  @file        DiskReserveTests.swift
//  @description Keeping room on a real (small) backup disk, end to end through BackupRunner: below the
//               reserve, the disk's oldest restore points go first whichever job they belong to; a pass that
//               runs out of room settles, makes room for what it still has to write, and finishes; "Keep all"
//               gives up nothing for space; with nothing left that may go, the pass fails as a full disk and
//               leaves no unsettled intents behind. A disk so full a catalog cannot be opened makes room with
//               its ballast first, and gets it back once the reserve is; one that filled before it had a
//               ballast says so. A batch that would not fit is never begun.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - A 200 MB APFS disk image stands in for the backup disk (hdiutil): its reserve is 5% — 10 MB — or what
//    a test's jobs set. Sizes leave margins of several MB, for what APFS itself takes.
//  - Restore points are made with the capture engine at times within the last few hours, so the Automatic
//    policy keeps them all: only space decides what goes.
//

import CoreServices
import XCTest
@testable import SpectaBackup

final class DiskReserveTests: XCTestCase {

    private var folder: URL!
    private var mount: URL!
    private var first: HistoryFixture!
    private var second: HistoryFixture!
    private let base = Date().addingTimeInterval(-3 * 3600)
    private let megabyte: Int64 = 1 << 20

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-reserve-\(UUID().uuidString)", isDirectory: true)
        mount = folder.appendingPathComponent("disk", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("disk.dmg").path
        try hdiutil(["create", "-size", "200m", "-fs", "APFS", "-volname", "Reserve", "-type", "UDIF", image])
        try hdiutil(["attach", image, "-nobrowse", "-noverify", "-mountpoint", mount.path])
        first = try HistoryFixture()
        second = try HistoryFixture()
    }

    override func tearDownWithError() throws {
        if let mount { try? hdiutil(["detach", mount.path, "-force"]) }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        first?.remove()
        second?.remove()
    }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The fixture's job, backing up to the small disk.
    private func job(_ fixture: HistoryFixture, _ retention: RetentionPolicy = .automatic) -> BackupJob {
        var job = fixture.job
        job.destination = mount
        job.retention = retention
        return job
    }

    private func layout(_ job: BackupJob) -> HistoryLayout {
        HistoryLayout(jobRoot: BackupRunner.jobRoot(for: job))
    }

    /// Write `megabytes` of incompressible data to the fixture's source as `name`.
    private func write(_ fixture: HistoryFixture, _ name: String, megabytes: Int) throws {
        let after = FSEventsGetCurrentEventId()
        var data = Data(count: megabytes << 20)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try data.write(to: fixture.source.appendingPathComponent(name))
        fixture.note(name, after: after)
        fixture.waitForEvents()
    }

    /// A restore point of the job at each of `minutes` (after `base`), `name` rewritten with `megabytes` before
    /// each: every one but the newest keeps its copy in versions/.
    private func history(_ fixture: HistoryFixture, _ job: BackupJob, _ name: String, megabytes: Int,
                         at minutes: [Double]) throws {
        try FileManager.default.createDirectory(at: layout(job).jobRoot, withIntermediateDirectories: true)
        for minute in minutes {
            try write(fixture, name, megabytes: megabytes)
            _ = try CaptureEngine(layout: layout(job)).runPass(job: job, quietWindow: 0, forceCheckpoint: true,
                                                               now: { self.base.addingTimeInterval(minute * 60) })
        }
    }

    /// What the disk has free once everything written has reached it (APFS allocates written data lazily).
    private func free() throws -> Int64 {
        let fd = open(mount.path, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        sync()
        return try Syscalls.volumeInfo(at: mount.path).freeBytes
    }

    /// Fill the disk until about `bytes` are free — or as full as it gets: near full, APFS takes only small
    /// writes (measured: 256 KB still, 1 MB no longer, with 4.7 MB reported free), and one large write fails
    /// well before that (Data.write of 193 MB with 198 MB free).
    private func leave(_ bytes: Int64) throws {
        let filler = mount.appendingPathComponent("filler-\(UUID().uuidString)")
        var remaining = try free() - bytes
        guard remaining > 0 else { return }
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler)
        defer { try? handle.close() }
        for size in [1 << 20, 256 << 10, 64 << 10, 4 << 10] {
            let chunk = Data(count: size)
            while remaining >= Int64(size) {
                do {
                    try handle.write(contentsOf: chunk)
                    remaining -= Int64(size)
                } catch where DiskSpace.isOutOfSpace(error) {
                    break   // this size no longer fits; a smaller one may
                }
            }
        }
        try? handle.synchronize()
    }

    private func checkpoints(_ job: BackupJob) throws -> [Int64] {
        try HistoryStore(path: layout(job).catalogPath).checkpoints().map(\.seq)
    }

    // MARK: -

    /// The disk before it filled up: an earlier pass set its ballast aside.
    private func setBallast(_ jobs: [BackupJob]) async throws {
        _ = await BackupRunner().keepDiskReserve(for: jobs[0], jobs: jobs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: BackupRunner.ballastURL(for: mount).path))
    }

    /// Keep 20 MB free (a ballast of 10 MB): clear of the 5% default's 10 MB, which APFS's own margin blurs.
    private var roomy: RetentionPolicy { RetentionPolicy(mode: .automatic, minimumFreeBytes: 20 * megabyte) }

    func testTheDisksOldestRestorePointsGoFirstWhicheverJobTheyBelongTo() async throws {
        let older = job(first, roomy), newer = job(second, roomy)
        try history(first, older, "a.bin", megabytes: 30, at: [0, 20])
        try history(second, newer, "b.bin", megabytes: 30, at: [10, 30])
        try await setBallast([older, newer])
        try leave(0)   // so full that only the ballast makes room to open a catalog

        _ = try await BackupRunner().run(job: newer, neighbors: [older]) { _ in }
        XCTAssertEqual(try checkpoints(older), [2], "the disk's oldest restore point, though another job's")
        XCTAssertEqual(try checkpoints(newer), [1, 2])
        XCTAssertGreaterThanOrEqual(try free(), 20 * megabyte, "the reserve is back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: BackupRunner.ballastURL(for: mount).path), "and the ballast")
    }

    func testAPassThatRunsOutOfRoomMakesRoomAndFinishes() async throws {
        let older = job(first), newer = job(second)
        try history(first, older, "a.bin", megabytes: 30, at: [0, 20])
        try write(second, "big.bin", megabytes: 40)
        try leave(25 * megabyte)   // above the reserve: nothing goes before the pass, which needs 40 MB

        _ = try await BackupRunner().run(job: newer, neighbors: [older], forceCheckpoint: true) { _ in }
        XCTAssertEqual(try checkpoints(older), [2], "room made for the pass")
        XCTAssertEqual(try checkpoints(newer), [1])
        let copied = try FileManager.default.attributesOfItem(atPath: layout(newer).current("src/big.bin"))[.size] as? Int
        XCTAssertEqual(copied, 40 << 20)
        XCTAssertTrue(try HistoryStore(path: layout(newer).catalogPath).pendingIntents().isEmpty)
    }

    func testKeepAllGivesUpNothingForSpace() async throws {
        let kept = job(first, RetentionPolicy(mode: .keepAll)), thinned = job(second, roomy)
        try history(first, kept, "a.bin", megabytes: 30, at: [0, 20])
        try history(second, thinned, "b.bin", megabytes: 30, at: [10, 30])
        try await setBallast([kept, thinned])
        try leave(0)

        _ = try await BackupRunner().run(job: thinned, neighbors: [kept]) { _ in }
        XCTAssertEqual(try checkpoints(kept), [1, 2], "older, but kept all")
        XCTAssertEqual(try checkpoints(thinned), [2])
    }

    func testABatchThatDoesNotFitIsNotBegun() throws {
        let only = job(first)
        try history(first, only, "a.bin", megabytes: 1, at: [0])
        try write(first, "big.bin", megabytes: 5)
        let engine = CaptureEngine(layout: layout(only))
        XCTAssertThrowsError(try engine.runPass(job: only, quietWindow: 0, forceCheckpoint: true,
                                                room: { 4 * self.megabyte })) { error in
            guard case let CaptureError.outOfSpace(needed) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(needed, 5 * self.megabyte)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout(only).current("src/big.bin")), "nothing written")
        XCTAssertTrue(try HistoryStore(path: layout(only).catalogPath).pendingIntents().isEmpty)
        _ = try engine.runPass(job: only, quietWindow: 0, forceCheckpoint: true, room: { 6 * self.megabyte })
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout(only).current("src/big.bin")))
    }

    func testADiskTooFullToOpenItsCatalogsSaysToFreeALittle() async throws {
        let only = job(first, roomy)
        try history(first, only, "a.bin", megabytes: 30, at: [0, 20])
        try write(first, "new.bin", megabytes: 1)
        try leave(0)   // filled before any ballast was set aside

        do {
            _ = try await BackupRunner().run(job: only) { _ in }
            XCTFail("no room even to make room")
        } catch let error as DiskFullError {
            XCTAssertTrue(error.tooFullToMakeRoom, "not \"nothing left to remove\": it has an old restore point")
        }
    }

    func testWithNothingLeftToRemoveThePassFailsAsAFullDisk() async throws {
        let only = job(first)
        try history(first, only, "a.bin", megabytes: 10, at: [0])
        try write(first, "big.bin", megabytes: 60)
        try leave(30 * megabyte)

        do {
            _ = try await BackupRunner().run(job: only, forceCheckpoint: true) { _ in }
            XCTFail("there is no room, and nothing may go: its only restore point is its newest")
        } catch {
            XCTAssertTrue(error is DiskFullError, "\(error)")
        }
        XCTAssertEqual(try checkpoints(only), [1])
        XCTAssertTrue(try HistoryStore(path: layout(only).catalogPath).pendingIntents().isEmpty, "settled")
    }
}
