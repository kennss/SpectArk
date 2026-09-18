//
//  @file        AppRuntimeTests.swift
//  @description Guards against the test host acting on the developer's real backups: the host process
//               must be detected as a unit-test host, and its AppModel must start with no jobs loaded
//               from the real config and nothing scheduled.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import XCTest
@testable import SpectaBackup

@MainActor
final class AppRuntimeTests: XCTestCase {

    func testThisProcessIsRecognizedAsATestHost() {
        XCTAssertTrue(AppRuntime.isUnitTestHost)
    }

    func testTestHostAppModelDoesNotLoadRealJobs() {
        let model = AppModel()
        XCTAssertTrue(model.coordinator.jobs.isEmpty, "the test host must never load the real config.json")
        XCTAssertFalse(model.coordinator.anyRunning)
    }
}
