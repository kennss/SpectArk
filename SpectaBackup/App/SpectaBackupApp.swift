//
//  @file        SpectaBackupApp.swift
//  @description SwiftUI app entry point for SpectArk. Declares the dashboard Window and the
//               menu-bar dropdown (MenuBarExtra, .window style). The shared AppModel is created
//               here and injected into both scenes.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Scenes: a single `Window` (id "dashboard") plus a `MenuBarExtra`. Not WindowGroup — backup
//    config is a single document-less app surface, so one window is correct.
//  - AppModel is @MainActor @Observable (Swift 6 style); it owns the coordinator/metrics once
//    those services land. For now it is a thin placeholder so the app launches.
//

import SwiftUI

@main
struct SpectaBackupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate   // launch, sleep and quit hooks
    @State private var model = AppModel()
    @AppStorage("spectabackup.appearance") private var appearance = "system"

    var body: some Scene {
        // MARK: - Dashboard window (main surface)
        Window("SpectArk", id: AppModel.dashboardWindowID) {
            DashboardView()
                .environment(model)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            // Standard "Check for Updates…" under the app menu (Sparkle).
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
                    .disabled(!UpdaterController.shared.canCheck)
            }
        }

        // MARK: - Menu-bar dropdown (status + quick controls)
        MenuBarExtra("SpectArk", systemImage: "externaldrive.fill") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }

    /// App appearance override from General settings (nil = follow the system).
    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
