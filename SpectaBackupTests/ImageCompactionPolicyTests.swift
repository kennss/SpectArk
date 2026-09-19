//
//  @file        ImageCompactionPolicyTests.swift
//  @description When an idle NAS image is compacted (ImageLease): once its gap — what the share holds beyond
//               the volume's use — has grown the threshold past the baseline a compaction left; a compaction
//               that left a gap past the threshold is followed up a day later, and a follow-up that gives
//               back less than the threshold settles the baseline; a failed one is tried again a day later;
//               the baseline follows a shrinking gap down; the ledger keeps all this across launches, per
//               image.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Sizes are in GiB (`g`) and MiB (`m`); the threshold is 1 GiB, as in the app.
//

import XCTest
@testable import SpectaBackup

final class ImageCompactionPolicyTests: XCTestCase {

    private let g: Int64 = 1 << 30
    private let m: Int64 = 1 << 20
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var day: TimeInterval { ImageLease.compactionFollowUpInterval }

    private func trigger(_ gap: Int64, _ record: CompactionRecord?, at time: Date? = nil) -> ImageLease.CompactionTrigger? {
        ImageLease.compactionTrigger(gap: gap, record: record, threshold: g, now: time ?? now)
    }

    private func after(_ trigger: ImageLease.CompactionTrigger, left: Int64, given: Int64, succeeded: Bool = true,
                       previous: CompactionRecord? = nil) -> CompactionRecord {
        ImageLease.record(afterCompacting: trigger, previous: previous, left: left, given: given,
                          succeeded: succeeded, threshold: g, now: now)
    }

    func testAGapIsCompactedOnceItHasGrownTheThresholdPastItsBaseline() {
        XCTAssertNil(trigger(g / 2, nil), "not worth it")
        XCTAssertEqual(trigger(g + g / 5, nil), .grown, "nothing known: measured from nothing")
        let settled = CompactionRecord(baseline: g + g / 10, compacted: now, followUp: nil)
        XCTAssertNil(trigger(g + g / 5, settled), "the image's own gap, plus a little")
        XCTAssertEqual(trigger(2 * g + g / 5, settled), .grown)
    }

    func testAFollowUpIsDueFromItsTime() {
        let pending = CompactionRecord(baseline: g + g / 10, compacted: now, followUp: now.addingTimeInterval(day))
        XCTAssertNil(trigger(g + g / 5, pending, at: now.addingTimeInterval(day - 60)))
        XCTAssertEqual(trigger(g + g / 5, pending, at: now.addingTimeInterval(day)), .followUp)
        XCTAssertNil(trigger(g / 2, pending, at: now.addingTimeInterval(day)), "too little left to be worth it")
    }

    func testACompactionThatLeftAGapIsFollowedUpOnceAndThenSettles() {
        // Measured on the NAS image: 1.2 GB held beyond use, 72 MB given back.
        let first = after(.grown, left: g + g / 10, given: 72 * m)
        XCTAssertEqual(first.baseline, g + g / 10)
        XCTAssertEqual(first.compacted, now)
        XCTAssertEqual(first.followUp, now.addingTimeInterval(day), "APFS may not have released it yet")

        let settled = after(.followUp, left: g + g / 10, given: 3 * m, previous: first)
        XCTAssertNil(settled.followUp, "what is left is the image's own")
        XCTAssertEqual(settled.baseline, g + g / 10)

        let releasing = after(.followUp, left: 2 * g, given: 3 * g, previous: first)
        XCTAssertEqual(releasing.followUp, now.addingTimeInterval(day), "APFS was still releasing: again")

        XCTAssertNil(after(.grown, left: 30 * m, given: 5 * g).followUp, "all of it given back")
    }

    func testAFailedCompactionIsTriedAgainADayLater() {
        let previous = CompactionRecord(baseline: g / 10, compacted: now.addingTimeInterval(-7 * day), followUp: nil)
        let failed = after(.grown, left: 3 * g, given: 0, succeeded: false, previous: previous)
        XCTAssertEqual(failed.baseline, 3 * g, "not tried again at every detach")
        XCTAssertEqual(failed.followUp, now.addingTimeInterval(day))
        XCTAssertEqual(failed.compacted, previous.compacted, "it did not run through")
        XCTAssertEqual(trigger(3 * g, failed, at: now.addingTimeInterval(day)), .followUp)
    }

    func testTheBaselineFollowsAShrinkingGapDown() {
        let record = CompactionRecord(baseline: g + g / 10, compacted: now, followUp: nil)
        let lowered = ImageLease.lowered(record, toGap: g / 5)
        XCTAssertEqual(lowered?.baseline, g / 5)
        XCTAssertNil(ImageLease.lowered(record, toGap: 2 * g), "a growing gap is growth, not a baseline")
        XCTAssertNil(ImageLease.lowered(nil, toGap: g / 5))
        // Freed after the gap shrank: growth counts from the lower baseline.
        XCTAssertEqual(trigger(g / 5 + g + g / 10, lowered), .grown)
    }

    func testTheLedgerKeepsRecordsAcrossLaunchesPerImage() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCompactionPolicyTests-\(UUID().uuidString)/ImageCompaction.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let record = CompactionRecord(baseline: g, compacted: now, followUp: now.addingTimeInterval(day))
        CompactionLedger(file: file).set(record, for: "volume-a")

        let relaunched = CompactionLedger(file: file)
        XCTAssertEqual(relaunched.record(for: "volume-a"), record)
        XCTAssertNil(relaunched.record(for: "volume-b"), "a new image in the same place starts afresh")
        relaunched.forget("volume-a")
        XCTAssertNil(CompactionLedger(file: file).record(for: "volume-a"))
    }
}
