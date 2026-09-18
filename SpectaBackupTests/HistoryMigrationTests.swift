//
//  @file        HistoryMigrationTests.swift
//  @description History engine, phase 4 — migration from 1.1.x. HistorySeeder: the newest legacy snapshot
//               is cloned into current/ and recorded, so the first full pass copies only what changed
//               since; it runs only on a pristine catalog, skips sources the snapshot lacks, and leftovers
//               of an interrupted seed never linger, and an unchanged source adds no checkpoint. End to end
//               through the BackupRunner: a job with 1.1.x snapshots gets checkpoint 1 on its next pass,
//               keeps its old snapshots on the same timeline (restorable), and stops writing snapshot
//               trees. HistoryMaterializer: a checkpoint rebuilt as a folder tree is exactly that checkpoint,
//               and survives a round trip through the encrypted repo (the encryption migration's path).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import Darwin
import XCTest
@testable import SpectaBackup

final class HistoryMigrationTests: XCTestCase {

    private var fixture: HistoryFixture!
    private var snapshotRoot: URL { fixture.root.appendingPathComponent("legacy-snapshot", isDirectory: true) }

    override func setUpWithError() throws { fixture = try HistoryFixture() }
    override func tearDownWithError() throws { fixture?.remove() }

    /// A legacy snapshot of the source as it is now, made the way 1.1.x did (metadata-faithful copies).
    private func takeLegacySnapshot(into root: URL? = nil) throws {
        let tree = (root ?? snapshotRoot).appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileWalker.walk(root: fixture.source, exclusions: .includeEverything) { item in
            let destination = tree.appendingPathComponent(item.relativePath).path
            if item.isDirectory {
                try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            } else {
                try Syscalls.copyItem(at: item.url.path, to: destination)
            }
        }
    }

    /// A published 1.1.x snapshot of the job: `snapshots/<dirName>/src/…` with the COMPLETE marker at its
    /// top, recorded `complete` in the job's catalog.sqlite.
    private func publishLegacySnapshot(of job: BackupJob) async throws -> SnapshotRecord {
        let jobRoot = BackupRunner.jobRoot(for: job)
        let catalog = try CatalogStore(path: jobRoot.appendingPathComponent("catalog.sqlite").path)
        let seq = try await catalog.beginSnapshot(jobID: job.id, timestamp: Date(), sourceSnapshotID: nil)
        let dirName = "20260918-120000-\(seq)"
        let tree = jobRoot.appendingPathComponent("snapshots/\(dirName)", isDirectory: true)
        try takeLegacySnapshot(into: tree)
        try Data().write(to: tree.appendingPathComponent(SnapshotBrowser.completeMarker))
        try await catalog.markComplete(seqId: seq, dirName: dirName, fileCount: 0, logicalBytes: 0,
                                       addedBlocks: 0, durationMs: 0)
        let published = try await catalog.latestComplete(jobID: job.id)
        return try XCTUnwrap(published)
    }

    // MARK: - HistorySeeder

    func testTheFirstPassAfterASeedCopiesOnlyWhatChanged() throws {
        try fixture.write("same.txt", "unchanged since the snapshot")
        try fixture.write("docs/edited.txt", "old")
        try fixture.write("gone.txt", "deleted after the snapshot")
        try fixture.write("node_modules/pkg/index.js", "1.1.x backed this up")
        try takeLegacySnapshot()
        try fixture.write("docs/edited.txt", "new!")
        try fixture.write("added.txt", "added")
        try fixture.delete("gone.txt")

        let seeded = try HistorySeeder(layout: fixture.layout).seedIfPristine(from: snapshotRoot, sourceNames: ["src"], exclusions: BackupExclusions(job: fixture.job))
        XCTAssertEqual(seeded, 5, "src, same.txt, docs, docs/edited.txt, gone.txt — not the excluded node_modules")
        let outcome = try fixture.pass(at: 0)
        XCTAssertTrue(outcome.fullScan)
        XCTAssertEqual(outcome.bytesCopied, 9, "edited.txt (4) and added.txt (5) only")
        XCTAssertEqual(outcome.changedCount, 3, "and gone.txt removed; nothing excluded to clean up")
        XCTAssertEqual(outcome.sealed.map(\.seq), [1])
        XCTAssertEqual(try fixture.files(at: 1), ["src/same.txt": "unchanged since the snapshot",
                                                  "src/docs/edited.txt": "new!", "src/added.txt": "added"])
        XCTAssertTrue(try fixture.store().versions().isEmpty, "the seeded state is the legacy snapshot's, not history")
        try fixture.assertConsistent()
    }

    func testAnUnchangedSourceAddsNoCheckpointAfterASeed() throws {
        try fixture.write("a.txt", "a")
        try takeLegacySnapshot()
        try HistorySeeder(layout: fixture.layout).seedIfPristine(from: snapshotRoot, sourceNames: ["src"], exclusions: BackupExclusions(job: fixture.job))
        let outcome = try fixture.pass(at: 0, force: true)
        XCTAssertEqual(outcome.changedCount, 0)
        XCTAssertTrue(outcome.sealed.isEmpty, "the legacy snapshot already is this restore point")
        XCTAssertEqual(fixture.mirror("a.txt"), "a")
        try fixture.assertConsistent()
    }

    func testASeedRunsOnlyOnAPristineCatalog() throws {
        try fixture.write("a.txt", "a")
        try takeLegacySnapshot()
        try fixture.pass(at: 0)
        XCTAssertEqual(try HistorySeeder(layout: fixture.layout).seedIfPristine(from: snapshotRoot, sourceNames: ["src"], exclusions: BackupExclusions(job: fixture.job)), 0)
    }

    func testASourceTheSnapshotLacksIsNotSeeded() throws {
        try fixture.write("a.txt", "a")
        try FileManager.default.createDirectory(at: snapshotRoot.appendingPathComponent("other"), withIntermediateDirectories: true)
        XCTAssertEqual(try HistorySeeder(layout: fixture.layout).seedIfPristine(from: snapshotRoot, sourceNames: ["src"], exclusions: BackupExclusions(job: fixture.job)), 0)
        XCTAssertEqual(try fixture.pass(at: 0).bytesCopied, 1, "copied from the source instead")
    }

    func testLeftoversOfAnInterruptedSeedNeverLinger() throws {
        try fixture.write("a.txt", "a")
        // A seed that cloned but never committed: the catalog is still pristine.
        try FileManager.default.createDirectory(atPath: fixture.layout.current("src/stale"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: fixture.layout.current("src/stale/x.txt")))
        try fixture.pass(at: 0)
        XCTAssertNil(fixture.mirror("stale/x.txt"))
        XCTAssertEqual(fixture.mirror("a.txt"), "a")
        try fixture.assertConsistent()
    }

    // MARK: - HistoryMaterializer

    func testACheckpointMaterializesExactlyAndRoundTripsThroughTheEncryptedRepo() async throws {
        try fixture.write("a.txt", "v1")
        try fixture.write("docs/b.txt", "bravo")
        try fixture.pass(at: 0)
        try fixture.write("a.txt", "v2-")
        try fixture.delete("docs")
        try fixture.write("c.txt", "charlie")
        try fixture.pass(at: 16)

        for seq in [Int64(1), 2] {
            let tree = fixture.layout.jobRoot.appendingPathComponent(".materialize-\(seq)", isDirectory: true)
            let roots = try HistoryMaterializer(layout: fixture.layout).materialize(sourceNames: ["src"], at: seq, into: tree)
            XCTAssertEqual(roots.map(\.lastPathComponent), ["src"])
            var built: [String: String] = [:]
            try FileWalker.walk(root: tree, exclusions: .includeEverything) { item in
                if !item.isDirectory { built[item.relativePath] = try String(contentsOf: item.url, encoding: .utf8) }
            }
            XCTAssertEqual(built, try fixture.files(at: seq), "checkpoint \(seq)")

            let repo = fixture.root.appendingPathComponent("repo-\(seq)", isDirectory: true)
            let keys = RepoKeys.generate()
            let chunker = FastCDC(minSize: 64, avgSize: 256, maxSize: 1024)
            _ = try await DedupEngine(backend: try LocalBackend(root: repo), keys: keys, chunker: chunker)
                .backUp(sources: roots, snapshotID: "enc-\(seq)", now: 1000, exclusions: .includeEverything,
                        toleratingVanishedEntries: false)
            let restored = fixture.root.appendingPathComponent("restored-\(seq)", isDirectory: true)
            try await DedupEngine(backend: try LocalBackend(root: repo), keys: keys, chunker: chunker)
                .restore(snapshotID: "enc-\(seq)", to: restored)
            var back: [String: String] = [:]
            try FileWalker.walk(root: restored, exclusions: .includeEverything) { item in
                if !item.isDirectory { back[item.relativePath] = try String(contentsOf: item.url, encoding: .utf8) }
            }
            XCTAssertEqual(back, built)
            try FileManager.default.removeItem(at: tree)
        }
        try fixture.assertConsistent()
    }

    // MARK: - End to end through the runner

    func testAJobWithLegacySnapshotsMovesToTheHistoryEngine() async throws {
        let job = fixture.job
        try fixture.write("a.txt", "v1")
        try fixture.write("b.txt", "bravo")
        let jobRoot = BackupRunner.jobRoot(for: job)
        let legacySnapshot = try await publishLegacySnapshot(of: job)

        try fixture.write("a.txt", "v2-")
        try fixture.delete("b.txt")

        let runner = BackupRunner()   // its first history pass is a full scan: no events needed
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }
        let history = try await runner.history(for: job)
        XCTAssertEqual(history.points.map(\.source), [.checkpoint(seq: 1), .legacySnapshot(dirName: legacySnapshot.dirName)])
        XCTAssertEqual(fixture.mirror("a.txt"), "v2-")
        XCTAssertNil(fixture.mirror("b.txt"))

        let target = fixture.root.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        _ = try await runner.restore(job: job, point: history.points[1], sourceName: "src", relPaths: ["b.txt"],
                                     to: target, conflict: .overwrite, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("b.txt"), encoding: .utf8), "bravo")

        let trees = try FileManager.default.contentsOfDirectory(atPath: jobRoot.appendingPathComponent("snapshots").path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(trees, [legacySnapshot.dirName], "no new snapshot tree")
        try fixture.assertConsistent()
    }
}
