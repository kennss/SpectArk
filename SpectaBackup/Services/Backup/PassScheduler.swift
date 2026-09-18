//
//  @file        PassScheduler.swift
//  @description Per-job scheduling state for backup passes as a pure value type: every event (a
//               relevant change, a manual request, the armed timer firing, a pass or migration starting
//               and finishing) updates the state and returns the one action the coordinator must
//               perform. Keeping all of it here — instead of several dictionaries in the coordinator —
//               makes every ordering unit-testable with an injected clock.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Timing rules come from RerunPolicy. At most one automatic pass is armed at a time; a newer request
//    re-arms it, and the smaller quiet window wins so a pending settle pass stays a settle pass.
//  - Anything that arrives while the job is busy is remembered and acted on when the work finishes:
//    a manual request starts immediately (never throttled), otherwise a settle pass for deferred files,
//    otherwise a follow-up for changes, otherwise nothing. A failed pass arms a backoff retry.
//  - The coordinator only performs `.arm` for enabled realtime jobs; for others it calls
//    `automaticRunsStopped()` so no stale pending state survives.
//  - A started pass says whether it was requested (Back Up Now, a due schedule, a new job) rather than
//    triggered by changes: a requested pass always ends with a checkpoint, an explicit restore point.
//

import Foundation

struct PassScheduler: Equatable {

    enum Action: Equatable {
        case none
        /// Arm (replacing any armed one) an automatic pass to start after `delay` seconds.
        case arm(delay: TimeInterval, quietWindow: TimeInterval)
        /// Start a pass now. `requested`: someone asked for this backup (it seals a checkpoint).
        case start(quietWindow: TimeInterval, requested: Bool)
    }

    /// A pass or a migration is in progress.
    private(set) var isBusy = false
    private var changedWhileBusy = false
    private var manualWhileBusy = false
    /// A settle pass is still owed: it was armed when other work started, or fired while busy.
    private var settleWhileBusy = false
    /// When the oldest change not yet covered by a pass arrived.
    private var pendingSince: Date?
    /// Earliest start allowed by the duty cycle.
    private var notBefore: Date?
    /// Quiet window of the armed automatic pass; nil when none is armed.
    private(set) var armedQuietWindow: TimeInterval?
    private var consecutiveFailures = 0

    // MARK: - Events

    /// A relevant filesystem change (or a catch-up request) for this job.
    mutating func changeArrived(now: Date) -> Action {
        if pendingSince == nil { pendingSince = now }
        if isBusy {
            changedWhileBusy = true
            return .none
        }
        return arm(requested: RerunPolicy.changeDebounce, quietWindow: RerunPolicy.quietWindow, now: now)
    }

    /// The user asked for a backup now.
    mutating func manualRequested() -> Action {
        if isBusy {
            manualWhileBusy = true
            return .none
        }
        return .start(quietWindow: 0, requested: true)
    }

    /// The armed automatic pass's timer fired.
    mutating func armedPassFired() -> Action {
        let window = armedQuietWindow ?? RerunPolicy.quietWindow
        armedQuietWindow = nil
        if isBusy {
            changedWhileBusy = true
            if window == 0 { settleWhileBusy = true }
            return .none
        }
        return .start(quietWindow: window, requested: false)
    }

    /// What the job is busy with.
    enum Work: Equatable {
        /// A backup pass reading the source with this quiet window.
        case pass(quietWindow: TimeInterval)
        /// Re-encrypting existing snapshots; it does not read the source.
        case migration
    }

    /// Work begins and supersedes the armed pass (the coordinator cancels its timer). A pass covers
    /// every change seen so far; a migration does not, so pending work carries over to its end.
    mutating func workStarted(_ work: Work) {
        let armedSettle = armedQuietWindow == 0
        let hadPending = pendingSince != nil || armedQuietWindow != nil
        isBusy = true
        armedQuietWindow = nil
        switch work {
        case .pass(let quietWindow):
            pendingSince = nil
            if armedSettle && quietWindow > 0 { settleWhileBusy = true }
        case .migration:
            if hadPending { changedWhileBusy = true }
            if armedSettle { settleWhileBusy = true }
        }
    }

    mutating func passFinished(now: Date, duration: TimeInterval, deferredCount: Int, succeeded: Bool) -> Action {
        isBusy = false
        notBefore = RerunPolicy.notBefore(passEndedAt: now, duration: duration)
        let changed = changedWhileBusy, manual = manualWhileBusy, settle = settleWhileBusy
        changedWhileBusy = false
        manualWhileBusy = false
        settleWhileBusy = false

        if manual { return .start(quietWindow: 0, requested: true) }
        guard succeeded else {
            consecutiveFailures += 1
            pendingSince = nil   // the backoff must not be cut short by the debounce cap
            return arm(requested: RerunPolicy.retryDelay(afterFailures: consecutiveFailures),
                       quietWindow: RerunPolicy.quietWindow, now: now)
        }
        consecutiveFailures = 0
        let deferred = settle ? max(1, deferredCount) : deferredCount
        guard let followUp = RerunPolicy.followUp(changedDuringPass: changed, deferredCount: deferred,
                                                  succeeded: true) else { return .none }
        return arm(requested: followUp.delay, quietWindow: followUp.quietWindow, now: now)
    }

    mutating func migrationFinished(now: Date) -> Action {
        isBusy = false
        let changed = changedWhileBusy, manual = manualWhileBusy, settle = settleWhileBusy
        changedWhileBusy = false
        manualWhileBusy = false
        settleWhileBusy = false
        if manual { return .start(quietWindow: 0, requested: true) }
        if settle { return arm(requested: RerunPolicy.quietWindow, quietWindow: 0, now: now) }
        if changed { return arm(requested: RerunPolicy.changeDebounce, quietWindow: RerunPolicy.quietWindow, now: now) }
        return .none
    }

    /// The job no longer runs automatically (disabled, switched to a schedule): forget pending work.
    mutating func automaticRunsStopped() {
        armedQuietWindow = nil
        pendingSince = nil
        changedWhileBusy = false
        settleWhileBusy = false
    }

    // MARK: - Arming

    private mutating func arm(requested: TimeInterval, quietWindow: TimeInterval, now: Date) -> Action {
        let window = min(quietWindow, armedQuietWindow ?? quietWindow)
        armedQuietWindow = window
        let delay = RerunPolicy.startDelay(requested: requested, pendingSince: pendingSince,
                                           notBefore: notBefore, now: now)
        return .arm(delay: delay, quietWindow: window)
    }
}
