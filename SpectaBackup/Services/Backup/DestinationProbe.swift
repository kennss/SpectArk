//
//  @file        DestinationProbe.swift
//  @description Probes a destination volume's real capabilities by performing tiny live tests in a
//               throwaway directory: clonefile support, hardlink support, xattr round-trip, case
//               sensitivity, plus filesystem type and free space. The result selects where backups are
//               written (directly, or inside a sparsebundle).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - Tests are real syscalls against the actual volume — never assume from the fs name alone.
//  - `hardlinkPersistsRemount` cannot be verified inline (no remount in a single pass); we treat
//    local filesystems as persistent and SMB as unverified (conservative), refined in the NAS task.
//  - Case-insensitive destinations risk silently clobbering source names differing only in case;
//    the engine uses `isCaseSensitive` to detect and refuse such collisions.
//

import Darwin
import Foundation

enum DestinationProbe {

    static func probe(destination: URL) throws -> DestinationCapabilities {
        let fm = FileManager.default
        let probeDir = destination.appendingPathComponent(".spectabackup-probe-\(UUID().uuidString)")
        try fm.createDirectory(at: probeDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: probeDir) }

        let vol = try Syscalls.volumeInfo(at: destination.path)
        let fsKind = fileSystemKind(from: vol.fsTypeName)

        let base = probeDir.appendingPathComponent("base.bin")
        try Data([0x01, 0x02, 0x03]).write(to: base)

        let supportsClone = testClone(base: base.path,
                                      dst: probeDir.appendingPathComponent("clone.bin").path)
        let supportsHardlink = testHardlink(base: base.path,
                                            dst: probeDir.appendingPathComponent("link.bin").path)
        let xattrOK = testXattrRoundTrip(path: base.path)
        let caseSensitive = testCaseSensitivity(in: probeDir)
        let mtimeRes: MTimeResolution = (fsKind == .smb) ? .second : .nanosecond

        return DestinationCapabilities(
            fileSystem: fsKind,
            supportsClone: supportsClone,
            supportsHardlink: supportsHardlink,
            hardlinkPersistsRemount: supportsHardlink && fsKind != .smb,
            xattrRoundTrip: xattrOK,
            isCaseSensitive: caseSensitive,
            mtimeResolution: mtimeRes,
            freeBytes: vol.freeBytes,
            probedAt: Date()
        )
    }

    // MARK: - Individual capability tests

    private static func testClone(base: String, dst: String) -> Bool {
        let flags = UInt32(CLONE_NOFOLLOW) | UInt32(CLONE_NOOWNERCOPY)
        guard clonefile(base, dst, flags) == 0 else { return false }
        unlink(dst)
        return true
    }

    private static func testHardlink(base: String, dst: String) -> Bool {
        guard link(base, dst) == 0 else { return false }
        unlink(dst)
        return true
    }

    private static func testXattrRoundTrip(path: String) -> Bool {
        let name = "com.calidalab.spectabackup.probe"
        let value: [UInt8] = [0xAB, 0xCD]
        let setResult = value.withUnsafeBytes { raw in
            setxattr(path, name, raw.baseAddress, raw.count, 0, 0)
        }
        guard setResult == 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 8)
        let read = buffer.withUnsafeMutableBytes { raw in
            getxattr(path, name, raw.baseAddress, raw.count, 0, 0)
        }
        removexattr(path, name, 0)
        return read == value.count
    }

    private static func testCaseSensitivity(in dir: URL) -> Bool {
        let fm = FileManager.default
        let lower = dir.appendingPathComponent("casetest")
        let upper = dir.appendingPathComponent("CASETEST")
        try? Data([0x00]).write(to: lower)
        // If the upper-case path does NOT resolve to the file we just created, the FS is case-sensitive.
        let sensitive = !fm.fileExists(atPath: upper.path)
        try? fm.removeItem(at: lower)
        try? fm.removeItem(at: upper)
        return sensitive
    }

    private static func fileSystemKind(from fsType: String) -> FileSystemKind {
        let name = fsType.lowercased()
        if name == "apfs" { return .apfs }
        if name.hasPrefix("hfs") { return .hfsPlus }
        if name.contains("smb") { return .smb }
        return .other
    }
}
