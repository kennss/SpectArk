//
//  @file        BackupRunnerTests.swift
//  @description Tests for BackupRunner orchestration — in particular that orphaned `.inprogress-*`
//               trees of the 1.1.x snapshot engine are discarded by the next pass: nothing resumes them
//               any more, and a partial tree must never be mistaken for a valid snapshot.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//

import XCTest
@testable import SpectaBackup

final class BackupRunnerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testInProgressGarbageCollectedOnNextRun() async throws {
        let source = tmp.appendingPathComponent("src", isDirectory: true)
        let dest = tmp.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let job = BackupJob(name: "t", sources: [source], destination: dest)
        let runner = BackupRunner()

        _ = try await runner.run(job: job) { _ in }   // first pass (history engine)

        // Simulate a crashed pass: an orphaned in-progress tree with no COMPLETE marker.
        let snapshotsDir = BackupRunner.jobRoot(for: job).appendingPathComponent("snapshots", isDirectory: true)
        let orphan = snapshotsDir.appendingPathComponent(".inprogress-99999", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        _ = try? await runner.run(job: job) { _ in }   // GC runs before the pass
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path),
                       "orphaned .inprogress tree should be garbage-collected")
    }
}
