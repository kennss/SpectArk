//
//  @file        BackupExclusions.swift
//  @description Decides which source entries to skip: built-in system junk (Trashes, Spotlight,
//               fseventsd, …) and transient Git lock files, user-supplied glob patterns (matched with
//               fnmatch), and — when the job opts in — rebuildable developer artifacts (dependency
//               folders, build outputs, caches). The engine also excludes the destination tree
//               separately to avoid recursion.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Artifact rules never guess from a folder name alone when the name is ambiguous. A directory is
//    skipped only when the tool that owns it is identified: by a name only that tool uses
//    (node_modules, __pycache__, .dart_tool), by that tool's manifest beside it (Flutter/Gradle
//    `build`, Cargo/Maven `target`, CocoaPods `Pods`, Gradle `.gradle`, SwiftPM `.build`), or by a
//    marker the tool writes (SwiftPM workspace-state.json, a CACHEDIR.TAG, Xcode's Intermediates.noindex,
//    `DerivedData` holding ModuleCache.noindex, a Python virtualenv's pyvenv.cfg).
//  - The macOS "exclude from backups" flag (NSURLIsExcludedFromBackupKey) is deliberately NOT honoured:
//    Photos sets it on its library's `database` and `resources` folders, so honouring it would back up
//    a Photos library that cannot be opened after restore.
//  - `build` beside an .xcodeproj is deliberately NOT a rule: its content is developer-chosen (release
//    archives with dSYMs live there); Xcode derived data inside it is still recognised by its markers.
//  - Rules never skip a folder that may also hold the user's own work. A virtualenv contributes only
//    its `site-packages` (a project may live in the venv folder, scripts in its bin/). Xcode build
//    output contributes only `Build` and Xcode's own caches and package checkouts beside it — with the
//    "Relative to Workspace" build location, `Build/Intermediates.noindex` sits inside the project folder.
//  - `includeEverything` matches nothing, not even the built-ins. Walks over SNAPSHOT trees (orphan
//    removal, hardlink materialization, flag clearing, restore) must use it so they see every entry.
//    (Deliberately not named `none`: in an Optional context `.none` silently means nil.)
//  - `rulesVersion` must be bumped whenever a built-in rule changes (names, Git locks, artifact rules):
//    the history engine then walks every source once, because no file event announces that a rule now
//    includes or excludes something else.
//  - Every content-based artifact rule declares its marker files in `ArtifactRules.markerReach`, so a
//    pass driven by the FSEvents journal re-evaluates the folders a marker change affects.
//

import Darwin
import Foundation

struct BackupExclusions: Sendable {
    /// User-supplied relative glob patterns.
    let globs: [String]
    /// Skip rebuildable developer artifacts (see `ArtifactRules`).
    let skipsBuildArtifacts: Bool
    /// False only for `includeEverything`: built-in names and Git lock files are then kept too.
    private let appliesBuiltIns: Bool

    /// Version of the built-in rules below and of `ArtifactRules`. Bump on any change to them.
    static let rulesVersion = 1

    /// Directory/file names always skipped (volume metadata, caches that must never be backed up).
    static let builtInNames: Set<String> = [
        ".Trashes",
        ".Spotlight-V100",
        ".fseventsd",
        ".DocumentRevisions-V100",
        ".TemporaryItems",
        ".vol",
        ".MobileBackups",
        // Finder view metadata — rewritten just by opening a folder, so backing it up would create
        // no-op snapshots on every Finder visit. Finder regenerates it on restore.
        ".DS_Store"
    ]

    /// Matches nothing — for walking snapshot trees, never sources.
    static let includeEverything = BackupExclusions(globs: [], skipsBuildArtifacts: false, appliesBuiltIns: false)

    init(globs: [String] = [], skipsBuildArtifacts: Bool = false) {
        self.init(globs: globs, skipsBuildArtifacts: skipsBuildArtifacts, appliesBuiltIns: true)
    }

    /// The exclusions a job's backup passes (and its change watcher) use.
    init(job: BackupJob) {
        self.init(globs: job.excludeGlobs, skipsBuildArtifacts: job.skipsBuildArtifacts)
    }

    private init(globs: [String], skipsBuildArtifacts: Bool, appliesBuiltIns: Bool) {
        self.globs = globs
        self.skipsBuildArtifacts = skipsBuildArtifacts
        self.appliesBuiltIns = appliesBuiltIns
    }

    /// Whether an entry (by relative path and leaf name) should be excluded from the backup.
    /// Name/pattern rules only — no filesystem access.
    func isExcluded(relativePath: String, name: String) -> Bool {
        if appliesBuiltIns {
            if Self.builtInNames.contains(name) { return true }
            if Self.isGitLockFile(relativePath: relativePath, name: name) { return true }
        }
        for pattern in globs {
            if fnmatch(pattern, relativePath, 0) == 0 || fnmatch(pattern, name, 0) == 0 {
                return true
            }
        }
        return false
    }

    /// Whether a DIRECTORY is a rebuildable artifact to skip (only when the job opts in).
    /// `siblings` answers whether a name exists next to the directory, i.e. in its parent.
    func isArtifactDirectory(at url: URL, name: String, siblings: (String) -> Bool) -> Bool {
        guard skipsBuildArtifacts else { return false }
        return ArtifactRules.matches(directory: url, name: name, siblings: siblings)
    }

    /// The first component of `rel` (a path inside the source folder at `root`) that a walk of the source
    /// skips — the item itself or a folder above it — as a relative path; nil when a walk reaches it.
    /// Only folders can be artifacts: the last component counts as one when `lastIsDirectory`.
    /// `isArtifact(path, name, parentPath)` (absolute paths) lets callers cache folder decisions.
    func excludedComponent(of rel: String, root: String, lastIsDirectory: Bool,
                           isArtifact: (_ path: String, _ name: String, _ parentPath: String) -> Bool) -> String? {
        let components = rel.split(separator: "/").map(String.init)
        var parentPath = root
        var relativePath = ""
        for (index, name) in components.enumerated() {
            relativePath = relativePath.isEmpty ? name : relativePath + "/" + name
            if isExcluded(relativePath: relativePath, name: name) { return relativePath }
            let itemPath = parentPath + "/" + name
            let isDirectory = index < components.count - 1 || lastIsDirectory
            if isDirectory && isArtifact(itemPath, name, parentPath) { return relativePath }
            parentPath = itemPath
        }
        return nil
    }

    /// `excludedComponent` with uncached folder checks (a parent listing per artifact candidate).
    func excludedComponent(of rel: String, root: String, lastIsDirectory: Bool) -> String? {
        excludedComponent(of: rel, root: root, lastIsDirectory: lastIsDirectory) { path, name, parentPath in
            var siblings: Set<String>?
            return isArtifactDirectory(at: URL(fileURLWithPath: path, isDirectory: true), name: name) { candidate in
                if siblings == nil {
                    siblings = Set((try? FileManager.default.contentsOfDirectory(atPath: parentPath)) ?? [])
                }
                return siblings!.contains(candidate)
            }
        }
    }

    /// Git's `<file>.lock` files (index.lock, HEAD.lock, refs/…/x.lock) exist only while a git command
    /// runs. They are never repository state, and a stale one restored from a backup blocks git.
    /// git-annex is the exception: its object store under `.git/annex/` keeps each file's extension in
    /// the key, so an annexed `x.lock` is real content there.
    private static func isGitLockFile(relativePath: String, name: String) -> Bool {
        guard name.hasSuffix(".lock") else { return false }
        let parts = relativePath.split(separator: "/")
        guard let git = parts.lastIndex(of: ".git"), git < parts.count - 1 else { return false }
        return !parts[(git + 1)...].contains("annex")
    }
}

/// Recognizers for rebuildable developer artifacts, each keyed to the tool that owns the directory.
enum ArtifactRules {

    /// Names only one tool ever uses: the directory holds nothing but that tool's output.
    static let toolOwnedNames: Set<String> = [
        "node_modules",   // npm / yarn / pnpm dependencies
        "__pycache__",    // Python bytecode cache
        ".dart_tool"      // Dart / Flutter tool state
    ]

    /// Names that are artifacts only next to the manifest of the tool that writes them.
    static let manifestGated: [String: [String]] = [
        "build": ["pubspec.yaml", "build.gradle", "build.gradle.kts"],             // Flutter, Gradle
        "target": ["Cargo.toml", "pom.xml"],                                       // Cargo, Maven
        "Pods": ["Podfile"],                                                        // CocoaPods
        // Gradle's per-project cache. ~/.gradle (the Gradle home, with gradle.properties credentials
        // and init scripts) has no manifest beside it and is kept.
        ".gradle": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"],
        ".build": ["Package.swift"]                                                 // SwiftPM
    ]

    /// Names that are artifacts when the tool's own state is inside them (manifest may be absent).
    static let markerGated: [String: [String]] = [
        ".build": ["workspace-state.json"],                                         // SwiftPM
        "DerivedData": ["ModuleCache.noindex"]                                      // Xcode's global root
    ]

    /// Xcode's build output folder (`Build`, with Intermediates.noindex inside) and what Xcode keeps
    /// beside it in a derived-data folder: its caches and the Swift package checkouts (SourcePackages,
    /// re-resolvable from Package.resolved). Recognised only next to such a `Build`; the generic
    /// `Logs` is deliberately not in the list.
    static let xcodeBuildMarker = "Intermediates.noindex"
    static let xcodeDerivedNames: Set<String> = ["ModuleCache.noindex", "Index.noindex",
                                                 "CompilationCache.noindex", "SDKStatCaches.noindex",
                                                 "SourcePackages"]

    /// Cache Directory Tagging Specification signature (https://bford.info/cachedir/).
    static let cacheDirTagName = "CACHEDIR.TAG"
    static let cacheDirTagSignature = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    /// A Python virtualenv's marker, at the venv root; its `site-packages` is two or three levels down.
    static let virtualEnvMarker = "pyvenv.cfg"

    /// Which folder must be compared again when a marker file appears, changes or disappears.
    struct MarkerReach: Equatable, Sendable {
        /// The folder whose listing decides the affected artifact, as levels above the marker file.
        let levelsUp: Int
        /// Everything below that folder must be compared (the artifact is not directly in it).
        let recursive: Bool
    }

    /// Every file name a content-based rule reads, and the folder a change to it affects. Derived from the
    /// rules above; keep it complete when adding a rule (and bump `BackupExclusions.rulesVersion`).
    static let markerReach: [String: MarkerReach] = {
        var reach: [String: MarkerReach] = [:]
        for manifest in manifestGated.values.joined() {
            reach[manifest] = MarkerReach(levelsUp: 1, recursive: false)   // beside the artifact
        }
        for marker in markerGated.values.joined() {
            reach[marker] = MarkerReach(levelsUp: 2, recursive: false)     // inside the artifact
        }
        // Build/<marker>: decides Build and the Xcode folders beside it — all in Build's parent.
        reach[xcodeBuildMarker] = MarkerReach(levelsUp: 2, recursive: false)
        reach[cacheDirTagName] = MarkerReach(levelsUp: 2, recursive: false)
        // <venv>/pyvenv.cfg: site-packages sits two or three levels below the venv root.
        reach[virtualEnvMarker] = MarkerReach(levelsUp: 1, recursive: true)
        return reach
    }()

    static func matches(directory url: URL, name: String, siblings: (String) -> Bool) -> Bool {
        if toolOwnedNames.contains(name) { return true }
        if let manifests = manifestGated[name], manifests.contains(where: siblings) { return true }
        let path = url.path
        if let markers = markerGated[name], markers.contains(where: { exists(path + "/" + $0) }) { return true }
        if name == "Build" && exists(path + "/" + xcodeBuildMarker) { return true }
        if xcodeDerivedNames.contains(name),
           exists(url.deletingLastPathComponent().path + "/Build/" + xcodeBuildMarker) { return true }
        if name == "site-packages" && isInsideVirtualEnv(sitePackages: url) { return true }
        if hasCacheDirTag(path) { return true }
        return false
    }

    private static func exists(_ path: String) -> Bool {
        var st = Darwin.stat()
        return lstat(path, &st) == 0
    }

    /// `<venv>/lib/pythonX.Y/site-packages` (POSIX) or `<venv>/Lib/site-packages` (Windows layout).
    private static func isInsideVirtualEnv(sitePackages url: URL) -> Bool {
        let up2 = url.deletingLastPathComponent().deletingLastPathComponent()
        let up3 = up2.deletingLastPathComponent()
        return exists(up2.path + "/" + virtualEnvMarker) || exists(up3.path + "/" + virtualEnvMarker)
    }

    private static func hasCacheDirTag(_ dir: String) -> Bool {
        // O_NONBLOCK so a FIFO named CACHEDIR.TAG can't hang the walk; only a regular file counts.
        let fd = open(dir + "/" + cacheDirTagName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = Darwin.stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_size >= off_t(cacheDirTagSignature.count) else { return false }
        var buf = [UInt8](repeating: 0, count: cacheDirTagSignature.count)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return n == cacheDirTagSignature.count && buf == cacheDirTagSignature
    }
}
