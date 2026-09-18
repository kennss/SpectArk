//
//  @file        ChangeJournal.swift
//  @description Asks the FSEvents journal what changed in a source folder since a cursor, so a capture
//               pass compares only those directories instead of walking the whole source. Replays the
//               volume's event history from the cursor (this also covers changes made while SpectArk was
//               not running) and reports either a set of dirty directories or that a full scan is needed.
//               Design: docs/INCREMENTAL_ENGINE_DESIGN.md §3.7.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - A cursor is (event ID, FSEvents UUID of the source volume). A different UUID means the volume's
//    event database was reset or replaced, so IDs are not comparable: full scan. A volume without a
//    journal (e.g. a network share) has no UUID: full scan every time.
//  - Dirty directory for an event = the parent of the changed item (its listing changed or the item
//    did); a directory event also marks the directory itself. MustScanSubDirs marks a recursive rescan;
//    dropped events, ID wraps, mounts, an event outside every spelling of the source folder, and a replay
//    that does not finish (HistoryDone) within the timeout demand a full scan.
//  - The journal says where to look, never what is there: the capture engine validates every reported
//    directory against the disk (symlinks, case, exclusions, directory identity) before trusting it.
//  - Replayed events go through the job's ChangeFilter first, so changes inside excluded folders never
//    make a directory dirty — the same rule that keeps them from waking a pass. Marker files of the
//    artifact rules (ArtifactRules.markerReach) are looked at before filtering: creating a CACHEDIR.TAG
//    hides its own event, yet the folder whose listing it changes must be compared.
//  - After HistoryDone the stream is flushed once (FSEventStreamFlushSync) to also collect events that
//    happened just before the pass but were not delivered yet. The next cursor is the last event ID
//    actually received, never "now": anything not delivered has a larger ID and is replayed next time.
//  - Events are mapped to paths relative to the source folder through every spelling of the root
//    (SourceSpellings: as configured, realpath(3), and without the Data volume prefix).
//

import CoreServices
import Foundation

struct JournalCursor: Codable, Equatable, Sendable {
    let eventID: UInt64
    let volumeUUID: String
}

enum JournalChanges: Equatable, Sendable {
    /// Compare only these directories (paths relative to the source folder, "" = the folder itself;
    /// value: recursive rescan).
    case directories([String: Bool], lastEventID: UInt64?)
    /// The journal cannot be trusted for this span; walk the whole source.
    case fullScan(reason: String)
}

enum ChangeJournal {

    static let replayTimeout: TimeInterval = 30

    /// The cursor that marks "everything up to now" for a source, or nil when its volume keeps no
    /// FSEvents journal.
    static func cursorNow(for source: URL) -> JournalCursor? {
        guard let uuid = volumeUUID(of: source.path) else { return nil }
        return JournalCursor(eventID: FSEventsGetCurrentEventId(), volumeUUID: uuid)
    }

    /// FSEvents UUID of the volume holding `path` (nil when it keeps no journal).
    static func volumeUUID(of path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// What changed in `source` since `cursor`, as far as `exclusions` let a backup see it.
    static func changes(in source: URL, since cursor: JournalCursor, exclusions: BackupExclusions,
                        timeout: TimeInterval = replayTimeout) -> JournalChanges {
        guard let uuid = volumeUUID(of: source.path) else { return .fullScan(reason: "no journal on this volume") }
        guard uuid == cursor.volumeUUID else { return .fullScan(reason: "journal reset") }

        let collector = ReplayCollector()
        // The stream holds its own reference to the collector for as long as it can call back.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: ReplayCollector.retainInfo, release: ReplayCollector.releaseInfo,
                                           copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, ReplayCollector.callback, &context,
                                               [source.path] as CFArray, FSEventStreamEventId(cursor.eventID),
                                               0, flags) else {
            return .fullScan(reason: "event stream unavailable")
        }
        let queue = DispatchQueue(label: "ai.calidalab.spectabackup.journal")
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        let finished = collector.done.wait(timeout: .now() + timeout) == .success
        if finished { FSEventStreamFlushSync(stream) }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        guard finished else { return .fullScan(reason: "journal replay timed out") }

        // One snapshot for everything below: the filter, the markers and the next cursor see the same events.
        let received = collector.events()
        let events = received.map { WatchEvent(path: $0.path, flags: $0.flags) }
        let relevant = ChangeFilter(sources: [source], exclusions: exclusions).relevantEvents(events)
        let markers = exclusions.skipsBuildArtifacts ? events.filter(isMarkerEvent) : []
        let lastID = received.filter { $0.id != 0 }.map(\.id).max()
        return directories(from: relevant, markers: markers, lastEventID: lastID, source: source)
    }

    // MARK: - Mapping events to dirty directories

    /// Flags that mean the stream lost detail for this span.
    private static let untrustworthy = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped
                                                               | kFSEventStreamEventFlagKernelDropped
                                                               | kFSEventStreamEventFlagRootChanged
                                                               | kFSEventStreamEventFlagEventIdsWrapped
                                                               | kFSEventStreamEventFlagMount
                                                               | kFSEventStreamEventFlagUnmount)

    private static let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)

    private static func isMarkerEvent(_ event: WatchEvent) -> Bool {
        event.flags & (untrustworthy | historyDone) == 0
            && ArtifactRules.markerReach[(event.path as NSString).lastPathComponent] != nil
    }

    /// Dirty directories for already-filtered events plus the folders that `markers` (artifact-rule
    /// marker files, unfiltered) affect. `lastEventID` covers every received event, relevant or not, so
    /// irrelevant churn still advances the cursor.
    static func directories(from events: [WatchEvent], markers: [WatchEvent] = [], lastEventID: UInt64?,
                            source: URL) -> JournalChanges {
        let roots = SourceSpellings.of(source)
        var dirty: [String: Bool] = [:]

        func relative(_ absolute: String) -> String? {
            let path = SourceSpellings.normalized(absolute)
            guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
            return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        func mark(_ rel: String, recursive: Bool) {
            dirty[rel] = (dirty[rel] ?? false) || recursive
        }

        for event in events {
            if event.flags & untrustworthy != 0 { return .fullScan(reason: "events were dropped") }
            if event.flags & historyDone != 0 { continue }
            // A path we cannot place inside the source (another spelling, or a rescan coalesced at an
            // ancestor): its change cannot be localised.
            guard let rel = relative(event.path) else { return .fullScan(reason: "event outside the source folder") }

            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                mark(rel, recursive: true)
                continue
            }
            if rel.isEmpty {
                mark("", recursive: false)   // the folder itself (its listing or metadata)
                continue
            }
            mark((rel as NSString).deletingLastPathComponent, recursive: false)
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                mark(rel, recursive: false)
            }
        }

        for marker in markers {
            guard let rel = relative(marker.path), !rel.isEmpty,
                  let reach = ArtifactRules.markerReach[(rel as NSString).lastPathComponent] else { continue }
            let components = rel.split(separator: "/")
            mark(components.dropLast(reach.levelsUp).joined(separator: "/"), recursive: reach.recursive)
        }
        return .directories(dirty, lastEventID: lastEventID)
    }
}

/// Collects replayed events until FSEvents signals HistoryDone. Callbacks arrive on one serial queue.
final class ReplayCollector: @unchecked Sendable {

    struct Event: Equatable, Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
        let id: UInt64
    }

    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var collected: [Event] = []
    private var finished = false

    func events() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    fileprivate func receive(_ batch: [Event]) {
        lock.lock()
        collected.append(contentsOf: batch)
        let historyDone = batch.contains { $0.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 }
        let signal = historyDone && !finished
        if signal { finished = true }
        lock.unlock()
        if signal { done.signal() }
    }

    static let retainInfo: CFAllocatorRetainCallBack = { info in
        guard let info else { return nil }
        _ = Unmanaged<ReplayCollector>.fromOpaque(info).retain()
        return info
    }

    static let releaseInfo: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<ReplayCollector>.fromOpaque(info).release()
    }

    static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIds in
        guard let info else { return }
        let collector = Unmanaged<ReplayCollector>.fromOpaque(info).takeUnretainedValue()
        let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
        guard paths.count == count else {
            // Unreadable batch: record it as dropped (full scan) and end the replay now.
            collector.receive([Event(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped
                                                                                | kFSEventStreamEventFlagHistoryDone),
                                     id: 0)])
            return
        }
        collector.receive((0..<count).map { Event(path: paths[$0], flags: eventFlags[$0], id: eventIds[$0]) })
    }
}
