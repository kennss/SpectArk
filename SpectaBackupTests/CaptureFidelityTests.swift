//
//  @file        CaptureFidelityTests.swift
//  @description What the history engine's mirror preserves and refuses: permissions, xattrs and the
//               modification time of files, symlinks copied as links (never followed); Git lock files
//               never backed up; a future-dated file (camera clock, extracted archive) copied rather than
//               deferred forever; an entry SpectArk cannot read failing the pass — keeping the
//               previous backup and sealing nothing — instead of silently dropping out of the backup; and a
//               file locked in Finder backed up, replaced and removed like any other, its lock recorded and
//               put back on restore.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
//

import Darwin
import XCTest
@testable import SpectaBackup

final class CaptureFidelityTests: XCTestCase {

    private var fixture: HistoryFixture!

    override func setUpWithError() throws { fixture = try HistoryFixture() }
    override func tearDownWithError() throws { fixture?.remove() }

    func testMetadataAndSymlinksArePreserved() throws {
        try fixture.write("data.bin", "\u{DE}\u{AD}")
        let file = fixture.source.appendingPathComponent("data.bin").path
        XCTAssertEqual(chmod(file, 0o640), 0)
        let xname = "com.calidalab.spectabackup.kind"
        let xval: [UInt8] = [0x42]
        _ = xval.withUnsafeBytes { setxattr(file, xname, $0.baseAddress, $0.count, 0, 0) }
        try FileManager.default.createSymbolicLink(atPath: fixture.source.appendingPathComponent("link").path,
                                                   withDestinationPath: "data.bin")
        try fixture.pass(at: 0)

        let mirrored = fixture.layout.current("src/data.bin")
        var source = Darwin.stat(), copy = Darwin.stat()
        XCTAssertEqual(lstat(file, &source), 0)
        XCTAssertEqual(lstat(mirrored, &copy), 0)
        XCTAssertEqual(copy.st_mode & 0o777, 0o640)
        XCTAssertEqual(copy.st_mtimespec.tv_sec, source.st_mtimespec.tv_sec)
        XCTAssertEqual(copy.st_mtimespec.tv_nsec, source.st_mtimespec.tv_nsec)
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBytes { getxattr(mirrored, xname, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(buf[0], 0x42)

        let link = fixture.layout.current("src/link")
        XCTAssertEqual(lstat(link, &copy), 0)
        XCTAssertEqual(copy.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "data.bin")
        XCTAssertEqual(try fixture.store().entry(at: "src/link")?.kind, .symlink)
        try fixture.assertConsistent()
    }

    func testALockedFileIsBackedUpReplacedRemovedAndRestoredWithItsLock() throws {
        let immutable = UInt32(UF_IMMUTABLE)
        let doc = fixture.source.appendingPathComponent("doc.txt").path
        try fixture.write("doc.txt", "v1")
        XCTAssertEqual(lchflags(doc, immutable), 0)
        try fixture.pass(at: 0)
        XCTAssertEqual(try Syscalls.flags(of: fixture.layout.current("src/doc.txt")) & Syscalls.lockFlags, 0,
                       "a locked copy could never be replaced or retired")
        XCTAssertEqual(try fixture.store().entry(at: "src/doc.txt")?.lockFlags, immutable)

        XCTAssertEqual(lchflags(doc, 0), 0)
        try fixture.write("doc.txt", "v2-")
        XCTAssertEqual(lchflags(doc, immutable), 0)
        try fixture.pass(at: 16)                                  // v1 retires into versions/
        XCTAssertEqual(fixture.mirror("doc.txt"), "v2-")

        let target = fixture.root.appendingPathComponent("restored", isDirectory: true)
        let outcome = try HistoryReader(layout: fixture.layout)
            .restore(sourceName: "src", relPaths: ["doc.txt"], at: 1, to: target, conflict: .overwrite)
        XCTAssertEqual(outcome.restored, 1)
        let restored = target.appendingPathComponent("doc.txt").path
        XCTAssertEqual(try String(contentsOfFile: restored, encoding: .utf8), "v1")
        XCTAssertEqual(try Syscalls.flags(of: restored) & Syscalls.lockFlags, immutable, "the lock comes back")

        XCTAssertEqual(lchflags(doc, 0), 0)
        try fixture.delete("doc.txt")
        try fixture.pass(at: 32)
        XCTAssertNil(fixture.mirror("doc.txt"))
        try fixture.assertConsistent()
    }

    func testGitLockFilesAreNeverBackedUp() throws {
        try fixture.write(".git/HEAD", "ref: refs/heads/main")
        try fixture.write(".git/index.lock", "")
        try fixture.pass(at: 0)
        XCTAssertEqual(fixture.mirror(".git/HEAD"), "ref: refs/heads/main")
        XCTAssertNil(fixture.mirror(".git/index.lock"))
    }

    func testAFutureDatedFileIsCopiedNotDeferred() throws {
        try fixture.write("from-camera.jpg", "jpeg")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(86_400)],
                                              ofItemAtPath: fixture.source.appendingPathComponent("from-camera.jpg").path)
        let outcome = try fixture.pass(at: 0, quietWindow: RerunPolicy.quietWindow)
        XCTAssertEqual(outcome.deferredCount, 0)
        XCTAssertEqual(fixture.mirror("from-camera.jpg"), "jpeg")
    }

    func testAnUnreadableEntryFailsThePassInsteadOfDroppingOut() throws {
        try fixture.write("locked/s.txt", "secret")
        try fixture.pass(at: 0)

        // Listable but not searchable: its entries can't be stat'ed (EACCES).
        let locked = fixture.source.appendingPathComponent("locked").path
        XCTAssertEqual(chmod(locked, 0o444), 0)
        defer { chmod(locked, 0o755) }
        try fixture.write("other.txt", "new")
        XCTAssertThrowsError(try fixture.pass(at: 24 * 60 + 1), "the daily full scan reads every folder")

        XCTAssertEqual(fixture.mirror("locked/s.txt"), "secret", "the previous backup is kept")
        XCTAssertEqual(try fixture.store().checkpoints().map(\.seq), [1], "nothing sealed without it")
        XCTAssertEqual(chmod(locked, 0o755), 0)
        try fixture.pass(at: 24 * 60 + 2)
        XCTAssertEqual(fixture.mirror("other.txt"), "new")
        try fixture.assertConsistent()
    }
}
