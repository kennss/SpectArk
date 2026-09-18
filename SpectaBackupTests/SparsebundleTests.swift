//
//  @file        SparsebundleTests.swift
//  @description Integration test for SparsebundleManager: create an APFS sparsebundle on a simulated
//               destination, attach it, confirm the inside is APFS (written directly), write/read a
//               file, detach, and confirm the image persists while the mount point is gone.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Uses real hdiutil; the image's own volume is APFS, so backups inside it are written directly.
//

import XCTest
@testable import SpectaBackup

final class SparsebundleTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-sparse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSparsebundleRoundTripAndInnerCloneStrategy() async throws {
        let dest = tmp.appendingPathComponent("nas-sim", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let attachment = try SparsebundleManager.attach(at: dest, maxSizeBytes: 200 * 1024 * 1024, readOnly: false)
        var detached = false
        defer { if !detached { SparsebundleManager.detach(attachment) } }

        // Mounted, and inside the image it's APFS → written directly.
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.mountPoint.path))
        let innerCaps = try DestinationProbe.probe(destination: attachment.mountPoint)
        XCTAssertEqual(innerCaps.strategy, .direct)

        // Write & read inside the image.
        let file = attachment.mountPoint.appendingPathComponent("hello.txt")
        try "inside-image".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "inside-image")

        SparsebundleManager.detach(attachment)
        detached = true

        // After detach the mount point is gone, but the image persists on the "NAS".
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.mountPoint.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(SparsebundleManager.imageName).path))
    }
}
