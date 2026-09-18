//
//  @file        HistoryMigrationTests.swift
//  @description History engine, phase 4 — migration from 1.1.x. HistorySeeder: the newest legacy snapshot
//               is cloned into current/ and recorded, so the first full pass copies only what changed
//               since; it runs only on a pristine catalog, skips sources the snapshot lacks, and leftovers
//               of an interrupted seed never linger, and an unchanged source adds no checkpoint. End to end
//               through the BackupRunner: a job with 1.1.x snapshots gets checkpoint 1 on its next pass,
//               keeps its old snapshots on the same timeline (restorable), and stops writing snapshot
//               trees. A locked legacy file is seeded unlocked and the snapshot keeps its lock.
//               HistoryMaterializer: a checkpoint rebuilt as a folder tree is exactly that checkpoint, and
//               survives a round trip through the encrypted repo. Turning encryption on leaves no plaintext
//               (even a seeded mirror that is no restore point, or a point an interrupted run encrypted)
//               and keeps sources since removed; a snapshot it cannot read stops it, and a history started
//               again after encryption was turned off is encrypted, never taken for the old one.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
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

    func testALockedLegacyFileIsSeededUnlockedAndTheSnapshotKeepsItsLock() throws {
        let immutable = UInt32(UF_IMMUTABLE)
        try fixture.write("doc.txt", "locked in 1.1.x")
        try takeLegacySnapshot()
        let legacyDoc = snapshotRoot.appendingPathComponent("src/doc.txt").path
        XCTAssertEqual(lchflags(legacyDoc, immutable), 0)

        try HistorySeeder(layout: fixture.layout).seedIfPristine(from: snapshotRoot, sourceNames: ["src"],
                                                                 exclusions: BackupExclusions(job: fixture.job))
        XCTAssertEqual(try Syscalls.flags(of: fixture.layout.current("src/doc.txt")) & Syscalls.lockFlags, 0)
        XCTAssertEqual(try fixture.store().entry(at: "src/doc.txt")?.lockFlags, immutable)
        XCTAssertEqual(try Syscalls.flags(of: legacyDoc) & Syscalls.lockFlags, immutable, "the snapshot is untouched")

        try fixture.write("doc.txt", "changed")
        try fixture.pass(at: 0)                                   // replacing the seeded copy works
        XCTAssertEqual(fixture.mirror("doc.txt"), "changed")
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
            let roots = try HistoryMaterializer(layout: fixture.layout).materialize(at: seq, into: tree)
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

    func testLegacyTreesLeftBehindAreReconciledNeverDeletedOnGuesswork() async throws {
        let job = fixture.job
        try fixture.write("a.txt", "alpha")
        let kept = try await publishLegacySnapshot(of: job)
        let snapshots = BackupRunner.jobRoot(for: job).appendingPathComponent("snapshots", isDirectory: true)
        let fm = FileManager.default
        // A complete tree whose row a 1.1.x launch cleanup dropped: a restore point to put back.
        let lost = snapshots.appendingPathComponent("20260101-000000-99", isDirectory: true)
        try fm.createDirectory(at: lost.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("lost".utf8).write(to: lost.appendingPathComponent("src/x.txt"))
        try Data().write(to: lost.appendingPathComponent(SnapshotBrowser.completeMarker))
        // A tree without its marker: nothing to judge, left alone.
        let unknown = snapshots.appendingPathComponent("20260102-000000-98", isDirectory: true)
        try fm.createDirectory(at: unknown.appendingPathComponent("src"), withIntermediateDirectories: true)
        // A deletion interrupted after its rename: finished, row included.
        let catalog = try CatalogStore(path: BackupRunner.jobRoot(for: job).appendingPathComponent("catalog.sqlite").path)
        try await catalog.adoptSnapshot(seqId: 97, jobID: job.id, timestamp: Date(timeIntervalSince1970: 0),
                                        dirName: "19700101-000000-97", fileCount: 0, logicalBytes: 0)
        let doomed = snapshots.appendingPathComponent(".deleting-19700101-000000-97", isDirectory: true)
        try fm.createDirectory(at: doomed, withIntermediateDirectories: true)

        _ = try await BackupRunner().run(job: job) { _ in }
        TreeReaper.shared.drain()   // dropped trees go in the background
        let rows = try await catalog.snapshots(jobID: job.id).map(\.dirName)
        XCTAssertTrue(rows.contains("20260101-000000-99"), "put back on the timeline")
        XCTAssertTrue(fm.fileExists(atPath: lost.path))
        XCTAssertTrue(fm.fileExists(atPath: unknown.path), "never deleted on guesswork")
        XCTAssertFalse(rows.contains("19700101-000000-97"))
        XCTAssertFalse(fm.fileExists(atPath: doomed.path))
        XCTAssertTrue(fm.fileExists(atPath: snapshots.appendingPathComponent(kept.dirName).path))
    }

    // MARK: - Turning encryption on

    private func makeRepo(for job: BackupJob, password: String) async throws {
        let repo = BackupRunner.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true)
        _ = try await RepoManager.create(backend: try LocalBackend(root: repo), password: Data(password.utf8))
    }

    func testTurningEncryptionOnLeavesNoPlaintextBehind() async throws {
        let job = fixture.job
        try fixture.write("a.txt", "alpha")
        let legacySnapshot = try await publishLegacySnapshot(of: job)
        let runner = BackupRunner()
        _ = try await runner.run(job: job) { _ in }   // seeds from the snapshot; nothing changed since
        XCTAssertNotNil(fixture.mirror("a.txt"))
        XCTAssertTrue(try fixture.store().checkpoints().isEmpty, "the seeded mirror is no restore point of its own")

        try await makeRepo(for: job, password: "pw")
        try await runner.migrateToEncrypted(job: job, password: "pw") { _, _ in }

        let fm = FileManager.default
        for leftover in [fixture.layout.currentRoot, fixture.layout.versionsRoot, fixture.layout.catalogPath,
                         BackupRunner.jobRoot(for: job).appendingPathComponent("snapshots/\(legacySnapshot.dirName)").path] {
            XCTAssertFalse(fm.fileExists(atPath: leftover), "plaintext left: \(leftover)")
        }
        let points = try await runner.history(for: job).points
        XCTAssertEqual(points.map(\.isBrowsable), [false], "one encrypted point")
        let remaining = await runner.plaintextSnapshotCount(for: job)
        XCTAssertEqual(remaining, 0)
    }

    func testARetriedMigrationAlsoRemovesWhatAnEarlierRunEncrypted() async throws {
        let job = fixture.job
        try fixture.write("a.txt", "alpha")
        let first = try await publishLegacySnapshot(of: job)
        try fixture.write("a.txt", "beta!")
        let second = try await publishLegacySnapshot(of: job)
        try await makeRepo(for: job, password: "pw")
        let snapshots = BackupRunner.jobRoot(for: job).appendingPathComponent("snapshots", isDirectory: true)
        // The second snapshot cannot be read: the first run encrypts the first one, then stops.
        let unreadable = snapshots.appendingPathComponent("\(second.dirName)/src").path
        chmod(unreadable, 0)
        defer { chmod(unreadable, 0o755) }
        let runner = BackupRunner()
        do {
            try await runner.migrateToEncrypted(job: job, password: "pw") { _, _ in }
            XCTFail("an unreadable snapshot must stop the migration")
        } catch {}
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: snapshots.appendingPathComponent(first.dirName).path), "plaintext intact")
        let stillPlaintext = await runner.plaintextSnapshotCount(for: job)
        XCTAssertEqual(stillPlaintext, 2, "the encrypted one is still plaintext on disk")

        chmod(unreadable, 0o755)
        try await runner.migrateToEncrypted(job: job, password: "pw") { _, _ in }
        TreeReaper.shared.drain()
        for snapshot in [first, second] {
            XCTAssertFalse(fm.fileExists(atPath: snapshots.appendingPathComponent(snapshot.dirName).path),
                           "plaintext left: \(snapshot.dirName)")
        }
        let points = try await runner.history(for: job).points
        XCTAssertEqual(points.map(\.isBrowsable), [false, false], "each encrypted once")
        let remaining = await runner.plaintextSnapshotCount(for: job)
        XCTAssertEqual(remaining, 0)
    }

    func testASnapshotThatCannotBeReadStopsTheMigration() async throws {
        let job = fixture.job
        try fixture.write("a.txt", "alpha")
        let snapshot = try await publishLegacySnapshot(of: job)
        try await makeRepo(for: job, password: "pw")
        let tree = BackupRunner.jobRoot(for: job).appendingPathComponent("snapshots/\(snapshot.dirName)").path
        chmod(tree, 0)
        defer { chmod(tree, 0o755) }
        do {
            try await BackupRunner().migrateToEncrypted(job: job, password: "pw") { _, _ in }
            XCTFail("a snapshot whose folders are unknown is no empty snapshot")
        } catch {}
        chmod(tree, 0o755)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree + "/src/a.txt"), "plaintext intact")
    }

    func testTurningEncryptionOffAndOnAgainEncryptsTheNewCheckpoints() async throws {
        let job = fixture.job
        try fixture.write("a.txt", "alpha")
        let runner = BackupRunner()
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }      // checkpoint 1
        try await makeRepo(for: job, password: "pw")
        try await runner.migrateToEncrypted(job: job, password: "pw") { _, _ in }

        // Encryption off: plaintext passes start a new history — at checkpoint 1 again.
        try fixture.write("a.txt", "beta!")
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }
        XCTAssertEqual(try fixture.store().checkpoints().map(\.seq), [1])
        try await runner.migrateToEncrypted(job: job, password: "pw") { _, _ in }   // and on again

        let points = try await runner.history(for: job).points
        XCTAssertEqual(points.map(\.isBrowsable), [false, false], "the new checkpoint 1 is encrypted, not taken for the old")
        guard case let .encryptedSnapshot(newest) = try XCTUnwrap(points.first).source else { return XCTFail() }
        let backend = try LocalBackend(root: BackupRunner.jobRoot(for: job).appendingPathComponent("repo"))
        let (config, keys) = try await RepoManager.unlock(backend: backend, password: Data("pw".utf8))
        let restored = fixture.root.appendingPathComponent("restored", isDirectory: true)
        try await DedupEngine(backend: backend, keys: keys, chunker: config.chunker).restore(snapshotID: newest, to: restored)
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("src/a.txt"), encoding: .utf8), "beta!")
    }

    func testMigrationKeepsSourcesSinceRemovedFromTheJob() async throws {
        let other = fixture.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("bravo".utf8).write(to: other.appendingPathComponent("b.txt"))
        var both = fixture.job
        both.sources = [fixture.source, other]
        try fixture.write("a.txt", "alpha")
        try fixture.pass(at: 0, job: both)                        // checkpoint 1 holds src and other
        try fixture.pass(at: 16, force: true)                     // other dropped from the job: checkpoint 2

        try await makeRepo(for: fixture.job, password: "pw")
        let runner = BackupRunner()
        try await runner.migrateToEncrypted(job: fixture.job, password: "pw") { _, _ in }
        let encrypted = try await runner.history(for: fixture.job).points.sorted { $0.time < $1.time }
        guard case let .encryptedSnapshot(first) = try XCTUnwrap(encrypted.first).source else { return XCTFail() }

        let backend = try LocalBackend(root: BackupRunner.jobRoot(for: fixture.job).appendingPathComponent("repo"))
        let (config, keys) = try await RepoManager.unlock(backend: backend, password: Data("pw".utf8))
        let restored = fixture.root.appendingPathComponent("restored", isDirectory: true)
        try await DedupEngine(backend: backend, keys: keys, chunker: config.chunker).restore(snapshotID: first, to: restored)
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("src/a.txt"), encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("other/b.txt"), encoding: .utf8), "bravo",
                       "checkpoint 1 still had the removed source")
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
