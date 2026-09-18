//
//  @file        RestoreEngineTests.swift
//  @description End-to-end restore tests through the BackupRunner: back up with the history engine, list
//               the job's restore points, then restore an earlier version of a file, recover a deleted
//               file from an old checkpoint, restore from the latest (not yet sealed) state, and verify
//               the conflict policies (overwrite / skip / keepBoth) — keep-both never destroys the
//               existing file.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - A pass reads changes from the FSEvents journal, so `write`/`delete` wait until a live stream has
//    seen the change before the next pass (see HistoryFixture) — in the app the watcher starts passes.
//

import CoreServices
import XCTest
@testable import SpectaBackup

final class RestoreEngineTests: XCTestCase {

    private var tmp: URL!
    private var source: URL!
    private var job: BackupJob!
    private var watch: JournalWatch!
    private var canonicalSource = ""
    private let runner = BackupRunner()

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-restore-\(UUID().uuidString)", isDirectory: true)
        source = tmp.appendingPathComponent("src", isDirectory: true)
        let dest = tmp.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        job = BackupJob(name: "t", sources: [source], destination: dest)
        canonicalSource = try XCTUnwrap(SourceSpellings.canonical(source.path))
        watch = JournalWatch(path: canonicalSource)
    }

    override func tearDownWithError() throws {
        watch = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private func write(_ rel: String, _ text: String) throws {
        let after = FSEventsGetCurrentEventId()
        try Data(text.utf8).write(to: source.appendingPathComponent(rel))
        XCTAssertTrue(watch.waitFor([(canonicalSource + "/" + rel, after)]))
    }

    private func delete(_ rel: String) throws {
        let after = FSEventsGetCurrentEventId()
        try FileManager.default.removeItem(at: source.appendingPathComponent(rel))
        XCTAssertTrue(watch.waitFor([(canonicalSource + "/" + rel, after)]))
    }

    /// A requested pass: it always ends with a checkpoint.
    private func backUp() async throws {
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }
    }

    private func points() async throws -> [RestorePoint] {
        try await runner.history(for: job).points
    }

    private func restore(_ rel: String, from point: RestorePoint, to target: URL,
                         conflict: RestoreEngine.ConflictPolicy) async throws -> RestoreEngine.Outcome {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return try await runner.restore(job: job, point: point, sourceName: "src", relPaths: [rel], to: target,
                                        conflict: conflict, progress: { _ in })
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Tests

    func testRestoreEarlierVersionToNewTarget() async throws {
        try write("a.txt", "v1")
        try await backUp()
        try write("a.txt", "v2-longer")
        try await backUp()

        let timeline = try await points()
        XCTAssertEqual(timeline.map(\.source), [.checkpoint(seq: 2), .checkpoint(seq: 1)], "newest first")
        let target = tmp.appendingPathComponent("restore-here", isDirectory: true)
        let outcome = try await restore("a.txt", from: timeline[1], to: target, conflict: .overwrite)
        XCTAssertEqual(outcome.restored, 1)
        XCTAssertEqual(try read(target.appendingPathComponent("a.txt")), "v1")
    }

    func testRestoreDeletedFile() async throws {
        try write("a.txt", "a")
        try write("b.txt", "b")
        try await backUp()
        try delete("b.txt")
        try await backUp()

        let timeline = try await points()
        let target = tmp.appendingPathComponent("recovered", isDirectory: true)
        let missing = try await restore("b.txt", from: timeline[0], to: target, conflict: .overwrite)
        XCTAssertEqual(missing.failed, ["b.txt"], "gone in the newest checkpoint")
        _ = try await restore("b.txt", from: timeline[1], to: target, conflict: .overwrite)
        XCTAssertEqual(try read(target.appendingPathComponent("b.txt")), "b")
    }

    func testTheLatestStateIsARestorePointBeforeItIsSealed() async throws {
        try write("a.txt", "v1")
        try await backUp()
        try write("a.txt", "v2-latest")
        _ = try await runner.run(job: job) { _ in }   // a change-triggered pass: too soon for a checkpoint

        let timeline = try await points()
        XCTAssertEqual(timeline.map(\.source), [.latest, .checkpoint(seq: 1)])
        let target = tmp.appendingPathComponent("latest", isDirectory: true)
        _ = try await restore("a.txt", from: timeline[0], to: target, conflict: .overwrite)
        XCTAssertEqual(try read(target.appendingPathComponent("a.txt")), "v2-latest")
    }

    func testKeepBothNeverDestroysExisting() async throws {
        try write("a.txt", "snapshot-version")
        try await backUp()

        // Target already has a different a.txt — keepBoth must preserve it.
        let target = tmp.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "existing-precious".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let outcome = try await restore("a.txt", from: try await points()[0], to: target, conflict: .keepBoth)
        XCTAssertEqual(outcome.restored, 1)
        XCTAssertEqual(try read(target.appendingPathComponent("a.txt")), "existing-precious")
        XCTAssertEqual(try read(target.appendingPathComponent("a (restored).txt")), "snapshot-version")
    }

    func testSkipLeavesExisting() async throws {
        try write("a.txt", "snap")
        try await backUp()

        let target = tmp.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "keep-me".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let outcome = try await restore("a.txt", from: try await points()[0], to: target, conflict: .skip)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(try read(target.appendingPathComponent("a.txt")), "keep-me")
    }
}
