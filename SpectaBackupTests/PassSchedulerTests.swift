//
//  @file        PassSchedulerTests.swift
//  @description Every ordering the pass scheduler must get right, with an injected clock: debounce and
//               its 60 s cap, changes during a pass, the settle pass for deferred files (and that it
//               survives new changes and other work starting first), manual runs never throttled, the
//               capped duty cycle, failure backoff, work pending across a migration, and stale state
//               never leaking into later runs.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import XCTest
@testable import SpectaBackup

final class PassSchedulerTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private let debounce = RerunPolicy.changeDebounce
    private let window = RerunPolicy.quietWindow

    /// Run a pass from start to finish.
    private func runPass(_ s: inout PassScheduler, start: TimeInterval, duration: TimeInterval,
                         deferred: Int = 0, succeeded: Bool = true,
                         during: (inout PassScheduler) -> Void = { _ in }) -> PassScheduler.Action {
        s.workStarted(.pass(quietWindow: RerunPolicy.quietWindow))
        during(&s)
        return s.passFinished(now: at(start + duration), duration: duration, deferredCount: deferred,
                              succeeded: succeeded)
    }

    // MARK: - Changes

    func testIdleChangeArmsDebouncedPass() {
        var s = PassScheduler()
        XCTAssertEqual(s.changeArrived(now: at(0)), .arm(delay: debounce, quietWindow: window))
    }

    func testContinuousChangesStartAPassWithin60Seconds() {
        var s = PassScheduler()
        _ = s.changeArrived(now: at(0))
        guard case let .arm(delay, _) = s.changeArrived(now: at(59)) else { return XCTFail() }
        XCTAssertEqual(delay, 1, accuracy: 0.001)
        XCTAssertEqual(s.changeArrived(now: at(75)), .arm(delay: 0, quietWindow: window))
    }

    func testChangeDuringPassGetsAFollowUp() {
        var s = PassScheduler()
        let next = runPass(&s, start: 0, duration: 1) { XCTAssertEqual($0.changeArrived(now: self.at(0.5)), .none) }
        XCTAssertEqual(next, .arm(delay: debounce, quietWindow: window))
    }

    func testNothingPendingMeansNoFollowUp() {
        var s = PassScheduler()
        XCTAssertEqual(runPass(&s, start: 0, duration: 1), .none)
    }

    func testAPassCoversEarlierChangesSoTheCapRestarts() {
        var s = PassScheduler()
        _ = s.changeArrived(now: at(0))
        _ = runPass(&s, start: 3, duration: 1)
        // 100 s later: a fresh change is debounced normally, not capped by the change at t=0.
        XCTAssertEqual(s.changeArrived(now: at(104)), .arm(delay: debounce, quietWindow: window))
    }

    // MARK: - Deferred files (settle pass)

    func testDeferredFilesGetASettlePassEvenWhenChangesKeepComing() {
        // A database written every second: every pass defers it AND sees new changes meanwhile.
        var s = PassScheduler()
        let next = runPass(&s, start: 0, duration: 1, deferred: 1) { _ = $0.changeArrived(now: self.at(0.5)) }
        guard case let .arm(_, quietWindow) = next else { return XCTFail("\(next)") }
        XCTAssertEqual(quietWindow, 0, "must settle (copy it anyway), not defer it again forever")
    }

    func testArmedSettlePassStaysSettleWhenANewChangeRearms() {
        var s = PassScheduler()
        _ = runPass(&s, start: 0, duration: 1, deferred: 1)
        guard case let .arm(_, quietWindow) = s.changeArrived(now: at(2)) else { return XCTFail() }
        XCTAssertEqual(quietWindow, 0)
        XCTAssertEqual(s.armedPassFired(), .start(quietWindow: 0, requested: false))
    }

    func testSettleIsNotLostWhenOtherWorkStartsFirst() {
        // A migration starts while a settle pass is armed; the migration doesn't read the source.
        var s = PassScheduler()
        _ = runPass(&s, start: 0, duration: 1, deferred: 1)
        s.workStarted(.migration)
        guard case let .arm(_, quietWindow) = s.migrationFinished(now: at(30)) else { return XCTFail() }
        XCTAssertEqual(quietWindow, 0)

        // A pass that still defers (quiet window > 0) starting over an armed settle keeps it owed.
        var p = PassScheduler()
        _ = runPass(&p, start: 0, duration: 1, deferred: 1)
        p.workStarted(.pass(quietWindow: RerunPolicy.quietWindow))
        guard case let .arm(_, window) = p.passFinished(now: at(10), duration: 1, deferredCount: 0,
                                                        succeeded: true) else { return XCTFail() }
        XCTAssertEqual(window, 0)
    }

    func testManualPassCoversAnArmedSettle() {
        var s = PassScheduler()
        _ = runPass(&s, start: 0, duration: 1, deferred: 1)
        XCTAssertEqual(s.manualRequested(), .start(quietWindow: 0, requested: true))   // copies without deferring
        s.workStarted(.pass(quietWindow: 0))
        XCTAssertEqual(s.passFinished(now: at(10), duration: 1, deferredCount: 0, succeeded: true), .none)
    }

    // MARK: - Manual runs

    func testManualRunStartsImmediately() {
        var s = PassScheduler()
        XCTAssertEqual(s.manualRequested(), .start(quietWindow: 0, requested: true))
    }

    func testManualRequestDuringLongPassIsNotThrottled() {
        var s = PassScheduler()
        let next = runPass(&s, start: 0, duration: 200) { XCTAssertEqual($0.manualRequested(), .none) }
        XCTAssertEqual(next, .start(quietWindow: 0, requested: true), "runs right after the current pass, no duty-cycle rest")
    }

    // MARK: - Duty cycle

    func testDutyCycleRestIsCapped() {
        var s = PassScheduler()
        let next = runPass(&s, start: 0, duration: 7_200) { _ = $0.changeArrived(now: self.at(100)) }
        guard case let .arm(delay, _) = next else { return XCTFail("\(next)") }
        XCTAssertEqual(delay, RerunPolicy.maxRest, accuracy: 0.001,
                       "a two-hour first backup must not hold realtime off for two more hours")
    }

    func testShortPassesKeepRealtimeLatency() {
        var s = PassScheduler()
        _ = runPass(&s, start: 0, duration: 0.5)
        XCTAssertEqual(s.changeArrived(now: at(1)), .arm(delay: debounce, quietWindow: window))
    }

    // MARK: - Failures

    func testFailedPassRetriesWithBackoffAndSuccessResetsIt() {
        var s = PassScheduler()
        XCTAssertEqual(runPass(&s, start: 0, duration: 1, succeeded: false),
                       .arm(delay: RerunPolicy.retryDelay(afterFailures: 1), quietWindow: window))
        _ = s.armedPassFired()
        XCTAssertEqual(runPass(&s, start: 61, duration: 1, succeeded: false),
                       .arm(delay: RerunPolicy.retryDelay(afterFailures: 2), quietWindow: window))
        XCTAssertEqual(RerunPolicy.retryDelay(afterFailures: 2), 2 * RerunPolicy.retryDelay(afterFailures: 1))
        XCTAssertEqual(RerunPolicy.retryDelay(afterFailures: 30), RerunPolicy.maxRetry)
        _ = s.armedPassFired()
        XCTAssertEqual(runPass(&s, start: 200, duration: 1), .none)
        XCTAssertEqual(runPass(&s, start: 300, duration: 1, succeeded: false),
                       .arm(delay: RerunPolicy.retryDelay(afterFailures: 1), quietWindow: window))
    }

    func testChangeDuringBackoffRetriesSooner() {
        var s = PassScheduler()
        _ = runPass(&s, start: 0, duration: 1, succeeded: false)
        XCTAssertEqual(s.changeArrived(now: at(5)), .arm(delay: debounce, quietWindow: window))
    }

    // MARK: - Migration and stopping

    func testMigrationFinishHonoursWhatArrivedMeanwhile() {
        var changed = PassScheduler()
        changed.workStarted(.migration)
        _ = changed.changeArrived(now: at(1))
        XCTAssertEqual(changed.migrationFinished(now: at(10)), .arm(delay: debounce, quietWindow: window))

        var manual = PassScheduler()
        manual.workStarted(.migration)
        _ = manual.manualRequested()
        XCTAssertEqual(manual.migrationFinished(now: at(20)), .start(quietWindow: 0, requested: true))

        var idle = PassScheduler()
        idle.workStarted(.migration)
        XCTAssertEqual(idle.migrationFinished(now: at(30)), .none)
    }

    func testChangePendingBeforeAMigrationIsNotLost() {
        var s = PassScheduler()
        _ = s.changeArrived(now: at(0))            // armed …
        s.workStarted(.migration)                  // … then the migration supersedes the timer
        XCTAssertEqual(s.migrationFinished(now: at(40)), .arm(delay: debounce, quietWindow: window))
    }

    func testStoppingAutomaticRunsForgetsPendingWork() {
        var s = PassScheduler()
        _ = s.changeArrived(now: at(0))
        s.automaticRunsStopped()
        XCTAssertNil(s.armedQuietWindow)
        // Re-enabled much later: the old pending change must not cap the new debounce to zero.
        XCTAssertEqual(s.changeArrived(now: at(500)), .arm(delay: debounce, quietWindow: window))
    }
}
