//
//  @file        LoginItem.swift
//  @description "Open at login": registers SpectArk as the user's login item (SMAppService.mainApp) so
//               realtime backup resumes after a restart without anyone reopening the app, and starts
//               quietly — menu bar only, no window, no Dock icon — when the system opened it at login.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Never turned on without the user: macOS announces every new login item, and a backup app that adds
//    itself silently would earn that notification's distrust. The dashboard offers it (once, dismissible)
//    while a job runs on changes; Settings ▸ General holds the switch.
//  - `status` can change behind our back (System Settings ▸ General ▸ Login Items), so it is re-read
//    whenever a surface that shows it appears.
//  - `.requiresApproval`: registered, but the user switched it off in System Settings; only they can
//    switch it back on there.
//  - A unit-test host never registers anything (AppRuntime).
//  - Launched at login = the launch's Apple event is an "open application" event marked
//    keyAELaunchedAsLogInItem; it is read in applicationDidFinishLaunching (AppDelegate), while it is the
//    current event.
//

import AppKit
import ServiceManagement

@MainActor
@Observable
final class LoginItem {

    static let shared = LoginItem()

    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    /// The last attempt to change it failed (shown in Settings).
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        guard !AppRuntime.isUnitTestHost else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The start of this run of the app, as the system reported it.
@MainActor
enum AppLaunch {

    /// The system opened SpectArk at login (read once, at launch).
    private(set) static var startedAtLogin = false
    /// The dashboard window SwiftUI opens at launch is still to be put away (quiet start).
    private static var quietStartPending = false

    /// Call from applicationDidFinishLaunching, while the launch event is the current Apple event.
    static func recordLaunch() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        startedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == OSType(keyAELaunchedAsLogInItem)
        guard startedAtLogin, !AppRuntime.isUnitTestHost else { return }
        quietStartPending = true
        NSApp.setActivationPolicy(.accessory)   // menu bar only until the dashboard is opened
    }

    /// True once, for the window SwiftUI shows at a quiet start: it should close right away.
    static func consumeQuietStart() -> Bool {
        defer { quietStartPending = false }
        return quietStartPending
    }

    /// The dashboard is being shown to the user: be a regular app (Dock icon, app menu) and come forward.
    static func dashboardShown() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
