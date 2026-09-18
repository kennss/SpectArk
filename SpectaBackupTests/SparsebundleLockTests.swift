//
//  @file        SparsebundleLockTests.swift
//  @description The NAS image's single-writer lock: this process's own lock is live only while one of its
//               attachments holds it (a detach that could not remove the file must not block the next
//               attach); a lock whose PID was reused by another process (after a crash and a reboot) is
//               stale; a lock from another machine is respected; and a 1.1.x-format lock ("pid@host") is
//               live only while that PID runs SpectArk — the case that blocked a real NAS job for weeks
//               once PID 750 went to a system process — its host compared with every name this Mac has.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-19
//

import Darwin
import SystemConfiguration
import XCTest
@testable import SpectaBackup

final class SparsebundleLockTests: XCTestCase {

    private func json(_ owner: SparsebundleManager.LockOwner) throws -> String {
        String(decoding: try JSONEncoder().encode(owner), as: UTF8.self)
    }

    func testThisProcessLockIsLiveOnlyWhileAnAttachmentHoldsIt() throws {
        let owner = try XCTUnwrap(SparsebundleManager.currentLockOwner())
        XCTAssertEqual(owner.pid, getpid())
        let path = "/tmp/sbk-lock-\(UUID().uuidString)"
        XCTAssertFalse(SparsebundleManager.isLockLive(try json(owner), at: path), "left behind by a failed detach")
        SparsebundleManager.heldLocks.insert(path)
        defer { SparsebundleManager.heldLocks.remove(path) }
        XCTAssertTrue(SparsebundleManager.isLockLive(try json(owner), at: path))
    }

    func testALockWhosePidWasReusedIsStale() throws {
        let owner = try XCTUnwrap(SparsebundleManager.currentLockOwner())
        // PID 1 exists, but it was not started when this lock's writer was.
        let reused = SparsebundleManager.LockOwner(pid: 1, started: owner.started, machine: owner.machine,
                                                   host: owner.host)
        XCTAssertFalse(SparsebundleManager.isLockLive(try json(reused)))
    }

    func testALockFromAnotherMachineIsRespected() throws {
        let other = SparsebundleManager.LockOwner(pid: 1, started: 0, machine: UUID().uuidString, host: "elsewhere.local")
        XCTAssertTrue(SparsebundleManager.isLockLive(try json(other)))
    }

    func testALegacyLockIsLiveOnlyWhileItsPidRunsSpectArk() {
        let host = ProcessInfo.processInfo.hostName
        XCTAssertFalse(SparsebundleManager.isLockLive("1@\(host)"), "PID 1 is launchd now")
        XCTAssertFalse(SparsebundleManager.isLockLive("\(getpid())@\(host)"),
                       "a 1.1.x lock is never this process's own: its PID was reused")
        XCTAssertFalse(SparsebundleManager.isLockLive("999999@\(host)"), "no such process")
        XCTAssertTrue(SparsebundleManager.isLockLive("1@elsewhere.local"), "another host's lock is respected")
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            XCTAssertFalse(SparsebundleManager.isLockLive("1@\(local).local"), "this Mac's Bonjour name is this host")
        }
    }

}
