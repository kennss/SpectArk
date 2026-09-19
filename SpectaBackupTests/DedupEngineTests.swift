//
//  @file        DedupEngineTests.swift
//  @description End-to-end tests for the encrypted dedup engine: back up a source tree (files,
//               subdirectory, multi-chunk large file, symlink) then restore it in a fresh engine and
//               compare bytes/structure; verify an unchanged re-backup reuses content-addressed
//               trees (no new tree objects); and that a restored file gets its modification time back to
//               the nanosecond, a time before 1970 included, and its permissions.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-30
//  @lastUpdated 2026-09-19
//

import XCTest
import Darwin
@testable import SpectaBackup

final class DedupEngineTests: XCTestCase {

    private var tmp: URL!
    private let keys = RepoKeys.generate()

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeEngine(_ repo: URL) throws -> DedupEngine {
        DedupEngine(backend: try LocalBackend(root: repo), keys: keys,
                    chunker: FastCDC(minSize: 64, avgSize: 256, maxSize: 1024))
    }

    private let bigFile = Data((0..<5000).map { UInt8($0 % 251) })

    private func buildSource() throws -> URL {
        let src = tmp.appendingPathComponent("src")
        let sub = src.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: src.appendingPathComponent("a.txt"))
        try bigFile.write(to: sub.appendingPathComponent("big.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: src.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        return src
    }

    func testBackupRestoreRoundTrip() async throws {
        let src = try buildSource()
        let repo = tmp.appendingPathComponent("repo")

        let writer = try makeEngine(repo)
        let snapshot = try await writer.backUp(sources: [src], snapshotID: "s1", now: 1000, exclusions: .includeEverything,
                                   toleratingVanishedEntries: false).snapshot
        XCTAssertEqual(snapshot.fileCount, 2)

        let dst = tmp.appendingPathComponent("dst")
        let reader = try makeEngine(repo)
        try await reader.restore(snapshotID: "s1", to: dst)

        // Each source is restored under a subdirectory named after its lastPathComponent ("src").
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("src/a.txt")), Data("alpha".utf8))
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("src/sub/big.bin")), bigFile)
        let linkTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: dst.appendingPathComponent("src/link").path)
        XCTAssertEqual(linkTarget, "a.txt")
    }

    func testJobExclusionsApply() async throws {
        let src = try buildSource()
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data("dep".utf8).write(to: src.appendingPathComponent("node_modules/pkg/index.js"))
        try Data("finder".utf8).write(to: src.appendingPathComponent(".DS_Store"))
        let repo = tmp.appendingPathComponent("repo")

        let snapshot = try await makeEngine(repo).backUp(sources: [src], snapshotID: "s1", now: 1000,
                                                         exclusions: BackupExclusions(skipsBuildArtifacts: true),
                                                         toleratingVanishedEntries: true).snapshot
        XCTAssertEqual(snapshot.fileCount, 2, "same two files as without the excluded entries")

        let dst = tmp.appendingPathComponent("dst")
        try await makeEngine(repo).restore(snapshotID: "s1", to: dst)
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("src/a.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("src/node_modules").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("src/.DS_Store").path))
    }

    func testUnchangedReBackupReusesTrees() async throws {
        let src = try buildSource()
        let repo = tmp.appendingPathComponent("repo")
        let backend = try LocalBackend(root: repo)
        let engine = DedupEngine(backend: backend, keys: keys,
                                 chunker: FastCDC(minSize: 64, avgSize: 256, maxSize: 1024))

        _ = try await engine.backUp(sources: [src], snapshotID: "s1", now: 1000, exclusions: .includeEverything,
                                   toleratingVanishedEntries: false)
        let treesAfterFirst = try await backend.list(prefix: "trees").count

        _ = try await engine.backUp(sources: [src], snapshotID: "s2", now: 2000, exclusions: .includeEverything,
                                   toleratingVanishedEntries: false)
        let treesAfterSecond = try await backend.list(prefix: "trees").count

        XCTAssertEqual(treesAfterFirst, treesAfterSecond, "unchanged dirs must reuse content-addressed trees")
        XCTAssertGreaterThan(treesAfterFirst, 0)
    }

    /// A fresh engine (new backup session) must load the blob index before backing up, or it re-stores
    /// every blob instead of deduplicating against what's already in the repo.
    func testNewSessionDedupsAgainstExistingBlobs() async throws {
        let src = try buildSource()
        let repo = tmp.appendingPathComponent("repo")
        let backend = try LocalBackend(root: repo)
        let chunker = FastCDC(minSize: 64, avgSize: 256, maxSize: 1024)

        let session1 = DedupEngine(backend: backend, keys: keys, chunker: chunker)
        _ = try await session1.backUp(sources: [src], snapshotID: "s1", now: 1000, exclusions: .includeEverything,
                                   toleratingVanishedEntries: false)
        let packsAfterFirst = try await backend.list(prefix: "data").count

        let session2 = DedupEngine(backend: backend, keys: keys, chunker: chunker)
        try await session2.open()   // without this, identical data would be re-stored
        _ = try await session2.backUp(sources: [src], snapshotID: "s2", now: 2000, exclusions: .includeEverything,
                                   toleratingVanishedEntries: false)
        let packsAfterSecond = try await backend.list(prefix: "data").count

        XCTAssertEqual(packsAfterFirst, packsAfterSecond,
                       "a new session must dedup identical data — no new packs should be written")
    }

    // MARK: - Metadata

    private func stat(_ path: String) -> Darwin.stat {
        var st = Darwin.stat()
        lstat(path, &st)
        return st
    }

    private func setModified(_ path: String, seconds: Int, nanoseconds: Int) {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
        utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
    }

    func testARestoredFileGetsItsModificationTimeAndPermissionsBack() async throws {
        let src = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let recent = src.appendingPathComponent("recent.txt").path
        let ancient = src.appendingPathComponent("ancient.txt").path
        try Data("recent".utf8).write(to: URL(fileURLWithPath: recent))
        try Data("ancient".utf8).write(to: URL(fileURLWithPath: ancient))
        setModified(recent, seconds: 1_600_000_000, nanoseconds: 123_456_789)
        setModified(ancient, seconds: -86_400, nanoseconds: 500_000_000)   // 1969-12-31
        chmod(recent, 0o640)

        let repo = tmp.appendingPathComponent("repo")
        try await makeEngine(repo).backUp(sources: [src], snapshotID: "s1", now: 1000, exclusions: .includeEverything,
                                          toleratingVanishedEntries: false)
        let dst = tmp.appendingPathComponent("dst")
        try await makeEngine(repo).restore(snapshotID: "s1", to: dst)

        let restoredRecent = stat(dst.appendingPathComponent("src/recent.txt").path)
        XCTAssertEqual(restoredRecent.st_mtimespec.tv_sec, 1_600_000_000)
        XCTAssertEqual(restoredRecent.st_mtimespec.tv_nsec, 123_456_789, "to the nanosecond")
        XCTAssertEqual(restoredRecent.st_mode & 0o7777, 0o640)
        let restoredAncient = stat(dst.appendingPathComponent("src/ancient.txt").path)
        XCTAssertEqual(restoredAncient.st_mtimespec.tv_sec, -86_400)
        XCTAssertEqual(restoredAncient.st_mtimespec.tv_nsec, 500_000_000)
    }
}
