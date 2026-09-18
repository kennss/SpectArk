//
//  @file        AppModel.swift
//  @description Root app model for SpectaBackup. Owns shared, observable app state and (later) the
//               BackupCoordinator and Metrics services. Injected into all scenes via @Environment.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - @MainActor @Observable singleton-style model (Swift 6). `dashboardWindowID` is the stable id
//    used by openWindow(id:) from the menu bar.
//  - When the process is a unit-test host (AppRuntime), nothing live starts: the coordinator neither
//    reads nor writes the real job config, and no history cleanup, watcher or pass is started.
//

import Foundation

@MainActor
@Observable
final class AppModel {
    /// Stable identifier for the dashboard `Window` scene; used by `openWindow(id:)`.
    static let dashboardWindowID = "dashboard"

    /// Owner of the job list and per-job runtime state, observed by the dashboard and menu bar.
    let coordinator = BackupCoordinator(usesSavedJobs: !AppRuntime.isUnitTestHost)

    /// App-wide settings, including the defaults applied to newly created jobs.
    let settings = AppSettings()

    init() {
        guard !AppRuntime.isUnitTestHost else { return }
        coordinator.refreshAllHistory()
        coordinator.startMonitoring()
    }
}
