//
//  @file        SourceReadSession.swift
//  @description Abstraction for a consistent read view of a source folder during one backup pass.
//               The engine reads from `rootURL` and asks `shouldDefer` whether a file is being
//               actively written (and should wait for a later pass). This indirection lets us swap
//               in a true APFS source-snapshot session later WITHOUT changing the engine.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - M1 ships `CoordinatedSourceSession`: it reads the live source via NSFileCoordinator and defers
//    files modified within a short "quiet window" (weak torn-file protection, but honest).
//  - A future `SnapshotSourceSession` will mount an APFS source snapshot for a frozen, fully
//    consistent view. That requires a privileged helper (mount is root-only), hence deferred to M3.
//    Because the engine only depends on this protocol, adding it is additive — not a rewrite.
//  - The quiet window is measured from the moment the engine looks at the file, not from the pass
//    start: a file saved seconds before the pass but read a minute into it has long settled.
//  - A modification date in the future (camera clocks, archive extractors, `touch -t`) is clock skew,
//    not an in-progress write. Such files are backed up — measured naively their "age" is negative
//    and they would be deferred on every pass, forever.
//

import Foundation

/// A read view of a source for the duration of a single backup pass.
protocol SourceReadSession: Sendable {
    /// Directory the engine should walk/read for this pass (a live source, or a snapshot mount).
    var rootURL: URL { get }
    /// Whether a file last modified at `modificationDate` should be deferred to a later pass
    /// because it may be mid-write (modified within the quiet window before now).
    func shouldDefer(modificationDate: Date) -> Bool
    /// Tear down any resources (unmount snapshot, etc.). No-op for the live session.
    func cleanup()
}

/// M1 session: reads the live source tree, deferring very recently modified files.
struct CoordinatedSourceSession: SourceReadSession {
    let rootURL: URL
    /// Files modified less than this many seconds ago are deferred to the next pass; 0 = never defer.
    let quietWindow: TimeInterval

    /// Modification dates up to this far ahead of the clock still count as "just written" (coarse
    /// timestamps on some filesystems); anything later is skew and never deferred.
    static let futureSkewTolerance: TimeInterval = 2

    func shouldDefer(modificationDate: Date) -> Bool {
        shouldDefer(modificationDate: modificationDate, now: Date())
    }

    func shouldDefer(modificationDate: Date, now: Date) -> Bool {
        guard quietWindow > 0 else { return false }
        let age = now.timeIntervalSince(modificationDate)
        if age < -Self.futureSkewTolerance { return false }
        return age < quietWindow
    }

    func cleanup() {}
}

/// Creates a read session for a source. M1 always returns a coordinated live session; future
/// versions will attempt an APFS snapshot mount first and fall back to this.
enum SourceSnapshotProvider {
    static func beginSession(for source: URL, quietWindow: TimeInterval) -> any SourceReadSession {
        CoordinatedSourceSession(rootURL: source, quietWindow: quietWindow)
    }
}
