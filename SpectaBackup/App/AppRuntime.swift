//
//  @file        AppRuntime.swift
//  @description Facts about how this process was launched that change what the app may do at startup.
//               Today: whether it is the host app of a unit-test run.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - The unit tests are hosted by SpectArk.app itself (TEST_HOST in project.yml), so every test run
//    launches the full app. Without this check that debug-signed copy loaded the developer's REAL
//    config.json, started watchers and backup passes on the real sources, deleted "orphaned" catalog
//    rows on the real destinations (including the row of a pass the installed SpectArk was running),
//    started Sparkle, and — asking for Desktop access with a different code signature — overwrote the
//    installed SpectArk's privacy grant (seen 2026-09-18). A test host must start none of that.
//  - Xcode and xcodebuild put the XCTest configuration into the host app's environment; different
//    Xcode versions use different keys, so any of them counts.
//

import Foundation

enum AppRuntime {
    /// True when this process hosts a unit-test run.
    static let isUnitTestHost: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }()
}
