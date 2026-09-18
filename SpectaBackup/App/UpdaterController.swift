//
//  @file        UpdaterController.swift
//  @description Sparkle auto-update wrapper. SpectArk is self-distributed (Developer ID, not the App
//               Store), so it checks a GitHub-Releases appcast for newer signed + notarized DMGs and
//               can install them in place. Reads its config (SUFeedURL / SUPublicEDKey) from Info.plist
//               and verifies each update against the EdDSA public key whose private half lives in the
//               developer's login keychain.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-07-01
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Only active when running from a real .app bundle that is not a unit-test host; otherwise it stays
//    inert and "Check for Updates…" is disabled (so it never tries to update a non-bundle build).
//

import SwiftUI
import Sparkle

@MainActor
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController?
    /// True only in the packaged .app, where Sparkle can actually run.
    let canCheck: Bool

    private init() {
        if Bundle.main.bundleURL.pathExtension == "app" && !AppRuntime.isUnitTestHost {
            controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil, userDriverDelegate: nil)
            canCheck = true
        } else {
            controller = nil
            canCheck = false
        }
    }

    func checkForUpdates() { controller?.updater.checkForUpdates() }
}
