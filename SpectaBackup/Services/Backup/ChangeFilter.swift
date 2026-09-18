//
//  @file        ChangeFilter.swift
//  @description Decides whether a batch of FSEvents contains a change that a backup pass would act on.
//               A path is irrelevant when it, or any folder above it inside the source, is excluded by
//               the job's BackupExclusions — the same rules the engine applies when it walks the source,
//               so the watcher never wakes a pass for something the pass would skip.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Conservative by construction: kernel/user-dropped events, MustScanSubDirs, root changes, event-ID
//    wraps, mounts/unmounts, paths outside every source root, and changes to a root itself are always
//    relevant. Only a positive exclusion match makes an event irrelevant.
//  - Artifact checks can touch the filesystem (parent listing for manifest-gated names, in-folder
//    markers such as pyvenv.cfg or CACHEDIR.TAG). Results are cached per batch, so a burst of events
//    under one deep folder costs one check per ancestor, not one per event.
//  - A folder that no longer exists (e.g. just deleted) cannot be probed; its content-based rules then
//    fail to match and the event counts as relevant — at worst one extra pass, never a missed change.
//  - FSEvents reports canonical paths (/private/var/…, symlinks resolved, firmlinks as /Users/…), so
//    each root is matched in every spelling `SourceSpellings` lists.
//

import CoreServices
import Foundation

struct ChangeFilter: Sendable {

    /// Source roots as absolute paths without a trailing slash, in every spelling (SourceSpellings).
    private let roots: [String]
    private let exclusions: BackupExclusions

    /// Flags meaning "the event stream lost detail — rescan", which always warrant a pass.
    static let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                                     | kFSEventStreamEventFlagUserDropped
                                                     | kFSEventStreamEventFlagKernelDropped
                                                     | kFSEventStreamEventFlagRootChanged
                                                     | kFSEventStreamEventFlagEventIdsWrapped
                                                     | kFSEventStreamEventFlagMount
                                                     | kFSEventStreamEventFlagUnmount)

    init(sources: [URL], exclusions: BackupExclusions) {
        var roots: [String] = []
        for source in sources {
            for path in SourceSpellings.of(source) where !roots.contains(path) {
                roots.append(path)
            }
        }
        self.roots = roots
        self.exclusions = exclusions
    }

    /// The events a backup would act on: relevant changes plus every stream-status event (rescan flags,
    /// HistoryDone), which callers interpret themselves. Used by the journal replay.
    func relevantEvents(_ events: [WatchEvent]) -> [WatchEvent] {
        let cache = BatchCache()
        let status = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) | Self.rescanFlags
        return events.filter { $0.flags & status != 0 || isRelevant($0, cache: cache) }
    }

    /// True when at least one event in the batch is a change the backup would pick up.
    func containsRelevantChange(_ events: [WatchEvent]) -> Bool {
        let cache = BatchCache()
        for event in events {
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            if event.flags & Self.rescanFlags != 0 { return true }
            if isRelevant(event, cache: cache) { return true }
        }
        return false
    }

    // MARK: - Per-event decision

    private func isRelevant(_ event: WatchEvent, cache: BatchCache) -> Bool {
        let path = SourceSpellings.normalized(event.path)
        let matching = roots.filter { path == $0 || path.hasPrefix($0 + "/") }
        // Not under a known root (a path spelling we can't map): don't risk missing it. Under several
        // (nested sources): relevant if any source would back it up.
        guard !matching.isEmpty else { return true }
        let isDirectoryEvent = event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        return matching.contains { root in
            let rel = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.isEmpty else { return true }   // the root folder itself changed
            return exclusions.excludedComponent(of: rel, root: root, lastIsDirectory: isDirectoryEvent) {
                cache.isArtifact($0, name: $1, parentPath: $2, exclusions: exclusions)
            } == nil
        }
    }
}

/// The spellings under which a source folder's paths can appear: as configured, as realpath(3) resolves
/// it (FSEvents reports /private/var/… for /var/…), and without the Data volume prefix, which FSEvents
/// omits for firmlinked locations (/System/Volumes/Data/Users/… is reported as /Users/…). Foundation's
/// resolvingSymlinksInPath is not used: it strips /private and would undo exactly the resolution needed.
enum SourceSpellings {

    private static let dataVolumePrefix = "/System/Volumes/Data/"

    static func of(_ source: URL) -> [String] {
        var spellings: [String] = []
        for path in [normalized(source.path), canonical(source.path)].compactMap({ $0 }) {
            for spelling in [path] + (path.hasPrefix(dataVolumePrefix) ? ["/" + path.dropFirst(dataVolumePrefix.count)] : [])
            where !spellings.contains(spelling) {
                spellings.append(spelling)
            }
        }
        return spellings
    }

    static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// realpath(3) of an existing path, normalized; nil if it cannot be resolved.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return normalized(String(cString: resolved))
    }
}

/// Per-batch memo of directory listings and artifact decisions. Used on one queue only.
private final class BatchCache {
    private var listings: [String: Set<String>] = [:]
    private var decisions: [String: Bool] = [:]

    func isArtifact(_ path: String, name: String, parentPath: String, exclusions: BackupExclusions) -> Bool {
        if let known = decisions[path] { return known }
        let result = exclusions.isArtifactDirectory(at: URL(fileURLWithPath: path, isDirectory: true),
                                                    name: name,
                                                    siblings: { self.listing(of: parentPath).contains($0) })
        decisions[path] = result
        return result
    }

    private func listing(of dir: String) -> Set<String> {
        if let names = listings[dir] { return names }
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        listings[dir] = names
        return names
    }
}
