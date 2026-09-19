//
//  @file        EncryptedTimelineTests.swift
//  @description An encrypted job's restore points come from its repo alone (RepoTimeline): a pass writes no
//               catalog at the destination and is listed and restorable; the local cache shows the timeline
//               without the password, forgets snapshots gone from the repo and is never taken over by another
//               repo; a catalog from before, listing only encrypted snapshots, is removed and its snapshots
//               stay listed once; an object being written is never listed; a pass thins the snapshots with
//               the job's retention policy; a repo created anew at the same path is never written with the
//               old one's keys; markers of earlier migrations move into their snapshots, which the cadence
//               then never thins.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//

import XCTest
@testable import SpectaBackup

final class EncryptedTimelineTests: XCTestCase {

    private var fixture: HistoryFixture!
    private var cacheDirectory: URL!
    private var job: BackupJob!

    private var jobRoot: URL { BackupRunner.jobRoot(for: job) }
    private var repoRoot: URL { jobRoot.appendingPathComponent("repo", isDirectory: true) }

    override func setUp() async throws {
        fixture = try HistoryFixture()
        cacheDirectory = fixture.root.appendingPathComponent("cache", isDirectory: true)
        job = fixture.job
        job.encryptionEnabled = true
        try fixture.write("a.txt", "alpha")
        _ = try await RepoManager.create(backend: try LocalBackend(root: repoRoot), password: Data("pw".utf8))
    }

    override func tearDownWithError() throws { fixture?.remove() }

    private func runner(password: String? = "pw", cache: URL? = nil) -> BackupRunner {
        BackupRunner(passwords: { _ in password }, timeline: RepoTimeline(directory: cache ?? cacheDirectory))
    }

    private func encryptedIDs(_ history: BackupHistory) -> [String] {
        history.points.compactMap { point in
            if case let .encryptedSnapshot(id) = point.source { return id }
            return nil
        }
    }

    func testAnEncryptedPassIsListedFromItsRepoAloneAndRestores() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent("catalog.sqlite").path),
                       "no catalog at the destination")

        let history = try await runner.history(for: job)
        let id = try XCTUnwrap(encryptedIDs(history).first)
        XCTAssertEqual(history.points.count, 1)
        XCTAssertEqual(history.points.first?.fileCount, 1)
        XCTAssertNotNil(history.lastBackup)

        let target = fixture.root.appendingPathComponent("restored", isDirectory: true)
        try await runner.restoreEncrypted(job: job, snapshotID: id, to: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("src/a.txt"), encoding: .utf8), "alpha")
    }

    func testTheCacheShowsTheTimelineWithoutThePassword() async throws {
        _ = try await runner().run(job: job) { _ in }
        _ = try await runner().history(for: job)   // decrypted once, cached

        let locked = try await runner(password: nil).history(for: job)
        XCTAssertEqual(encryptedIDs(locked).count, 1, "from the cache")
        let uncached = try await runner(password: nil, cache: fixture.root.appendingPathComponent("empty")).history(for: job)
        XCTAssertTrue(uncached.points.isEmpty, "nothing can be read without the keys")
    }

    func testASnapshotGoneFromTheRepoLeavesTheTimeline() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        let before = try await runner.history(for: job)
        let id = try XCTUnwrap(encryptedIDs(before).first)
        try FileManager.default.removeItem(at: repoRoot.appendingPathComponent("snapshots/\(id)"))

        let after = try await runner.history(for: job)
        XCTAssertTrue(after.points.isEmpty)
        let cached = try await self.runner(password: nil).history(for: job)
        XCTAssertTrue(cached.points.isEmpty, "the cache forgot it too")
    }

    func testACacheIsNeverTakenOverByAnotherRepo() async throws {
        _ = try await runner().run(job: job) { _ in }
        _ = try await runner().history(for: job)

        // The repo is replaced by a new one (its snapshots copied over, so only the cache could tell).
        let snapshots = fixture.root.appendingPathComponent("kept-snapshots", isDirectory: true)
        try FileManager.default.moveItem(at: repoRoot.appendingPathComponent("snapshots"), to: snapshots)
        try FileManager.default.removeItem(at: repoRoot)
        _ = try await RepoManager.create(backend: try LocalBackend(root: repoRoot), password: Data("pw".utf8))
        try FileManager.default.moveItem(at: snapshots, to: repoRoot.appendingPathComponent("snapshots"))

        let history = try await runner(password: nil).history(for: job)
        XCTAssertTrue(history.points.isEmpty, "the old repo's cache does not describe this one")
    }

    func testACatalogFromBeforeIsRemovedAndItsSnapshotsListedOnce() async throws {
        // As an earlier build left it: a snapshot "enc-1" in the repo, recorded in catalog.sqlite too.
        let (config, keys) = try await RepoManager.unlock(backend: try LocalBackend(root: repoRoot), password: Data("pw".utf8))
        let engine = DedupEngine(backend: try LocalBackend(root: repoRoot), keys: keys, chunker: config.chunker)
        try await engine.backUp(sources: job.sources, snapshotID: "enc-1", now: 1_000,
                                exclusions: .includeEverything, toleratingVanishedEntries: false)
        let catalog = try CatalogStore(path: jobRoot.appendingPathComponent("catalog.sqlite").path)
        let seq = try await catalog.beginSnapshot(jobID: job.id, timestamp: Date(timeIntervalSince1970: 1_000),
                                                  sourceSnapshotID: nil)
        try await catalog.markComplete(seqId: seq, dirName: "enc-1", fileCount: 1, logicalBytes: 5, addedBlocks: 0,
                                       durationMs: 0)

        try fixture.write("a.txt", "beta!")
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent("catalog.sqlite").path),
                       "it listed nothing the repo does not record itself")
        let history = try await runner.history(for: job)
        let ids = encryptedIDs(history)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.last, "enc-1", "the older one, listed once")
    }

    func testAnEncryptedPassThinsTheSnapshotsWithTheJobsPolicy() async throws {
        job.retention = RetentionPolicy(mode: .keepCount(1))
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        try fixture.write("a.txt", "beta!")
        _ = try await runner.run(job: job) { _ in }

        let history = try await runner.history(for: job)
        let id = try XCTUnwrap(encryptedIDs(history).first)
        XCTAssertEqual(history.points.count, 1, "the older snapshot was dropped")
        let target = fixture.root.appendingPathComponent("restored", isDirectory: true)
        try await runner.restoreEncrypted(job: job, snapshotID: id, to: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("src/a.txt"), encoding: .utf8), "beta!")
    }

    func testAnObjectBeingWrittenIsNeverListed() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        try Data("partial".utf8).write(to: repoRoot.appendingPathComponent("snapshots/.x.\(UUID().uuidString).tmp"))
        let history = try await runner.history(for: job)
        XCTAssertEqual(encryptedIDs(history).count, 1)
    }

    func testARepoCreatedAnewIsNeverWrittenWithTheOldKeys() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }   // the old repo's keys are unlocked now
        try FileManager.default.removeItem(at: repoRoot)
        _ = try await RepoManager.create(backend: try LocalBackend(root: repoRoot), password: Data("pw".utf8))
        try fixture.write("a.txt", "beta!")
        _ = try await runner.run(job: job) { _ in }

        // As after a relaunch: nothing unlocked, nothing cached.
        let fresh = BackupRunner(passwords: { _ in "pw" },
                                 timeline: RepoTimeline(directory: fixture.root.appendingPathComponent("fresh-cache")))
        let history = try await fresh.history(for: job)
        let id = try XCTUnwrap(encryptedIDs(history).first, "readable with the new repo's keys")
        let target = fixture.root.appendingPathComponent("restored", isDirectory: true)
        try await fresh.restoreEncrypted(job: job, snapshotID: id, to: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("src/a.txt"), encoding: .utf8), "beta!")
    }

    func testMarkersOfEarlierMigrationsMoveIntoTheirSnapshots() async throws {
        // An earlier build migrated two points ten seconds apart: "enc-1", "enc-2", markers in catalog.sqlite.
        let (config, keys) = try await RepoManager.unlock(backend: try LocalBackend(root: repoRoot), password: Data("pw".utf8))
        let engine = DedupEngine(backend: try LocalBackend(root: repoRoot), keys: keys, chunker: config.chunker)
        let catalog = try CatalogStore(path: jobRoot.appendingPathComponent("catalog.sqlite").path)
        let anHourAgo = Date().timeIntervalSince1970 - 3_600   // recent: the policy keeps every point of the day
        for (seq, time) in [(1, anHourAgo), (2, anHourAgo + 10)] {
            try await engine.backUp(sources: job.sources, snapshotID: "enc-\(seq)", now: time,
                                    exclusions: .includeEverything, toleratingVanishedEntries: false)
            let row = try await catalog.beginSnapshot(jobID: job.id, timestamp: Date(timeIntervalSince1970: time),
                                                      sourceSnapshotID: "migrated:legacy:2026010\(seq)")
            try await catalog.markComplete(seqId: row, dirName: "enc-\(seq)", fileCount: 1, logicalBytes: 5,
                                           addedBlocks: 0, durationMs: 0)
        }

        try fixture.write("a.txt", "beta!")
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent("catalog.sqlite").path))
        let history = try await runner.history(for: job)
        XCTAssertEqual(Set(encryptedIDs(history)).intersection(["enc-1", "enc-2"]), ["enc-1", "enc-2"],
                       "migrated points: never thinned by the cadence")
    }

    func testAMarkerStaysInTheCatalogWhileItsSnapshotCannotBeRead() async throws {
        let (config, keys) = try await RepoManager.unlock(backend: try LocalBackend(root: repoRoot), password: Data("pw".utf8))
        let engine = DedupEngine(backend: try LocalBackend(root: repoRoot), keys: keys, chunker: config.chunker)
        try await engine.backUp(sources: job.sources, snapshotID: "enc-1", now: Date().timeIntervalSince1970 - 3_600,
                                exclusions: .includeEverything, toleratingVanishedEntries: false)
        let catalog = try CatalogStore(path: jobRoot.appendingPathComponent("catalog.sqlite").path)
        let row = try await catalog.beginSnapshot(jobID: job.id, timestamp: Date(), sourceSnapshotID: "migrated:legacy:x")
        try await catalog.markComplete(seqId: row, dirName: "enc-1", fileCount: 1, logicalBytes: 5, addedBlocks: 0,
                                       durationMs: 0)
        try await LocalBackend(root: repoRoot).put(key: "snapshots/enc-1", data: Data("damaged for now".utf8))

        try fixture.write("a.txt", "beta!")
        _ = try await runner().run(job: job) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobRoot.appendingPathComponent("catalog.sqlite").path),
                      "its marker could not be moved: the catalog keeps it")
    }

    func testAPassWarnsWhenOldRestorePointsCannotBeCleanedUp() async throws {
        let runner = runner()
        _ = try await runner.run(job: job) { _ in }
        let history = try await runner.history(for: job)
        let first = try XCTUnwrap(encryptedIDs(history).first)
        try await LocalBackend(root: repoRoot).put(key: "snapshots/\(first)", data: Data("damaged".utf8))
        try fixture.write("a.txt", "beta!")
        // Read afresh (a cached snapshot is read again by the daily collection, which reports it the same way).
        let fresh = self.runner(cache: fixture.root.appendingPathComponent("fresh-cache"))
        let result = try await fresh.run(job: job) { _ in }
        XCTAssertNotNil(result.warning, "the backup succeeded, but the user should know")
    }
}
