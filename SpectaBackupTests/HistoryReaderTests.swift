//
//  @file        HistoryReaderTests.swift
//  @description History engine, phase 2 — browse and restore: a folder listed as it was at each
//               checkpoint (deleted items still shown there, kind changes, current/), and restoring files
//               and whole folders from an old checkpoint with the conflict policies; a path that did not
//               exist at the checkpoint is reported, not invented.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import XCTest
@testable import SpectaBackup

final class HistoryReaderTests: XCTestCase {

    private var fixture: HistoryFixture!
    private var reader: HistoryReader { HistoryReader(layout: fixture.layout) }
    private var target: URL { fixture.root.appendingPathComponent("restore", isDirectory: true) }

    override func setUpWithError() throws { fixture = try HistoryFixture() }
    override func tearDownWithError() throws { fixture.remove() }

    /// Checkpoint 1: a.txt=v1, docs/b.txt, x (file). Checkpoint 2: a.txt=v2, docs/ deleted, x now a folder.
    private func buildHistory() throws {
        try fixture.write("a.txt", "v1")
        try fixture.write("docs/b.txt", "bravo")
        try fixture.write("x", "was a file")
        try fixture.pass(at: 0)
        try fixture.write("a.txt", "v2-")
        try fixture.delete("docs")
        try fixture.delete("x")
        try fixture.write("x/inner.txt", "now a folder")
        try fixture.pass(at: 16)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func testListingFollowsTheCheckpoint() throws {
        try buildHistory()
        XCTAssertEqual(try reader.checkpoints().map(\.seq), [1, 2])
        XCTAssertEqual(try reader.list("", at: 1).map(\.name), ["src"])

        let old = try reader.list("src", at: 1)
        XCTAssertEqual(old.map(\.name), ["a.txt", "docs", "x"])
        XCTAssertEqual(old.first { $0.name == "x" }?.kind, .file)
        XCTAssertEqual(try reader.list("src/docs", at: 1).map(\.name), ["b.txt"])

        let new = try reader.list("src", at: 2)
        XCTAssertEqual(new.map(\.name), ["a.txt", "x"])
        XCTAssertEqual(new.first { $0.name == "x" }?.kind, .directory)
        XCTAssertEqual(try reader.list("src", at: nil).map(\.name), ["a.txt", "x"], "current/")
    }

    func testRestoreAFileAndAFolderFromAnOldCheckpoint() throws {
        try buildHistory()
        let outcome = try reader.restore(sourceName: "src", relPaths: ["a.txt", "docs"], at: 1,
                                         to: target, conflict: .overwrite)
        XCTAssertEqual(outcome.restored, 2)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(read(target.appendingPathComponent("a.txt")), "v1")
        XCTAssertEqual(read(target.appendingPathComponent("docs/b.txt")), "bravo")
    }

    func testRestoreHonoursConflictPolicies() throws {
        try buildHistory()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: target.appendingPathComponent("a.txt"))

        let skipped = try reader.restore(sourceName: "src", relPaths: ["a.txt"], at: 1, to: target, conflict: .skip)
        XCTAssertEqual(skipped.skipped, 1)
        XCTAssertEqual(read(target.appendingPathComponent("a.txt")), "mine")

        _ = try reader.restore(sourceName: "src", relPaths: ["a.txt"], at: 1, to: target, conflict: .keepBoth)
        XCTAssertEqual(read(target.appendingPathComponent("a.txt")), "mine")
        XCTAssertEqual(read(target.appendingPathComponent("a (restored).txt")), "v1")
    }

    func testPathMissingAtTheCheckpointIsReported() throws {
        try buildHistory()
        let outcome = try reader.restore(sourceName: "src", relPaths: ["docs"], at: 2, to: target, conflict: .overwrite)
        XCTAssertEqual(outcome.failed, ["docs"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("docs").path))
    }
}
