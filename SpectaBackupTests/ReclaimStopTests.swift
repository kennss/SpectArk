//
//  @file        ReclaimStopTests.swift
//  @description Stopping reclaims at quit and sleep (SparsebundleManager.stopCompactions, ReclaimRegistry):
//               a command under way is interrupted and the stop waits until its reclaim has ended (lock
//               released); once stopped for good nothing starts again, and a command that starts anyway is
//               interrupted at once; a stop for sleep lets the next one start. A real process stands in for
//               `hdiutil compact` (which cancels cleanly on SIGINT — measured by hand, see
//               SparsebundleManager).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//

import XCTest
@testable import SpectaBackup

final class ReclaimStopTests: XCTestCase {

    /// A reclaim that runs `/bin/sleep 30` the way a detach runs `hdiutil compact`, ending when it exits.
    private func reclaim(in registry: ReclaimRegistry, ended: XCTestExpectation) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let id = registry.begin()
        DispatchQueue.global().async {
            defer { registry.end(id); ended.fulfill() }
            guard registry.mayStart(id), (try? process.run()) != nil else { return }
            registry.running(process, for: id)
            process.waitUntilExit()
        }
        return process
    }

    func testAStopInterruptsWhatRunsAndWaitsForItToEnd() {
        let registry = ReclaimRegistry()
        let ended = expectation(description: "the reclaim ended")
        let process = reclaim(in: registry, ended: ended)
        while !process.isRunning { usleep(10_000) }

        let started = Date()
        registry.stop(timeout: 10, forGood: false)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "interrupted, not waited out")
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        wait(for: [ended], timeout: 1)
        XCTAssertTrue(registry.mayStart(UUID()), "after a sleep, the next one may start")
    }

    func testOnceStoppedForGoodNothingRunsAgain() {
        let registry = ReclaimRegistry()
        registry.stop(timeout: 1, forGood: true)
        XCTAssertFalse(registry.mayStart(UUID()))

        // One that got past the check just before the stop is interrupted as soon as it runs.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let id = registry.begin()
        XCTAssertNoThrow(try process.run())
        registry.running(process, for: id)
        process.waitUntilExit()
        registry.end(id)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    }
}
