//
//  @file        DestinationIdentityTests.swift
//  @description DestinationIdentity: a job's destination folder is found by the marker it carries, wherever
//               its volume is mounted — at a new path after a remount, or one folder deeper; another
//               destination at the job's old path is never used; a new job's folder is marked when it is
//               created, a job from before identities where its own backups are (on another volume too; a
//               SpectArk image counts only with the job's folder inside), and jobs marking one folder at once
//               end up with one ID; a lost marker is put back only there, an unreadable folder is never
//               taken for an unmarked one, and a deeper mount seen once keeps the way back. Jobs saved before
//               identities decode and keep working.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Temp folders stand in for mounted volumes; `volumes` and `volumeRoot` are handed to the resolver.
//

import XCTest
@testable import SpectaBackup

final class DestinationIdentityTests: XCTestCase {

    private var root: URL!
    private var volumeA: URL!
    private var volumeB: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-identity-\(UUID().uuidString)", isDirectory: true)
        volumeA = root.appendingPathComponent("home", isDirectory: true)
        volumeB = root.appendingPathComponent("home-1", isDirectory: true)
        for volume in [volumeA!, volumeB!] {
            try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func resolve(_ job: BackupJob, volumes: [URL]? = nil,
                         network: [URL] = []) -> DestinationIdentity.Resolution {
        let mounted = volumes ?? [volumeA!, volumeB!]
        let listed = mounted.map { DestinationIdentity.Volume(url: $0, isLocal: !network.contains($0)) }
        return DestinationIdentity.resolve(job, volumes: { listed }, volumeRoot: { url in
            mounted.first { url.standardizedFileURL.path == $0.path || url.standardizedFileURL.path.hasPrefix($0.path + "/") }
        })
    }

    /// The place a resolution found, or nil.
    private func place(_ resolution: DestinationIdentity.Resolution) -> DestinationIdentity.Location? {
        if case let .found(location) = resolution { return location }
        return nil
    }

    private func folder(_ path: String, in volume: URL) throws -> URL {
        let url = volume.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The job's own backups at `folder` (its job folder, as a pass leaves it).
    private func giveBackups(to job: BackupJob, at folder: URL) throws {
        var there = job
        there.destination = folder
        try FileManager.default.createDirectory(at: BackupRunner.jobRoot(for: there), withIntermediateDirectories: true)
    }

    private func markerID(in folder: URL) throws -> UUID? {
        let file = folder.appendingPathComponent(DestinationIdentity.markerName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        struct Marker: Decodable { let id: UUID }
        return try JSONDecoder().decode(Marker.self, from: Data(contentsOf: file)).id
    }

    private func identified(_ job: BackupJob, as resolution: DestinationIdentity.Resolution) -> BackupJob {
        guard let location = place(resolution) else { return job }
        var job = job
        job.record(location)
        return job
    }

    // MARK: - Identifying

    func testAJobIsMarkedWhereItsBackupsAreAndAnotherJobThereSharesTheMark() throws {
        let backup = try folder("Backup", in: volumeA)
        let first = BackupJob(name: "a", sources: [], destination: backup)
        try giveBackups(to: first, at: backup)

        let resolution = resolve(first)
        guard let found = place(resolution) else { return XCTFail("\(resolution)") }
        XCTAssertEqual(found.url, backup)
        XCTAssertEqual(found.subpath, "Backup")
        XCTAssertEqual(found.isLocal, true)
        XCTAssertEqual(try markerID(in: backup), found.id)
        let id = found.id
        XCTAssertEqual(resolve(identified(first, as: resolution)), resolution, "found again by its mark")

        let second = BackupJob(name: "b", sources: [], destination: backup)
        try giveBackups(to: second, at: backup)
        XCTAssertEqual(place(resolve(second))?.id, id, "one folder, one mark")
    }

    func testANewJobsFolderIsMarkedWhenItIsCreated() throws {
        let backup = try folder("Backup", in: volumeA)
        let identity = try DestinationIdentity.identify(newDestination: backup, volumeRoot: { _ in self.volumeA })
        XCTAssertEqual(identity.url, backup)
        XCTAssertEqual(try markerID(in: backup), identity.id)
        XCTAssertEqual(identity.subpath, "Backup")
        let again = try DestinationIdentity.identify(newDestination: backup, volumeRoot: { _ in self.volumeA })
        XCTAssertEqual(again.id, identity.id, "a second job there adopts the mark")
    }

    func testAJobFromBeforeIdentitiesIsFoundOnTheVolumeItsBackupsAreOn() throws {
        // The drive came back as "Backup 1" at upgrade, and another drive took its name.
        let real = try folder("Backup", in: volumeB)
        let impostor = try folder("Backup", in: volumeA)
        let job = BackupJob(name: "old", sources: [], destination: impostor)
        try giveBackups(to: job, at: real)

        let found = place(resolve(job))
        XCTAssertEqual(found?.url.standardizedFileURL.path, real.path)
        XCTAssertEqual(try markerID(in: real), found?.id)
        XCTAssertNil(try markerID(in: impostor), "the folder that took the name is left alone")
    }

    func testJobsMarkingOneFolderAtOnceEndUpWithOneID() async throws {
        let backup = try folder("Backup", in: volumeA)
        let jobs = (0..<8).map { BackupJob(name: "\($0)", sources: [], destination: backup) }
        for job in jobs { try giveBackups(to: job, at: backup) }
        let resolutions = await withTaskGroup(of: DestinationIdentity.Resolution.self) { group in
            for job in jobs { group.addTask { await DestinationIdentity.resolveInBackground(job) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let ids = Set(resolutions.compactMap { resolution -> UUID? in
            if case let .found(location) = resolution { return location.id }
            return nil
        })
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(try markerID(in: backup), ids.first)
    }

    func testAFolderWithoutTheJobsBackupsIsNotMarked() throws {
        let backup = try folder("Backup", in: volumeA)
        let job = BackupJob(name: "new", sources: [], destination: backup)
        // Every job from before identities that ever ran left its backups: none anywhere means its destination
        // is away, whatever folder sits at its path now.
        XCTAssertEqual(resolve(job), .notConnected)
        XCTAssertNil(try markerID(in: backup))
    }

    // MARK: - Finding

    func testARemountedDestinationIsFoundAtItsNewPath() throws {
        let backup = try folder("Backup", in: volumeA)
        let job = BackupJob(name: "nas", sources: [], destination: backup)
        try giveBackups(to: job, at: backup)
        let known = identified(job, as: resolve(job))

        // The share comes back as home-1: the folder (and its mark) are there now, nothing at the old path.
        let moved = volumeB.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.moveItem(at: backup, to: moved)
        let found = place(resolve(known))
        XCTAssertEqual(found?.url.standardizedFileURL.path, moved.path)
        XCTAssertEqual(found?.id, known.destinationID)
        XCTAssertEqual(found?.subpath, "Backup")
    }

    func testAShareMountedOneFolderDeeperIsFound() throws {
        let backup = try folder("home/Backup", in: volumeA)
        let job = BackupJob(name: "nas", sources: [], destination: backup)
        try giveBackups(to: job, at: backup)
        let known = identified(job, as: resolve(job))
        XCTAssertEqual(known.destinationSubpath, "home/Backup")

        // Now the Backup folder itself is what is mounted.
        let mountedDeeper = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.moveItem(at: backup, to: mountedDeeper)
        let deeper = resolve(known, volumes: [volumeB!, mountedDeeper])
        XCTAssertEqual(place(deeper)?.url.standardizedFileURL.path, mountedDeeper.path)
        XCTAssertEqual(place(deeper)?.subpath, "home/Backup", "the longer way is kept")

        // Mounted as before again: still found.
        try FileManager.default.createDirectory(at: volumeA.appendingPathComponent("home"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: mountedDeeper, to: backup)
        XCTAssertEqual(place(resolve(identified(known, as: deeper)))?.url.standardizedFileURL.path, backup.path)
    }

    func testAnotherDestinationAtTheJobsPathIsNeverUsed() throws {
        let backup = try folder("Backup", in: volumeA)
        let job = BackupJob(name: "nas", sources: [], destination: backup)
        try giveBackups(to: job, at: backup)
        let known = identified(job, as: resolve(job))

        // Our share is away; another NAS's share, with a SpectArk image of its own, is mounted under the name.
        try FileManager.default.removeItem(at: backup)
        let other = try folder("Backup", in: volumeA)
        try FileManager.default.createDirectory(at: ImageLease.imageURL(for: other), withIntermediateDirectories: true)
        let otherID = UUID()
        try JSONEncoder().encode(["id": otherID]).write(to: other.appendingPathComponent(DestinationIdentity.markerName))

        XCTAssertEqual(resolve(known), .notConnected)
        XCTAssertEqual(try markerID(in: other), otherID, "left as it was")
    }

    func testALostMarkIsPutBackOnlyWhereTheJobsBackupsAre() throws {
        let backup = try folder("Backup", in: volumeA)
        let job = BackupJob(name: "local", sources: [], destination: backup)
        try giveBackups(to: job, at: backup)
        let known = identified(job, as: resolve(job))
        try FileManager.default.removeItem(at: backup.appendingPathComponent(DestinationIdentity.markerName))   // a cleanup tool

        XCTAssertEqual(place(resolve(known))?.url, backup)
        XCTAssertEqual(try markerID(in: backup), known.destinationID)

        // Without the job's backups, an unmarked folder at its path is nobody's to claim.
        try FileManager.default.removeItem(at: backup)
        let bare = try folder("Backup", in: volumeA)
        XCTAssertEqual(resolve(known), .notConnected)
        XCTAssertNil(try markerID(in: bare))
    }

    func testAFolderThatCannotBeReadIsNeverTakenForUnmarked() throws {
        let backup = try folder("Backup", in: volumeA)
        let job = BackupJob(name: "nas", sources: [], destination: backup)
        try giveBackups(to: job, at: backup)
        let known = identified(job, as: resolve(job))
        try FileManager.default.removeItem(at: backup.appendingPathComponent(DestinationIdentity.markerName))
        chmod(backup.path, 0)
        defer { chmod(backup.path, 0o755) }

        XCTAssertEqual(resolve(known), .notConnected)
        chmod(backup.path, 0o755)
        XCTAssertNil(try markerID(in: backup), "nothing written on a guess")
    }

    func testOnlyVolumesOfTheDestinationsKindAreSearched() throws {
        let backup = try folder("Backup", in: volumeA)
        let job = BackupJob(name: "local", sources: [], destination: backup)
        try giveBackups(to: job, at: backup)
        let known = identified(job, as: resolve(job))
        XCTAssertEqual(known.destinationIsLocal, true)

        // Its drive is away; a network share (a hung one would stall the look) holds a copy of the folder.
        let copy = volumeB.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.copyItem(at: backup, to: copy)
        try FileManager.default.removeItem(at: backup)
        XCTAssertEqual(resolve(known, network: [volumeB!]), .notConnected, "network volumes are not looked at")
        XCTAssertEqual(place(resolve(known))?.url.standardizedFileURL.path, copy.path)
    }

    func testTheMountedVolumesAreListedWithoutHiddenOnes() throws {
        let volumes = DestinationIdentity.mountedVolumes()
        XCTAssertTrue(volumes.contains { $0.url.path == "/" && $0.isLocal }, "the startup volume")
        // A SpectArk NAS image mounts hidden: never a place to look for a destination.
        let lease = ImageLease.shared(for: volumeA)
        defer { lease.detachIfIdle() }
        let mount = try lease.acquire(create: true)
        lease.release(flush: false)
        XCTAssertFalse(DestinationIdentity.mountedVolumes().contains { $0.url.standardizedFileURL.path == mount.path })
    }

    // MARK: - Saved jobs

    func testAJobSavedBeforeIdentitiesDecodesAndKeepsItsIdentityOnceSet() throws {
        // As 1.2.0 saved it (config.json).
        let saved = """
        {"createdAt":804526638.704395,"destination":"file:///Volumes/home/Backup/","encryptionEnabled":false,
         "excludeGlobs":[],"id":"3E9BF210-E572-4994-9AEC-52D21B6BACBB","isEnabled":true,"name":"Old",
         "retention":{"maxTotalBytes":0,"minimumFreeBytes":0,"mode":{"automatic":{}}},
         "sources":["file:///Users/Old/"],"trigger":{"realtime":{}}}
        """
        var job = try JSONDecoder().decode(BackupJob.self, from: Data(saved.utf8))
        XCTAssertNil(job.destinationID)
        XCTAssertNil(job.destinationSubpath)

        job.destinationID = UUID()
        job.destinationSubpath = "Backup"
        let reloaded = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(reloaded.destinationID, job.destinationID)
        XCTAssertEqual(reloaded.destinationSubpath, "Backup")
    }

    // MARK: - NAS images

    func testASpectArkImageIsNoProofWithoutTheJobsFolderInside() throws {
        let backup = try folder("Backup", in: volumeA)
        let ours = BackupJob(name: "ours", sources: [], destination: backup)
        let lease = ImageLease.shared(for: backup)
        defer { lease.detachIfIdle() }
        // Somebody else's NAS image: another job's folder inside, not ours.
        let mount = try lease.acquire(create: true)
        try FileManager.default.createDirectory(
            at: mount.appendingPathComponent("\(SparsebundleManager.jobsFolderName)/\(UUID().uuidString)"),
            withIntermediateDirectories: true)
        lease.release(flush: true)

        lease.detachIfIdle()   // looked into read-only, without the writer lock
        XCTAssertEqual(resolve(ours), .notConnected, "nothing shows these are our backups")
        XCTAssertFalse(lease.isHeld)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent(SparsebundleManager.lockName).path))
        XCTAssertNil(try markerID(in: backup))

        let inside = try lease.acquire(create: false)
        try FileManager.default.createDirectory(
            at: inside.appendingPathComponent("\(SparsebundleManager.jobsFolderName)/\(ours.id.uuidString)"),
            withIntermediateDirectories: true)
        lease.release(flush: true)
        lease.detachIfIdle()
        let found = place(resolve(ours))
        XCTAssertEqual(found?.url, backup)
        XCTAssertEqual(try markerID(in: backup), found?.id)
    }
}
