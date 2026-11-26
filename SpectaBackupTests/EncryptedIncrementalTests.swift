//
//  @file        EncryptedIncrementalTests.swift
//  @description Encrypted passes as incremental as the history engine's: unchanged files are not read again
//               (their nodes are taken from the parent snapshot); a pass that finds nothing changed writes no
//               snapshot yet counts as a backup; a file in its quiet window keeps its previous version until a
//               settle pass takes it; a requested restore point is written even when nothing changed; the
//               15-minute cadence keeps the first snapshot once spacing has elapsed, each state left alone and
//               the newest, never a requested or migrated one, and every state a later pass removed something
//               from (a pass records it when it removes, not when it edits); a scope lists exactly the folders FSEvents
//               reported, those on the way, and everything under a recursive report; the timeline shows
//               what the repo occupies.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-11-26
//

import Darwin
import XCTest
@testable import SpectaBackup

final class EncryptedIncrementalTests: XCTestCase {

    private var fixture: HistoryFixture!
    private var job: BackupJob!

    private var repoRoot: URL { BackupRunner.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true) }

    override func setUp() async throws {
        fixture = try HistoryFixture()
        job = fixture.job
        job.encryptionEnabled = true
        try fixture.write("a.txt", "alpha")
        try fixture.write("sub/keep.txt", "kept as it was")
        _ = try await RepoManager.create(backend: try LocalBackend(root: repoRoot), password: Data("pw".utf8))
    }

    override func tearDownWithError() throws {
        chmod(fixture.source.appendingPathComponent("sub/keep.txt").path, 0o644)
        fixture?.remove()
    }

    private func runner() -> BackupRunner {
        BackupRunner(passwords: { _ in "pw" },
                     timeline: RepoTimeline(directory: fixture.root.appendingPathComponent("cache", isDirectory: true)))
    }

    private func snapshotIDs(_ runner: BackupRunner) async throws -> [String] {
        try await runner.history(for: job).points.compactMap { point in
            if case let .encryptedSnapshot(id) = point.source { return id }
            return nil
        }
    }

    private func restored(_ runner: BackupRunner, _ id: String) async throws -> [String: String] {
        let target = fixture.root.appendingPathComponent("restored-\(UUID().uuidString)", isDirectory: true)
        try await runner.restoreEncrypted(job: job, snapshotID: id, to: target)
        var files: [String: String] = [:]
        try FileWalker.walk(root: target.appendingPathComponent("src"), exclusions: .includeEverything) { item in
            guard !item.isDirectory else { return }
            files[item.relativePath] = try String(contentsOf: item.url, encoding: .utf8)
        }
        return files
    }

    // MARK: - Through the runner

    func testAnUnchangedFileIsNotReadAgain() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        // Unreadable from now on: a pass that read it would fail.
        let keep = fixture.source.appendingPathComponent("sub/keep.txt").path
        let changes = FSEventsGetCurrentEventId()
        chmod(keep, 0)
        fixture.note("sub/keep.txt", after: changes)
        try fixture.write("a.txt", "beta!")
        fixture.waitForEvents()

        _ = try await runner.run(job: job) { _ in }
        let ids = try await snapshotIDs(runner)
        XCTAssertEqual(ids.count, 2)
        chmod(keep, 0o644)
        let newest = try await restored(runner, try XCTUnwrap(ids.first))
        XCTAssertEqual(newest, ["a.txt": "beta!", "sub/keep.txt": "kept as it was"])
    }

    func testAPassThatFindsNothingChangedWritesNoSnapshotButCountsAsABackup() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        let second = try await runner.run(job: job) { _ in }
        let history = try await runner.history(for: job)
        XCTAssertEqual(history.points.count, 1, "no second restore point of the same state")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(history.lastBackup), second.finishedAt.addingTimeInterval(-1))
    }

    func testAFileInItsQuietWindowKeepsItsPreviousVersionUntilItSettles() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        try fixture.write("a.txt", "beta!")
        fixture.waitForEvents()

        let waiting = try await runner.run(job: job, quietWindow: 60) { _ in }
        XCTAssertEqual(waiting.deferredCount, 1)
        let before = try await snapshotIDs(runner)
        XCTAssertEqual(before.count, 1, "the previous version stands; nothing else changed")

        _ = try await runner.run(job: job) { _ in }   // the settle pass
        let ids = try await snapshotIDs(runner)
        XCTAssertEqual(ids.count, 2)
        let newest = try await restored(runner, try XCTUnwrap(ids.first))
        XCTAssertEqual(newest["a.txt"], "beta!")
    }

    func testTheTimelineShowsWhatTheRepoOccupies() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        let history = try await runner.history(for: job)
        let packs = try await LocalBackend(root: repoRoot).bytes(prefix: "data")
        XCTAssertGreaterThan(packs, 0)
        XCTAssertEqual(history.storageBytes, packs, "the quota gauge showed 0 for an encrypted backup")
    }

    func testARequestedRestorePointIsWrittenEvenWhenNothingChanged() async throws {
        let runner = runner()
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }
        let ids = try await snapshotIDs(runner)
        XCTAssertEqual(ids.count, 2, "both asked for; the cadence thins neither")
    }

    /// Every snapshot of the repo, by ID, as the timeline reads them.
    private func summaries() async throws -> [String: RepoSnapshotSummary] {
        let backend = try LocalBackend(root: repoRoot)
        let keys = try await RepoManager.unlock(backend: backend, password: Data("pw".utf8)).keys
        let timeline = RepoTimeline(directory: fixture.root.appendingPathComponent("summaries-\(UUID().uuidString)",
                                                                                  isDirectory: true))
        let listed = try await timeline.snapshots(jobID: job.id, backend: backend, keys: keys)
        return Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0) })
    }

    func testAPassThatRemovesAFileNamesTheStateItRemovedItFrom() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        let afterFirst = try await snapshotIDs(runner)
        let first = try XCTUnwrap(afterFirst.first)
        try fixture.write("a.txt", "beta!")
        fixture.waitForEvents()
        _ = try await runner.run(job: job) { _ in }
        let afterEdit = try await snapshotIDs(runner)
        let edited = try XCTUnwrap(afterEdit.first)
        try fixture.delete("sub")
        fixture.waitForEvents()
        _ = try await runner.run(job: job) { _ in }
        let afterRemoval = try await snapshotIDs(runner)
        let removed = try XCTUnwrap(afterRemoval.first)

        let listed = try await summaries()
        XCTAssertNil(listed[edited]?.removedFrom, "an edit removes nothing")
        XCTAssertNotEqual(edited, first)
        XCTAssertEqual(listed[removed]?.removedFrom, edited, "the folder and its file went")
    }

    // MARK: - Cadence

    private func summary(_ id: String, _ time: Double, requested: Bool = false, origin: String? = nil) -> RepoSnapshotSummary {
        RepoSnapshotSummary(id: id, createdAt: time, fileCount: 0, totalBytes: 0, origin: origin,
                            requested: requested ? true : nil)
    }

    func testTheCadenceKeepsTheFirstAfterSpacingEachStateLeftAloneAndTheNewest() {
        let ordered = [summary("a", 0), summary("b", 60), summary("c", 120), summary("d", 1_000),
                       summary("e", 1_060), summary("f", 5_000), summary("g", 5_060)]
        let dropped = RepoMaintenance.cadenceThinned(ordered, spacing: 900)
        // a: first. b, c: a burst within 15 minutes. d: spacing elapsed since a. e: left alone until f.
        // f: spacing elapsed. g: newest.
        XCTAssertEqual(dropped, [1, 2])
    }

    func testTheCadenceKeepsEveryStateALaterPassRemovedSomethingFrom() {
        var d = summary("d", 180)
        d.removedFrom = "c"
        let ordered = [summary("a", 0), summary("b", 60), summary("c", 120), d, summary("e", 240)]
        // c: the only state holding what d's pass removed. b, d: a burst within 15 minutes. e: newest.
        XCTAssertEqual(RepoMaintenance.cadenceThinned(ordered, spacing: 900), [1, 3])
    }

    func testTheCadenceNeverThinsRequestedOrMigratedSnapshots() {
        let ordered = [summary("a", 0), summary("b", 60, requested: true), summary("c", 120, origin: "migrated:x"),
                       summary("d", 180), summary("e", 240)]
        XCTAssertEqual(RepoMaintenance.cadenceThinned(ordered, spacing: 900), [3])
    }

    // MARK: - Scope

    func testAScopeListsWhatWasReportedAndTheWayThere() {
        let scope = DedupEngine.SourceScope(dirty: ["a/b": false, "x": true], carried: ["q/r"])
        for listed in ["", "a", "a/b", "x", "x/y", "x/y/z", "q", "q/r"] {
            XCTAssertTrue(scope.mustList(listed), listed)
        }
        for unlisted in ["a/c", "a/b/c", "b", "q/s", "xy"] {
            XCTAssertFalse(scope.mustList(unlisted), unlisted)
        }
    }
}
