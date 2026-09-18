//
//  @file        RerunPolicy.swift
//  @description Timing rules for automatic (realtime) backup passes: debounce of filesystem changes,
//               the quiet window for files still being written, the follow-up pass that makes sure no
//               change is left un-backed-up, and the bounds that keep a busy source from either
//               starving backups or running them back to back.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Follow-up passes (each of these previously dropped changes silently):
//    1. The pass deferred files modified within the quiet window. The follow-up is a "settle" pass with
//       no quiet window — even if more changes arrived meanwhile — so a file that is written every few
//       seconds (a database, a log) is still captured instead of being deferred forever.
//    2. A change arrived while a pass was running. The walk may already have passed that folder.
//  - Bounds:
//    - `changeDebounce` equals `quietWindow`, so the file whose save woke a pass has left the quiet
//      window by the time the pass reads it (otherwise every edit would cost a second pass).
//    - `maxDebounce`: a source rewritten more often than the debounce (a log, a dev database) keeps
//      re-arming it; a pass still starts at most this long after the first unserved change.
//    - Duty cycle: the next automatic pass starts no sooner than one pass-duration after the last one
//      ended (capped at `maxRest`), so automatic passes use at most about half the time — without a
//      two-hour initial backup holding realtime off for another two hours.
//  - A failed pass is retried with exponential backoff (the destination may simply not be mounted yet,
//    e.g. the catch-up pass at login); a new change retries sooner.
//  - Manual "Back Up Now" is never delayed by these rules.
//

import Foundation

enum RerunPolicy {
    /// Files modified less than this long before the engine reads them are deferred to a later pass
    /// (they may still be mid-write).
    static let quietWindow: TimeInterval = 3
    /// Wait this long after the last relevant change before starting a pass (coalesces bursts).
    static let changeDebounce: TimeInterval = quietWindow
    /// Upper bound on how long continuous changes can postpone a pass.
    static let maxDebounce: TimeInterval = 60
    /// Longest rest the duty cycle imposes after one pass.
    static let maxRest: TimeInterval = 300
    /// First and longest wait before retrying a failed pass.
    static let firstRetry: TimeInterval = 60
    static let maxRetry: TimeInterval = 1800

    /// A pass to schedule after the previous one finished.
    struct FollowUp: Equatable {
        let delay: TimeInterval
        let quietWindow: TimeInterval
    }

    /// The follow-up a finished pass requires, or nil when none is needed.
    static func followUp(changedDuringPass: Bool, deferredCount: Int, succeeded: Bool) -> FollowUp? {
        guard succeeded else { return nil }
        if deferredCount > 0 { return FollowUp(delay: quietWindow, quietWindow: 0) }   // settle pass
        if changedDuringPass { return FollowUp(delay: changeDebounce, quietWindow: quietWindow) }
        return nil
    }

    /// Wait before retrying after `failures` consecutive failed passes (1, 2, 4 … minutes, capped).
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        let exponent = Double(max(0, min(failures - 1, 16)))
        return min(firstRetry * pow(2, exponent), maxRetry)
    }

    /// Seconds from `now` until an automatic pass requested with `requested` delay may start.
    /// - pendingSince: when the oldest change not yet covered by a pass arrived (nil = none).
    /// - notBefore: earliest start allowed by the duty cycle (nil = no restriction).
    static func startDelay(requested: TimeInterval, pendingSince: Date?, notBefore: Date?,
                           now: Date) -> TimeInterval {
        var delay = requested
        if let pendingSince {
            delay = min(delay, max(0, pendingSince.addingTimeInterval(maxDebounce).timeIntervalSince(now)))
        }
        if let notBefore {
            delay = max(delay, notBefore.timeIntervalSince(now))
        }
        return max(0, delay)
    }

    /// Earliest start of the next automatic pass after one that ran for `duration` and ended at `end`.
    static func notBefore(passEndedAt end: Date, duration: TimeInterval) -> Date {
        end.addingTimeInterval(min(max(0, duration), maxRest))
    }
}
