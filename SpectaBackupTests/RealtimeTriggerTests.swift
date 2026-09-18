//
//  @file        RealtimeTriggerTests.swift
//  @description Realtime trigger behaviour. ChangeFilter: Git lock churn, Finder metadata and changes
//               inside excluded artifacts must not wake a pass; real edits (including git's
//               index.lock → index rename), lossy-stream flags and unmappable paths must; symlinked
//               source roots still filter. A real FSEvents stream end to end (FolderWatcher +
//               ChangeFilter). RerunPolicy's pure rules (follow-ups, settle pass, max debounce, duty
//               cycle) and the quiet-window rule of the source session (measured from now, future
//               mtimes never deferred). The coordinator wiring that applies these rules is not covered
//               here (it persists to the real Application Support config).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import CoreServices
import XCTest
@testable import SpectaBackup

final class RealtimeTriggerTests: XCTestCase {

    private var tmp: URL!
    private var source: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-trigger-\(UUID().uuidString)", isDirectory: true)
        source = tmp.appendingPathComponent("Developments", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: source.appendingPathComponent("app/build/out"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("tools/build"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("app/pubspec.yaml"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func filter(skipsBuildArtifacts: Bool = true, root: URL? = nil) -> ChangeFilter {
        ChangeFilter(sources: [root ?? source], exclusions: BackupExclusions(skipsBuildArtifacts: skipsBuildArtifacts))
    }

    private func event(_ rel: String, _ flags: Int = kFSEventStreamEventFlagItemModified, under root: URL? = nil) -> WatchEvent {
        WatchEvent(path: (root ?? source).appendingPathComponent(rel).path, flags: FSEventStreamEventFlags(flags))
    }

    // MARK: - ChangeFilter

    func testRealFileChangeIsRelevant() {
        XCTAssertTrue(filter().containsRelevantChange([event("books/Sources/Reader.swift")]))
    }

    func testGitLockChurnAndFinderMetadataAreIgnored() {
        XCTAssertFalse(filter().containsRelevantChange([
            event("books/.git/index.lock", kFSEventStreamEventFlagItemCreated),
            event("books/.git/index.lock", kFSEventStreamEventFlagItemRemoved),
            event("books/.DS_Store")
        ]))
    }

    func testGitIndexUpdateIsARealChange() {
        // `git add` writes index.lock and renames it over index: the index path itself must count.
        XCTAssertTrue(filter().containsRelevantChange([
            event("books/.git/index.lock", kFSEventStreamEventFlagItemRenamed),
            event("books/.git/index", kFSEventStreamEventFlagItemRenamed)
        ]))
    }

    func testChangesInsideArtifactsAreIgnoredOnlyWhenSkipped() {
        let inDeps = event("web/node_modules/pkg/index.js")
        XCTAssertFalse(filter().containsRelevantChange([inDeps]))
        XCTAssertTrue(filter(skipsBuildArtifacts: false).containsRelevantChange([inDeps]))
    }

    func testManifestGatedBuildFolder() {
        XCTAssertFalse(filter().containsRelevantChange([event("app/build/out/app.dill")]),
                       "Flutter build output (pubspec.yaml beside it) is an artifact")
        XCTAssertTrue(filter().containsRelevantChange([event("tools/build/script.sh")]),
                      "a plain folder named build is source")
    }

    func testOneRealChangeInANoisyBatchWakesThePass() {
        XCTAssertTrue(filter().containsRelevantChange([
            event("books/.git/index.lock"),
            event("web/node_modules/pkg/index.js"),
            event("books/Sources/Reader.swift")
        ]))
    }

    func testLossyStreamFlagsAlwaysWakeThePass() {
        XCTAssertTrue(filter().containsRelevantChange([
            event("books/.git/index.lock", kFSEventStreamEventFlagMustScanSubDirs)
        ]))
        XCTAssertTrue(filter().containsRelevantChange([
            event("web/node_modules", kFSEventStreamEventFlagKernelDropped)
        ]))
    }

    func testHistoryDoneIsIgnoredButUnknownPathsAndRootAreNot() {
        XCTAssertFalse(filter().containsRelevantChange([event("", kFSEventStreamEventFlagHistoryDone)]))
        XCTAssertTrue(filter().containsRelevantChange([
            WatchEvent(path: "/somewhere/else/file.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))
        ]))
        XCTAssertTrue(filter().containsRelevantChange([
            WatchEvent(path: source.path + "/", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir))
        ]))
    }

    func testSymlinkedSourceRootStillFilters() throws {
        // The job points at a symlink; FSEvents reports the resolved (canonical) path.
        let link = tmp.appendingPathComponent("link-to-source")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let canonical = URL(fileURLWithPath: try XCTUnwrap(realpathString(source.path)), isDirectory: true)
        let viaLink = filter(root: link)
        XCTAssertFalse(viaLink.containsRelevantChange([event("repo/.git/index.lock", under: canonical)]))
        XCTAssertTrue(viaLink.containsRelevantChange([event("repo/README.md", under: canonical)]))
    }

    // MARK: - End to end with a real FSEvents stream

    func testRealFSEventsIgnoreGitLockChurnButCatchRealEdits() throws {
        Thread.sleep(forTimeInterval: 1.0)   // let the fixture's own creation events age out
        let wakes = WakeCounter()
        let batches = WakeCounter()
        let changeFilter = filter()
        let watcher = FolderWatcher(paths: [source.path], latency: 0.2,
                                    isRelevant: { batches.increment(); return changeFilter.containsRelevantChange($0) },
                                    onChange: { wakes.increment() })
        watcher.start()
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.5)

        // Writes must come from another process: FolderWatcher uses IgnoreSelf, so events caused by
        // this test process itself would never be delivered and the test would prove nothing.
        let lock = source.appendingPathComponent("repo/.git/index.lock").path
        let dill = source.appendingPathComponent("app/build/out/app.dill").path
        try shell("for i in 1 2 3 4 5; do touch '\(lock)'; rm '\(lock)'; done; echo x > '\(dill)'")
        let quietDeadline = Date().addingTimeInterval(5)
        while batches.value == 0 && Date() < quietDeadline { Thread.sleep(forTimeInterval: 0.1) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThan(batches.value, 0, "the stream must actually deliver the lock/build events")
        XCTAssertEqual(wakes.value, 0, "lock churn and build output must not wake a pass")

        try shell("echo edit > '\(source.appendingPathComponent("repo/README.md").path)'")
        let deadline = Date().addingTimeInterval(10)
        while wakes.value == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(wakes.value, 0, "a real edit must wake a pass")
    }

    // MARK: - RerunPolicy

    func testFollowUpAfterChangeDuringPass() {
        XCTAssertEqual(RerunPolicy.followUp(changedDuringPass: true, deferredCount: 0, succeeded: true),
                       RerunPolicy.FollowUp(delay: RerunPolicy.changeDebounce, quietWindow: RerunPolicy.quietWindow))
        // Deferred files win: a file written continuously also produces changes during every pass, and
        // must still get a settle pass rather than being deferred again forever.
        XCTAssertEqual(RerunPolicy.followUp(changedDuringPass: true, deferredCount: 3, succeeded: true),
                       RerunPolicy.FollowUp(delay: RerunPolicy.quietWindow, quietWindow: 0))
    }

    func testDeferredFilesGetOneSettlePassWithoutQuietWindow() {
        XCTAssertEqual(RerunPolicy.followUp(changedDuringPass: false, deferredCount: 1, succeeded: true),
                       RerunPolicy.FollowUp(delay: RerunPolicy.quietWindow, quietWindow: 0))
    }

    func testNoFollowUpWhenNothingPendingOrPassFailed() {
        XCTAssertNil(RerunPolicy.followUp(changedDuringPass: false, deferredCount: 0, succeeded: true))
        XCTAssertNil(RerunPolicy.followUp(changedDuringPass: true, deferredCount: 2, succeeded: false))
    }

    func testDebounceCoversTheQuietWindow() {
        // Otherwise the file whose save woke a pass would itself be deferred to a second pass.
        XCTAssertGreaterThanOrEqual(RerunPolicy.changeDebounce, RerunPolicy.quietWindow)
    }

    func testContinuousChangesCannotPostponeAPassBeyondMaxDebounce() {
        let now = Date()
        XCTAssertEqual(RerunPolicy.startDelay(requested: 3, pendingSince: now, notBefore: nil, now: now), 3)
        XCTAssertEqual(RerunPolicy.startDelay(requested: 3, pendingSince: now.addingTimeInterval(-58.5),
                                              notBefore: nil, now: now), 1.5, accuracy: 0.001)
        XCTAssertEqual(RerunPolicy.startDelay(requested: 3, pendingSince: now.addingTimeInterval(-90),
                                              notBefore: nil, now: now), 0)
    }

    func testDutyCycleSpacesAutomaticPasses() {
        let now = Date()
        let notBefore = RerunPolicy.notBefore(passEndedAt: now, duration: 40)
        XCTAssertEqual(RerunPolicy.startDelay(requested: 3, pendingSince: now.addingTimeInterval(-90),
                                              notBefore: notBefore, now: now), 40, accuracy: 0.001,
                       "a 40 s pass is followed by at least 40 s of rest, even when changes are overdue")
        XCTAssertEqual(RerunPolicy.startDelay(requested: 3, pendingSince: nil,
                                              notBefore: RerunPolicy.notBefore(passEndedAt: now, duration: 0.5),
                                              now: now), 3, "short passes don't slow realtime down")
    }

    // MARK: - Quiet window (source session)

    func testQuietWindowMeasuredFromNowAndFutureSkewNeverDeferred() {
        let now = Date()
        let session = CoordinatedSourceSession(rootURL: source, quietWindow: RerunPolicy.quietWindow)
        XCTAssertTrue(session.shouldDefer(modificationDate: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(session.shouldDefer(modificationDate: now.addingTimeInterval(1), now: now),
                      "coarse timestamps slightly ahead of the clock still count as just written")
        XCTAssertFalse(session.shouldDefer(modificationDate: now.addingTimeInterval(-10), now: now))
        XCTAssertFalse(session.shouldDefer(modificationDate: now.addingTimeInterval(86_400), now: now),
                       "a future-dated file (camera clock, archive) is backed up, not deferred forever")
        let settle = CoordinatedSourceSession(rootURL: source, quietWindow: 0)
        XCTAssertFalse(settle.shouldDefer(modificationDate: now, now: now))
    }

    // MARK: - Helpers

    /// Run a shell command in a child process and wait for it.
    private func shell(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, command)
    }

    private func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Thread-safe counter for callbacks arriving on the watcher's queue.
private final class WakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
