//
//  @file        FileWalkerTests.swift
//  @description Source walks and destination probing: a folder vanishing mid-walk is skipped in source
//               walks only (walks over backup trees never tolerate it), the source root itself
//               disappearing fails the walk instead of looking like deletions, and a local APFS
//               destination is probed as clone-capable and written directly.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import XCTest
@testable import SpectaBackup

final class FileWalkerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testWalkSkipsAFolderThatVanishesMidWalk() throws {
        func makeTree() throws -> URL {
            let root = tmp.appendingPathComponent("walk-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("gone/deep"), withIntermediateDirectories: true)
            try "x".write(to: root.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
            return root
        }
        // Delete the folder after it was listed but before the walker descends into it.
        let deleteGone: (FileEntry) throws -> Void = { entry in
            if entry.relativePath == "gone" { try FileManager.default.removeItem(at: entry.url) }
        }

        let source = try makeTree()
        var seen: [String] = []
        try FileWalker.walk(root: source, exclusions: BackupExclusions(), toleratingVanishedEntries: true) { entry in
            seen.append(entry.relativePath)
            try deleteGone(entry)
        }
        XCTAssertTrue(seen.contains("keep.txt"))
        XCTAssertFalse(seen.contains("gone/deep"))

        // Walks over backup trees never tolerate a missing entry.
        XCTAssertThrowsError(try FileWalker.walk(root: try makeTree(), exclusions: .includeEverything, visit: deleteGone))
    }

    func testWalkFailsWhenTheSourceRootItselfDisappears() throws {
        // An ejected source volume makes everything "vanish" — that must fail, not look like deletions.
        let root = tmp.appendingPathComponent("walk-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FileWalker.walk(root: root, exclusions: BackupExclusions(),
                                                 toleratingVanishedEntries: true) { entry in
            if entry.relativePath == "a" { try FileManager.default.removeItem(at: root) }
        }) { error in
            guard case FileWalker.WalkError.sourceRootChanged = error else { return XCTFail("\(error)") }
        }
    }

    func testDestinationProbeWritesDirectlyOnLocalAPFS() throws {
        let dest = tmp.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let caps = try DestinationProbe.probe(destination: dest)
        XCTAssertEqual(caps.fileSystem, .apfs)
        XCTAssertTrue(caps.supportsClone)
        XCTAssertEqual(caps.strategy, .direct)
    }
}
