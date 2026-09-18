//
//  @file        BackupExclusionsTests.swift
//  @description Exclusion rules: rebuildable-artifact recognition (tool-owned names; manifest-gated
//               build/target/Pods/.gradle/.build; markers for SwiftPM, Xcode build output and caches,
//               virtualenv site-packages and CACHEDIR.TAG), what must NOT be excluded (the Gradle home, a
//               project using Xcode's "Relative to Workspace" build location, a project or scripts living
//               in a venv folder, folders carrying the macOS backup-exclude flag such as Photos library
//               internals, git-annex objects, real *.lock files), the opt-out, and `includeEverything`.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-09-18
//  @lastUpdated 2026-09-18
//

import XCTest
@testable import SpectaBackup

final class BackupExclusionsTests: XCTestCase {

    private var tmp: URL!
    private let on = BackupExclusions(skipsBuildArtifacts: true)

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sbk-excl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Fixtures

    /// Create `rel` as a directory (and optional files beside it), returning its URL.
    @discardableResult
    private func makeDir(_ rel: String, siblings: [String] = []) throws -> URL {
        let url = tmp.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in siblings {
            let sibling = url.deletingLastPathComponent().appendingPathComponent(name)
            if name.hasSuffix(".xcodeproj") {
                try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            } else {
                try Data().write(to: sibling)
            }
        }
        return url
    }

    private func isArtifact(_ url: URL, _ exclusions: BackupExclusions? = nil) throws -> Bool {
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))
        return (exclusions ?? on).isArtifactDirectory(at: url, name: url.lastPathComponent,
                                                      siblings: { names.contains($0) })
    }

    // MARK: - Artifact rules

    /// Create an empty file at `rel` (intermediate folders included).
    private func touch(_ rel: String) throws {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func testToolOwnedNamesAreArtifacts() throws {
        for name in ["node_modules", "__pycache__", ".dart_tool"] {
            XCTAssertTrue(try isArtifact(makeDir("p/\(name)")), name)
        }
    }

    func testGradleCacheOnlyInsideAGradleProject() throws {
        XCTAssertTrue(try isArtifact(makeDir("app/.gradle", siblings: ["gradlew"])))
        // The Gradle home (~/.gradle: gradle.properties credentials, init scripts) is kept.
        XCTAssertFalse(try isArtifact(makeDir("home/.gradle", siblings: [".zshrc"])))
    }

    func testSwiftPMBuildByManifestOrState() throws {
        XCTAssertTrue(try isArtifact(makeDir("pkg/.build", siblings: ["Package.swift"])))
        try touch("guide/.build/workspace-state.json")
        XCTAssertTrue(try isArtifact(tmp.appendingPathComponent("guide/.build", isDirectory: true)))
        XCTAssertFalse(try isArtifact(makeDir("notes/.build")))
    }

    func testXcodeDerivedDataByMarkers() throws {
        // A custom -derivedDataPath: its Build output and Xcode's caches go, the folder itself stays.
        try touch("app/build/dd/Build/Intermediates.noindex/x")
        try touch("app/build/dd/ModuleCache.noindex/x")
        try touch("app/build/dd/Logs/Build/log.xcactivitylog")
        XCTAssertFalse(try isArtifact(tmp.appendingPathComponent("app/build/dd", isDirectory: true)))
        XCTAssertTrue(try isArtifact(tmp.appendingPathComponent("app/build/dd/Build", isDirectory: true)))
        XCTAssertTrue(try isArtifact(tmp.appendingPathComponent("app/build/dd/ModuleCache.noindex", isDirectory: true)))
        try touch("app/build/dd/SourcePackages/checkouts/pkg/Package.swift")
        XCTAssertTrue(try isArtifact(tmp.appendingPathComponent("app/build/dd/SourcePackages", isDirectory: true)),
                      "Xcode's package checkouts beside its Build output")
        XCTAssertFalse(try isArtifact(tmp.appendingPathComponent("app/build/dd/Logs", isDirectory: true)),
                       "a generic Logs folder is kept")
        XCTAssertFalse(try isArtifact(makeDir("elsewhere/SourcePackages")), "no Xcode Build beside it")
        // The global root is recognised as a whole.
        try touch("Xcode/DerivedData/ModuleCache.noindex/x")
        XCTAssertTrue(try isArtifact(tmp.appendingPathComponent("Xcode/DerivedData", isDirectory: true)))
        // A clang module cache in an ordinary folder is not Xcode's (no Build/Intermediates beside it) …
        try touch("project/ModuleCache.noindex/x")
        XCTAssertFalse(try isArtifact(tmp.appendingPathComponent("project/ModuleCache.noindex", isDirectory: true)))
        // … and a research folder that merely happens to be called DerivedData is kept.
        XCTAssertFalse(try isArtifact(makeDir("study/DerivedData")))
    }

    func testXcodeRelativeToWorkspaceBuildKeepsTheProject() throws {
        // Build Location "Relative to Workspace": Build/Intermediates.noindex inside the project folder.
        try touch("MyApp/Build/Intermediates.noindex/x")
        try touch("MyApp/Sources/App.swift")
        try touch("MyApp/MyApp.xcodeproj/project.pbxproj")
        XCTAssertFalse(try isArtifact(tmp.appendingPathComponent("MyApp", isDirectory: true)))
        XCTAssertTrue(try isArtifact(tmp.appendingPathComponent("MyApp/Build", isDirectory: true)))
        XCTAssertFalse(try isArtifact(tmp.appendingPathComponent("MyApp/Sources", isDirectory: true)))
    }

    func testBuildIsArtifactOnlyNextToFlutterOrGradleManifest() throws {
        XCTAssertTrue(try isArtifact(makeDir("flutter/build", siblings: ["pubspec.yaml"])))
        XCTAssertTrue(try isArtifact(makeDir("android/build", siblings: ["build.gradle.kts"])))
        // Developer-chosen Xcode output (release archives + dSYMs live here) is kept.
        XCTAssertFalse(try isArtifact(makeDir("xcode/build", siblings: ["App.xcodeproj"])))
        // A package whose source folder is literally named "build" is kept.
        XCTAssertFalse(try isArtifact(makeDir("pip/_internal/operations/build")))
    }

    func testTargetAndPodsNeedTheirManifest() throws {
        XCTAssertTrue(try isArtifact(makeDir("rust/target", siblings: ["Cargo.toml"])))
        XCTAssertTrue(try isArtifact(makeDir("java/target", siblings: ["pom.xml"])))
        XCTAssertFalse(try isArtifact(makeDir("docs/target")))
        XCTAssertTrue(try isArtifact(makeDir("ios/Pods", siblings: ["Podfile"])))
        XCTAssertFalse(try isArtifact(makeDir("art/Pods")))
    }

    func testVirtualEnvContributesOnlyItsSitePackages() throws {
        try touch("tool/subtitle_env/pyvenv.cfg")
        try touch("tool/subtitle_env/bin/my-own-script.sh")
        try touch("tool/subtitle_env/lib/python3.13/site-packages/pkg/__init__.py")
        XCTAssertFalse(try isArtifact(tmp.appendingPathComponent("tool/subtitle_env", isDirectory: true)))
        XCTAssertFalse(try isArtifact(tmp.appendingPathComponent("tool/subtitle_env/bin", isDirectory: true)))
        XCTAssertTrue(try isArtifact(tmp.appendingPathComponent("tool/subtitle_env/lib/python3.13/site-packages",
                                                                isDirectory: true)))
    }

    func testProjectLivingInAVenvFolderIsKept() throws {
        // `python3 -m venv myproj` and then the code inside myproj/: only site-packages goes.
        try touch("myproj/pyvenv.cfg")
        try touch("myproj/app.py")
        try touch("myproj/lib/python3.13/site-packages/requests/__init__.py")
        XCTAssertFalse(try isArtifact(tmp.appendingPathComponent("myproj", isDirectory: true)))
        XCTAssertTrue(try isArtifact(tmp.appendingPathComponent("myproj/lib/python3.13/site-packages",
                                                                isDirectory: true)))
        // site-packages outside any venv (e.g. a vendored tree) is kept.
        XCTAssertFalse(try isArtifact(makeDir("vendor/lib/python3.13/site-packages")))
    }

    func testCacheDirTagIgnoresNonRegularFiles() throws {
        let dir = try makeDir("c/fifo")
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("CACHEDIR.TAG").path, 0o644), 0)
        XCTAssertFalse(try isArtifact(dir), "a FIFO must neither match nor block the walk")
    }

    func testCacheDirTagRequiresSignature() throws {
        let good = try makeDir("c/good")
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n# cache".utf8)
            .write(to: good.appendingPathComponent("CACHEDIR.TAG"))
        XCTAssertTrue(try isArtifact(good))

        let bad = try makeDir("c/bad")
        try Data("not a cache tag".utf8).write(to: bad.appendingPathComponent("CACHEDIR.TAG"))
        XCTAssertFalse(try isArtifact(bad))
    }

    func testMacOSBackupExcludeFlagIsNotAnExclusion() throws {
        // Photos flags its library's `database` folder this way; skipping it would back up a library
        // that cannot be opened after restore.
        var dir = try makeDir("Photos Library.photoslibrary/database")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertFalse(try isArtifact(dir))
    }

    func testOptOutDisablesArtifactRules() throws {
        let off = BackupExclusions(skipsBuildArtifacts: false)
        XCTAssertFalse(try isArtifact(makeDir("p/node_modules"), off))
    }

    // MARK: - Built-ins and Git lock files

    func testGitLockFilesExcludedButRealLockFilesKept() {
        let ex = BackupExclusions()
        XCTAssertTrue(ex.isExcluded(relativePath: ".git/index.lock", name: "index.lock"))
        XCTAssertTrue(ex.isExcluded(relativePath: "books/.git/refs/heads/main.lock", name: "main.lock"))
        XCTAssertFalse(ex.isExcluded(relativePath: ".git/HEAD", name: "HEAD"))
        XCTAssertFalse(ex.isExcluded(relativePath: ".git/index", name: "index"))
        for lockfile in ["Cargo.lock", "Podfile.lock", "yarn.lock", "app/pubspec.lock"] {
            XCTAssertFalse(ex.isExcluded(relativePath: lockfile, name: (lockfile as NSString).lastPathComponent), lockfile)
        }
        // git-annex keeps the file extension in its object keys: an annexed x.lock is real content.
        let annexKey = "SHA256E-s12--3f2a.lock"
        XCTAssertFalse(ex.isExcluded(relativePath: ".git/annex/objects/Xk/9z/\(annexKey)", name: annexKey))
        XCTAssertFalse(ex.isExcluded(relativePath: ".git/annex/objects/Xk/9z/\(annexKey)/\(annexKey)", name: annexKey))
    }

    func testIncludeEverythingMatchesNothing() throws {
        XCTAssertFalse(BackupExclusions.includeEverything.isExcluded(relativePath: ".DS_Store", name: ".DS_Store"))
        XCTAssertFalse(BackupExclusions.includeEverything.isExcluded(relativePath: ".git/index.lock", name: "index.lock"))
        XCTAssertFalse(try isArtifact(makeDir("p/node_modules"), .includeEverything))
    }
}
