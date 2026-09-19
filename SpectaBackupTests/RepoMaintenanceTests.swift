//
//  @file        RepoMaintenanceTests.swift
//  @description Encrypted repo retention and garbage collection (RepoMaintenance): the policy drops the
//               oldest snapshots and the collection removes exactly what only they used — packs, a repacked
//               pack's dead part, trees — while every kept snapshot still restores; dropped data waits for
//               the daily collection; an interrupted collection (after rewriting packs, after removing index
//               objects) leaves every kept snapshot restorable and the next one finishes the job; a quota
//               drops the oldest until the live data fits, never the newest; a snapshot that cannot be read
//               stops the collection (reported) while the age and count rules go on; one the caller did not
//               list keeps its data; what takes no writing is reclaimed before anything is rewritten; a folder
//               the listing cannot read, or an object it cannot delete, stops it too; free space below the
//               floor collects at once even when the garbage alone is enough.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//

import Darwin
import XCTest
@testable import SpectaBackup

final class RepoMaintenanceTests: XCTestCase {

    private var root: URL!
    private var backend: LocalBackend!
    private var keys: RepoKeys!
    private var config: RepoConfig!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-maintenance-\(UUID().uuidString)", isDirectory: true)
        backend = try LocalBackend(root: root.appendingPathComponent("repo", isDirectory: true))
        let created = try await RepoManager.create(backend: backend, password: Data("pw".utf8))
        keys = created.keys
        config = created.config
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private struct Taken {
        let id: String
        let time: Double
    }

    /// A backup of a source holding `files` (name → contents), taken at `time`.
    private func backUp(_ files: [String: Data], at time: Double) async throws -> Taken {
        let source = root.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: source.appendingPathComponent(name)) }
        let engine = DedupEngine(backend: backend, keys: keys, chunker: config.chunker)
        try await engine.open()
        let id = "t\(Int(time))"
        try await engine.backUp(sources: [source], snapshotID: id, now: time,
                                exclusions: .includeEverything, toleratingVanishedEntries: false)
        try FileManager.default.removeItem(at: source)
        return Taken(id: id, time: time)
    }

    private func summaries(_ taken: [Taken]) -> [RepoSnapshotSummary] {
        taken.map { RepoSnapshotSummary(id: $0.id, createdAt: $0.time, fileCount: 0, totalBytes: 0, origin: nil) }
    }

    private func maintenance(_ hook: (@Sendable (RepoMaintenance.Step) throws -> Void)? = nil) -> RepoMaintenance {
        RepoMaintenance(backend: backend, keys: keys, faultHook: hook)
    }

    private func restore(_ id: String) async throws -> [String: Data] {
        let target = root.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try await DedupEngine(backend: backend, keys: keys, chunker: config.chunker).restore(snapshotID: id, to: target)
        let folder = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: target.path).first)
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: target.appendingPathComponent(folder).path) {
            files[name] = try Data(contentsOf: target.appendingPathComponent("\(folder)/\(name)"))
        }
        return files
    }

    private func blobCount() async throws -> [Data: Int] {
        var count: [Data: Int] = [:]
        for pack in try await PackFormat.readIndex(backend: backend, cipher: BlobCipher(keys: keys)) {
            for entry in pack.entries { count[entry.blobID, default: 0] += 1 }
        }
        return count
    }

    private func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private let keepOne = RetentionPolicy(mode: .keepCount(1))
    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: - Policy and collection

    func testTheOldestAreDroppedAndOnlyWhatTheyAloneUsedIsCollected() async throws {
        let shared = bytes(40_000), onlyFirst = bytes(60_000), onlySecond = bytes(60_000)
        let first = try await backUp(["shared": shared, "b": onlyFirst], at: 1_000)
        let second = try await backUp(["shared": shared, "c": onlySecond], at: 2_000)
        let third = try await backUp(["shared": shared], at: 3_000)
        let treesBefore = try await backend.list(prefix: "trees").count

        let outcome = try await maintenance().run(policy: keepOne, snapshots: summaries([first, second, third]),
                                                  freeBytes: .max, collect: true, now: now)
        XCTAssertEqual(outcome.dropped, [first.id, second.id])
        XCTAssertTrue(outcome.collected)
        XCTAssertGreaterThan(outcome.reclaimedBytes, 100_000)
        let remaining = try await backend.list(prefix: "snapshots")
        XCTAssertEqual(remaining, ["snapshots/\(third.id)"])
        let blobs = try await blobCount()
        XCTAssertEqual(blobs.count, 1, "only the shared file's blob is left")
        XCTAssertEqual(Set(blobs.values), [1], "stored once")
        let treesAfter = try await backend.list(prefix: "trees").count
        XCTAssertLessThan(treesAfter, treesBefore)
        let restored = try await restore(third.id)
        XCTAssertEqual(restored, ["shared": shared])
    }

    func testDroppedSnapshotsDataWaitsForTheDailyCollection() async throws {
        let first = try await backUp(["a": bytes(50_000)], at: 1_000)
        let second = try await backUp(["b": bytes(50_000)], at: 2_000)
        let packsBefore = try await backend.list(prefix: "data").count

        let dropped = try await maintenance().run(policy: keepOne, snapshots: summaries([first, second]),
                                                  freeBytes: .max, collect: false, now: now)
        XCTAssertEqual(dropped.dropped, [first.id])
        XCTAssertFalse(dropped.collected)
        let packsWaiting = try await backend.list(prefix: "data").count
        XCTAssertEqual(packsWaiting, packsBefore, "unreachable, not yet reclaimed")

        let collected = try await maintenance().run(policy: keepOne, snapshots: summaries([second]),
                                                    freeBytes: .max, collect: true, now: now)
        XCTAssertTrue(collected.collected)
        let packsAfter = try await backend.list(prefix: "data").count
        XCTAssertLessThan(packsAfter, packsBefore)
        let restored = try await restore(second.id)
        XCTAssertEqual(restored.keys.sorted(), ["b"])
    }

    // MARK: - Interruptions

    private struct Interrupted: Error {}

    private func interruptedCollectionLeavesEverythingRestorable(at step: RepoMaintenance.Step) async throws {
        let shared = bytes(10_000), dead = bytes(90_000)
        let first = try await backUp(["shared": shared, "dead": dead], at: 1_000)   // one pack: mostly dead later
        let second = try await backUp(["shared": shared, "new": bytes(5_000)], at: 2_000)

        let crashing = maintenance { if $0 == step { throw Interrupted() } }
        do {
            _ = try await crashing.run(policy: keepOne, snapshots: summaries([first, second]), freeBytes: .max,
                                       collect: true, now: now)
            XCTFail("interrupted")
        } catch is Interrupted {}
        let meanwhile = try await restore(second.id)
        XCTAssertEqual(meanwhile["shared"], shared, "restorable while interrupted")

        _ = try await maintenance().run(policy: keepOne, snapshots: summaries([second]), freeBytes: .max,
                                        collect: true, now: now)
        let restored = try await restore(second.id)
        XCTAssertEqual(restored["shared"], shared)
        let blobs = try await blobCount()
        XCTAssertEqual(blobs.count, 2, "shared and new; the dead blob is gone")
        XCTAssertEqual(Set(blobs.values), [1], "no copy left twice")
        let packs = try await backend.list(prefix: "data").count
        let indexes = try await backend.list(prefix: "index").count
        XCTAssertEqual(packs, indexes, "no pack without its index")
    }

    func testACollectionInterruptedAfterRewritingPacksIsFinishedByTheNext() async throws {
        try await interruptedCollectionLeavesEverythingRestorable(at: .packsRewritten)
    }

    func testACollectionInterruptedAfterRemovingIndexesIsFinishedByTheNext() async throws {
        try await interruptedCollectionLeavesEverythingRestorable(at: .indexesRemoved)
    }

    // MARK: - Space

    func testAQuotaDropsTheOldestUntilTheLiveDataFitsButNeverTheNewest() async throws {
        let shared = bytes(1_000)
        let first = try await backUp(["shared": shared, "u": bytes(100_000)], at: 1_000)
        let second = try await backUp(["shared": shared, "u": bytes(100_000)], at: 2_000)
        let third = try await backUp(["shared": shared, "u": bytes(100_000)], at: 3_000)
        let all = summaries([first, second, third])

        let quota = RetentionPolicy(mode: .keepAll, maxTotalBytes: 250_000)
        let outcome = try await maintenance().run(policy: quota, snapshots: all, freeBytes: .max, collect: false, now: now)
        XCTAssertEqual(outcome.dropped, [first.id], "two newest fit")
        XCTAssertTrue(outcome.collected, "space pressure collects right away")

        let tiny = RetentionPolicy(mode: .keepAll, maxTotalBytes: 1)
        let squeezed = try await maintenance().run(policy: tiny, snapshots: summaries([second, third]), freeBytes: .max,
                                                   collect: false, now: now)
        XCTAssertEqual(squeezed.dropped, [second.id], "the newest stays, over quota or not")
        let restored = try await restore(third.id)
        XCTAssertEqual(restored["shared"], shared)
    }

    func testASnapshotThatCannotBeReadStopsTheCollection() async throws {
        let first = try await backUp(["a": bytes(20_000)], at: 1_000)
        let second = try await backUp(["b": bytes(20_000)], at: 2_000)
        try await backend.put(key: "snapshots/\(second.id)", data: Data("damaged".utf8))
        let packsBefore = try await backend.list(prefix: "data").count
        let treesBefore = try await backend.list(prefix: "trees").count

        let outcome = try await maintenance().run(policy: RetentionPolicy(mode: .keepAll),
                                                  snapshots: summaries([first, second]), freeBytes: .max,
                                                  collect: true, now: now)
        XCTAssertEqual(outcome.unreadable, [second.id], "its references are unknown: reported")
        XCTAssertFalse(outcome.collected)
        let packsAfter = try await backend.list(prefix: "data").count
        let treesAfter = try await backend.list(prefix: "trees").count
        XCTAssertEqual(packsAfter, packsBefore)
        XCTAssertEqual(treesAfter, treesBefore)
    }

    func testAnUnreadableSnapshotStillLetsTheCadenceAndPolicyDrop() async throws {
        let first = try await backUp(["a": bytes(20_000)], at: 1_000)
        let second = try await backUp(["b": bytes(20_000)], at: 2_000)
        let third = try await backUp(["c": bytes(20_000)], at: 3_000)
        try await backend.put(key: "snapshots/\(second.id)", data: Data("damaged".utf8))
        let quota = RetentionPolicy(mode: .keepCount(2), maxTotalBytes: 10)   // space rules wait while it is there
        let outcome = try await maintenance().run(policy: quota, snapshots: summaries([first, second, third]),
                                                  freeBytes: .max, collect: true, now: now)
        XCTAssertEqual(outcome.dropped, [first.id], "keep 2 still applies")
        XCTAssertEqual(outcome.unreadable, [second.id])
        XCTAssertFalse(outcome.collected)
    }

    func testWhatTakesNoWritingIsReclaimedFirst() async throws {
        let shared = bytes(10_000)
        let first = try await backUp(["shared": shared, "x": bytes(90_000)], at: 1_000)   // will be partly dead
        let second = try await backUp(["y": bytes(50_000)], at: 2_000)                    // will be all dead
        let third = try await backUp(["shared": shared], at: 3_000)
        let packsBefore = try await backend.list(prefix: "data").count

        let stopped = maintenance { if $0 == .garbageRemoved { throw Interrupted() } }   // a full disk would stop here
        do {
            _ = try await stopped.run(policy: keepOne, snapshots: summaries([first, second, third]), freeBytes: .max,
                                      collect: true, now: now)
            XCTFail("stopped before writing")
        } catch is Interrupted {}
        let packsAfter = try await backend.list(prefix: "data").count
        XCTAssertEqual(packsAfter, packsBefore - 1, "the all-dead pack went without anything written")
        let restored = try await restore(third.id)
        XCTAssertEqual(restored["shared"], shared)
    }

    // MARK: - Never on an incomplete view

    func testASnapshotTheCallerDidNotListKeepsItsData() async throws {
        let first = try await backUp(["a": bytes(30_000)], at: 1_000)
        let second = try await backUp(["b": bytes(30_000)], at: 2_000)
        // The timeline could not read the first (not cached, no keys at hand): the collection must see it anyway.
        _ = try await maintenance().run(policy: RetentionPolicy(mode: .keepAll), snapshots: summaries([second]),
                                        freeBytes: .max, collect: true, now: now)
        let restored = try await restore(first.id)
        XCTAssertEqual(restored.keys.sorted(), ["a"])
    }

    func testAFolderTheListingCannotReadStopsTheCollection() async throws {
        let first = try await backUp(["a": bytes(30_000)], at: 1_000)
        let second = try await backUp(["b": bytes(30_000)], at: 2_000)
        let indexRoot = backend.root.appendingPathComponent("index")
        let shard = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: indexRoot.path).first)
        let unreadable = indexRoot.appendingPathComponent(shard).path
        chmod(unreadable, 0)
        defer { chmod(unreadable, 0o755) }
        let packsBefore = try FileWalkerCount.files(under: backend.root.appendingPathComponent("data"))

        do {
            _ = try await maintenance().run(policy: keepOne, snapshots: summaries([first, second]), freeBytes: .max,
                                            collect: true, now: now)
            XCTFail("an index that cannot be listed is no empty index")
        } catch {}
        chmod(unreadable, 0o755)
        XCTAssertEqual(try FileWalkerCount.files(under: backend.root.appendingPathComponent("data")), packsBefore)
        let restored = try await restore(second.id)
        XCTAssertEqual(restored.keys.sorted(), ["b"])
    }

    func testAnObjectThatCannotBeDeletedIsNoDeletion() async throws {
        _ = try await backUp(["a": bytes(1_000)], at: 1_000)
        let snapshots = backend.root.appendingPathComponent("snapshots").path
        chmod(snapshots, 0o555)
        defer { chmod(snapshots, 0o755) }
        do {
            try await backend.delete(key: "snapshots/t1000")
            XCTFail("the object is still there")
        } catch {}
        try await backend.delete(key: "snapshots/none")   // already gone: fine
    }

    func testFreeSpaceBelowTheFloorCollectsAtOnceEvenWhenGarbageAloneIsEnough() async throws {
        let first = try await backUp(["a": bytes(100_000)], at: 1_000)
        let second = try await backUp(["b": bytes(1_000)], at: 2_000)
        _ = try await maintenance().run(policy: keepOne, snapshots: summaries([first, second]), freeBytes: .max,
                                        collect: false, now: now)   // dropped; its data waits for the collection
        let floor = RetentionPolicy(mode: .keepAll, minimumFreeBytes: 50_000)
        let outcome = try await maintenance().run(policy: floor, snapshots: summaries([second]), freeBytes: 10_000,
                                                  collect: false, now: now)
        XCTAssertTrue(outcome.collected, "short of space now: the garbage is collected now")
        XCTAssertTrue(outcome.dropped.isEmpty, "collecting it is enough")
        XCTAssertGreaterThan(outcome.reclaimedBytes, 90_000)
    }
}

/// Files below a folder, counted.
private enum FileWalkerCount {
    static func files(under root: URL) throws -> Int {
        var count = 0
        try FileWalker.walk(root: root, exclusions: .includeEverything) { item in if !item.isDirectory { count += 1 } }
        return count
    }
}
