//
//  @file        HistoryFixture.swift
//  @description Shared test fixture for the history engine: a temp source folder and destination, a
//               controllable clock for capture passes, helpers to read current/ and rebuild the file
//               contents of any checkpoint from the catalog, and a disk/catalog consistency check.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Passes read changes from the FSEvents journal. A change made a moment ago may not have reached
//    fseventsd yet, so `pass` first waits until a live stream on the source has reported every path the
//    test wrote or deleted, with an event newer than the change — then the journal replay has it too.
//    (In the app a pass starts only after the watcher saw the event, so the race does not exist there.)
//

import CoreServices
import Darwin
import Foundation
import XCTest
@testable import SpectaBackup

final class HistoryFixture {

    struct SimulatedCrash: Error {}

    let root: URL
    let source: URL
    let job: BackupJob
    let layout: HistoryLayout
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let watch: JournalWatch
    private let canonicalSource: String
    private var unsettled: [(path: String, after: UInt64)] = []

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-history-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("src", isDirectory: true)
        let destination = root.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        job = BackupJob(name: "t", sources: [source], destination: destination)
        layout = HistoryLayout(jobRoot: BackupRunner.jobRoot(for: job))
        try FileManager.default.createDirectory(at: layout.jobRoot, withIntermediateDirectories: true)
        canonicalSource = try XCTUnwrap(realpath(source.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        watch = JournalWatch(path: canonicalSource)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func time(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func write(_ rel: String, _ text: String) throws {
        let url = source.appendingPathComponent(rel)
        let after = FSEventsGetCurrentEventId()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        unsettled.append((canonicalSource + "/" + rel, after))
    }

    func delete(_ rel: String) throws {
        let after = FSEventsGetCurrentEventId()
        try FileManager.default.removeItem(at: source.appendingPathComponent(rel))
        unsettled.append((canonicalSource + "/" + rel, after))
    }

    func move(_ rel: String, to newRel: String) throws {
        let after = FSEventsGetCurrentEventId()
        try FileManager.default.moveItem(at: source.appendingPathComponent(rel), to: source.appendingPathComponent(newRel))
        unsettled.append((canonicalSource + "/" + rel, after))
        unsettled.append((canonicalSource + "/" + newRel, after))
    }

    /// rename(2) inside the source (FileManager may refuse a change of letter case only).
    func rename(_ rel: String, to newRel: String) throws {
        let after = FSEventsGetCurrentEventId()
        guard Darwin.rename(source.appendingPathComponent(rel).path, source.appendingPathComponent(newRel).path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        unsettled.append((canonicalSource + "/" + rel, after))
        unsettled.append((canonicalSource + "/" + newRel, after))
    }

    /// Wait for `rel` too before the next pass (for changes made without the helpers above).
    func note(_ rel: String, after: UInt64) {
        unsettled.append((canonicalSource + "/" + rel, after))
    }

    @discardableResult
    func pass(at minutes: Double, force: Bool = false, engine: CaptureEngine? = nil,
              job override: BackupJob? = nil, quietWindow: TimeInterval = 0) throws -> CaptureOutcome {
        XCTAssertTrue(watch.waitFor(unsettled), "FSEvents never reported \(unsettled.map(\.path))")
        unsettled.removeAll()
        let when = time(minutes)
        return try (engine ?? CaptureEngine(layout: layout))
            .runPass(job: override ?? job, quietWindow: quietWindow, forceCheckpoint: force, now: { when })
    }

    func store() throws -> HistoryStore { try HistoryStore(path: layout.catalogPath) }

    func mirror(_ rel: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: layout.current("src/" + rel))))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// File contents of checkpoint `seq`, rebuilt from the catalog.
    func files(at seq: Int64) throws -> [String: String] {
        let s = try store()
        var result: [String: String] = [:]
        for entry in try s.allEntries().values where entry.kind == .file && entry.born <= seq {
            result[entry.path] = try read(layout.current(entry.path))
        }
        for version in try s.versions() where version.kind == .file && version.born <= seq && seq < version.died {
            result[version.path] = try read(layout.version(try XCTUnwrap(version.stored)))
        }
        return result
    }

    /// Disk and catalog agree: every entry is on disk as that inode, every kept version exists, nothing
    /// untracked (temps included) is left in current/, and no intent is pending.
    func assertConsistent(file: StaticString = #filePath, line: UInt = #line) throws {
        let s = try store()
        XCTAssertTrue(try s.pendingIntents().isEmpty, "pending intents", file: file, line: line)
        let entries = try s.allEntries()
        for entry in entries.values {
            var st = Darwin.stat()
            XCTAssertEqual(lstat(layout.current(entry.path), &st), 0, "missing \(entry.path)", file: file, line: line)
            XCTAssertEqual(UInt64(st.st_ino), entry.mirrorIno, "inode of \(entry.path)", file: file, line: line)
        }
        for version in try s.versions() {
            if let stored = version.stored {
                XCTAssertTrue(FileManager.default.fileExists(atPath: layout.version(stored)),
                              "version file of \(version.path)", file: file, line: line)
            }
        }
        let onDisk = FileManager.default.enumerator(atPath: layout.currentRoot)?.allObjects as? [String] ?? []
        for rel in onDisk {
            XCTAssertNotNil(entries[rel], "untracked in current/: \(rel)", file: file, line: line)
        }
    }

    private func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }
}

/// A live FSEvents stream on the source that records every path it reports, so a test can wait until
/// fseventsd has its changes.
final class JournalWatch: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var newest: [String: UInt64] = [:]   // path → newest event ID reported for it

    init(path: String) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, _, ids in
            guard let info else { return }
            let watch = Unmanaged<JournalWatch>.fromOpaque(info).takeUnretainedValue()
            let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
            watch.lock.lock()
            for index in 0..<min(count, list.count) {
                watch.newest[list[index]] = max(watch.newest[list[index]] ?? 0, ids[index])
            }
            watch.lock.unlock()
        }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "test.journal.watch"))
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Wait until each path has an event newer than its `after` ID.
    func waitFor(_ changes: [(path: String, after: UInt64)], timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let done = changes.allSatisfy { (newest[$0.path] ?? 0) > $0.after }
            lock.unlock()
            if done { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
}
