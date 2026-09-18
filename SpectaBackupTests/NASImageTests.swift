//
//  @file        NASImageTests.swift
//  @description NAS jobs end to end through a real sparsebundle (hdiutil): the timeline, browsing and
//               restore read the job's backups inside the image; the image stays attached while in use and
//               is detached once idle; an image macOS ejected behind the lease is attached again; removing a
//               job's backups gives the space back (the image goes with the last job) — once nothing uses the
//               image, and never by ejecting another volume at its old path; turning encryption on moves a NAS
//               job's plaintext out of the image and stops on a catalog it cannot read.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - A temp folder stands in for the share: a job is an image job when the image exists and the job has
//    no direct layout, whatever the destination's file system — so setUp makes the image first.
//

import XCTest
@testable import SpectaBackup

final class NASImageTests: XCTestCase {

    private var root: URL!
    private var destination: URL!
    private var source: URL!

    private var lease: ImageLease { ImageLease.shared(for: destination) }
    private var imagePath: String { ImageLease.imageURL(for: destination).path }
    private var lockPath: String { destination.appendingPathComponent(SparsebundleManager.lockName).path }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-nas-\(UUID().uuidString)", isDirectory: true)
        destination = root.appendingPathComponent("share", isDirectory: true)
        source = root.appendingPathComponent("src", isDirectory: true)
        for folder in [destination!, source!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // The share's image, as the first pass of a NAS job makes it.
        _ = try lease.acquire(create: true)
        lease.release(flush: false)
        lease.detachIfIdle()
    }

    override func tearDownWithError() throws {
        if let destination { ImageLease.shared(for: destination).detachIfIdle() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeJob(_ name: String = "nas") -> BackupJob {
        BackupJob(name: name, sources: [source], destination: destination)
    }

    private func write(_ rel: String, _ text: String) throws {
        try Data(text.utf8).write(to: source.appendingPathComponent(rel))
    }

    // MARK: - Reading

    func testTheTimelineBrowsingAndRestoreReadTheImage() async throws {
        let job = makeJob()
        try write("a.txt", "alpha")
        let runner = BackupRunner()
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackupRunner.jobRoot(for: job).path),
                       "nothing of the job's is on the share outside the image")

        let history = try await runner.history(for: job)
        let point = try XCTUnwrap(history.points.first)
        XCTAssertEqual(point.source, .checkpoint(seq: 1))

        let session = try BackupRunner.beginBrowsing(job: job)
        let listed = BackupRunner.browser(session: session, point: point, sourceName: "src")?.children(of: "")
        XCTAssertEqual(listed?.map(\.name), ["a.txt"])

        try write("a.txt", "beta!")
        let target = root.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        _ = try await runner.restore(job: job, point: point, sourceName: "src", relPaths: ["a.txt"], to: target,
                                     conflict: .overwrite, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.txt"), encoding: .utf8), "alpha")

        BackupRunner.endBrowsing(session)
        XCTAssertTrue(lease.isHeld, "kept attached for a while after its last use")
        lease.detachIfIdle()
        XCTAssertFalse(lease.isHeld)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath), "the writer lock goes with the attachment")
    }

    func testAnUnreachableDestinationIsNoEmptyTimeline() async throws {
        var job = makeJob()
        job.destination = root.appendingPathComponent("unmounted-share", isDirectory: true)
        do {
            _ = try await BackupRunner().history(for: job)
            XCTFail("the timeline shown must stay")
        } catch {}
    }

    // MARK: - The lease

    func testAnIdleImageIsDetachedAfterItsTimeoutAndNotBefore() async throws {
        let lease = ImageLease(destination: destination, idleTimeout: 0.5)
        defer { lease.detachIfIdle() }
        _ = try lease.acquire(create: false)
        lease.release(flush: true)
        _ = try lease.acquire(create: false)   // back within the timeout: the timer armed before does nothing
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(lease.isHeld, "in use")
        lease.release(flush: false)
        XCTAssertTrue(lease.isHeld, "idle, not yet for long")
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(lease.isHeld)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))
    }

    func testAnImageMacOSEjectedIsAttachedAgain() throws {
        let first = try lease.acquire(create: false)
        lease.release(flush: false)
        try hdiutil(["detach", first.path, "-force"])

        let mount = try lease.acquire(create: false)
        defer { lease.release(flush: true) }
        let probe = mount.appendingPathComponent("probe.txt")
        try Data("x".utf8).write(to: probe)
        XCTAssertEqual(try String(contentsOf: probe, encoding: .utf8), "x")
    }

    // MARK: - Giving the space back

    func testRemovingANASJobsBackupsGivesTheSpaceBack() async throws {
        let first = makeJob("first"), second = makeJob("second")
        try write("a.txt", "alpha")
        let runner = BackupRunner()
        _ = try await runner.run(job: first, forceCheckpoint: true) { _ in }
        _ = try await runner.run(job: second, forceCheckpoint: true) { _ in }

        await runner.deleteJobData(for: first)
        lease.drain()
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath), "the other job's backups are in it")
        XCTAssertFalse(lease.isHeld, "compacted, so detached")
        let removed = try await runner.history(for: first)
        XCTAssertTrue(removed.points.isEmpty)
        let kept = try await runner.history(for: second)
        XCTAssertEqual(kept.points.map(\.source), [.checkpoint(seq: 1)])

        await runner.deleteJobData(for: second)
        lease.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath), "nothing left to keep: the image goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))
    }

    func testTheSpaceIsGivenBackOnceTheImageIsNoLongerInUse() async throws {
        let job = makeJob()
        try write("a.txt", "alpha")
        let runner = BackupRunner()
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }
        let session = try BackupRunner.beginBrowsing(job: job)   // an open restore sheet

        await runner.deleteJobData(for: job)
        lease.drain()
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath), "in use: left alone for now")

        BackupRunner.endBrowsing(session)
        lease.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath), "reclaimed when the last user left")
    }

    func testARemovalLeftHalfwayIsSweptAway() throws {
        let leftover = destination.appendingPathComponent(SparsebundleManager.removingPrefix + SparsebundleManager.imageName + "-x",
                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: leftover.appendingPathComponent("bands"), withIntermediateDirectories: true)
        _ = try lease.acquire(create: false)
        lease.release(flush: false)
        TreeReaper.shared.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testADetachNeverEjectsAnotherVolumeMountedAtTheSamePath() throws {
        let first = try lease.acquire(create: false)
        lease.release(flush: false)
        try hdiutil(["detach", first.path, "-force"])   // macOS ejected it: the share dropped

        // Another image named alike takes the path that is free again.
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherAttachment = try SparsebundleManager.attach(at: other, maxSizeBytes: 0, readOnly: false)
        defer { SparsebundleManager.detach(otherAttachment) }
        guard otherAttachment.mountPoint == first else {
            throw XCTSkip("macOS mounted the other image at \(otherAttachment.mountPoint.path)")
        }

        lease.detachIfIdle()
        XCTAssertFalse(lease.isHeld, "ours is forgotten")
        XCTAssertTrue(SparsebundleManager.isAttached(otherAttachment), "the other volume is left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath), "our lock is released")
    }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testTurningEncryptionOnMovesANASJobsPlaintextOutOfTheImage() async throws {
        let job = makeJob()
        try write("a.txt", "alpha")
        let runner = BackupRunner()
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }
        let before = await runner.plaintextSnapshotCount(for: job)
        XCTAssertEqual(before, 1, "the checkpoint in the image")

        let repo = BackupRunner.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true)
        _ = try await RepoManager.create(backend: try LocalBackend(root: repo), password: Data("pw".utf8))
        try await runner.migrateToEncrypted(job: job, password: "pw") { _, _ in }
        lease.drain()

        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath), "its plaintext was all the image held")
        let points = try await runner.history(for: job).points
        XCTAssertEqual(points.map(\.isBrowsable), [false], "one encrypted point")
        let after = await runner.plaintextSnapshotCount(for: job)
        XCTAssertEqual(after, 0)

        guard case let .encryptedSnapshot(id) = try XCTUnwrap(points.first).source else { return XCTFail() }
        let (config, keys) = try await RepoManager.unlock(backend: try LocalBackend(root: repo), password: Data("pw".utf8))
        let restored = root.appendingPathComponent("restored", isDirectory: true)
        try await DedupEngine(backend: try LocalBackend(root: repo), keys: keys, chunker: config.chunker)
            .restore(snapshotID: id, to: restored)
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("src/a.txt"), encoding: .utf8), "alpha")
    }

    func testAMigrationStopsOnACatalogInTheImageItCannotRead() async throws {
        let job = makeJob()
        try write("a.txt", "alpha")
        let runner = BackupRunner()
        _ = try await runner.run(job: job, forceCheckpoint: true) { _ in }
        let mount = try lease.acquire(create: false)
        let catalog = mount.appendingPathComponent("\(SparsebundleManager.jobsFolderName)/\(job.id.uuidString)/catalog.sqlite")
        try Data(repeating: 0x41, count: 4096).write(to: catalog)   // a 1.1.x catalog, damaged
        lease.release(flush: true)

        let repo = BackupRunner.jobRoot(for: job).appendingPathComponent("repo", isDirectory: true)
        _ = try await RepoManager.create(backend: try LocalBackend(root: repo), password: Data("pw".utf8))
        do {
            try await runner.migrateToEncrypted(job: job, password: "pw") { _, _ in }
            XCTFail("what the catalog records is unknown: nothing may be discarded")
        } catch {}
        lease.drain()
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
        let history = try await runner.history(for: job)
        XCTAssertTrue(history.points.contains { $0.source == .checkpoint(seq: 1) }, "the plaintext is still there")
    }
}
