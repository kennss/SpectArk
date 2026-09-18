//
//  @file        FolderWatcher.swift
//  @description FSEvents wrapper that watches a set of source paths and fires a coalesced callback when
//               a batch of events contains a change worth a backup pass. Which changes count is decided
//               by an injected predicate (the job's ChangeFilter), evaluated on the watcher's own queue.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - File-level events + IgnoreSelf; the destination lives outside the watched source roots, so our
//    own writes don't create an event storm.
//  - Stream runs on a private serial dispatch queue; `isRelevant` runs there (it may touch the
//    filesystem), so the main actor never pays for filtering. The owner (BackupCoordinator)
//    debounces `onChange` and hops to the main actor before triggering a pass.
//  - Without filtering, background tools polling a repo (`git status` creating and removing
//    .git/index.lock every few seconds) or builds writing into excluded output folders would each
//    wake a full pass.
//

import CoreServices
import Foundation

/// One FSEvents record: the changed path and its FSEventStreamEventFlags.
struct WatchEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags
}

final class FolderWatcher: @unchecked Sendable {

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ai.calidalab.spectabackup.watcher")
    private let paths: [String]
    private let latency: CFTimeInterval
    private let isRelevant: @Sendable ([WatchEvent]) -> Bool
    private let onChange: @Sendable () -> Void

    init(paths: [String],
         latency: TimeInterval = 1.0,
         isRelevant: @escaping @Sendable ([WatchEvent]) -> Bool,
         onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.latency = latency
        self.isRelevant = isRelevant
        self.onChange = onChange
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagIgnoreSelf
                           | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault,
                                               Self.eventCallback,
                                               &context,
                                               paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency,
                                               flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private static let eventCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        // UseCFTypes ⇒ eventPaths is a CFArray of CFString, parallel to the eventFlags C array.
        let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray) as? [String] ?? []
        guard paths.count == count else {
            watcher.onChange()   // can't read the batch: never risk dropping a real change
            return
        }
        let events = (0..<count).map { WatchEvent(path: paths[$0], flags: eventFlags[$0]) }
        if watcher.isRelevant(events) {
            watcher.onChange()
        }
    }
}
