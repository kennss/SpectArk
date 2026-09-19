//
//  @file        AppDelegate.swift
//  @description App-level hooks SwiftUI's App lifecycle does not expose: how the app was launched (a quiet
//               start at login), the Mac going to sleep, and quitting — NAS images are detached before
//               either of the last two.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-19
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Sleep: only images nothing is using are detached (ImageLease.detachIdle) — the share may not survive
//    the sleep. It runs on the main thread before the notification returns, so it is done before the Mac
//    sleeps.
//  - Quit: every image this process attached is detached, in use or not; the process is ending. A NAS image
//    being compacted first has its compaction cancelled and its lock released (at most 20 s): left running,
//    `hdiutil compact` would hold the image past the process, with nothing holding the lock. Sleep cancels
//    compactions the same way (at most 10 s) rather than have the share drop under one.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppLaunch.recordLaunch() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                          object: nil, queue: nil) { _ in
            SparsebundleManager.stopCompactions(timeout: 10, forGood: false)
            ImageLease.detachIdle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SparsebundleManager.stopCompactions(timeout: 20, forGood: true)
        SparsebundleManager.detachAll()
    }
}
