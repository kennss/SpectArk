//
//  @file        SparsebundleManager.swift
//  @description Manages an APFS sparsebundle disk image on a destination that is not a local APFS/HFS+
//               volume (NAS shares, exFAT/FAT drives). The image is attached, the history engine runs
//               inside its APFS volume exactly as on a local disk, then it is detached.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  This is the most fragile backup path (review H6) — a network drop can corrupt the embedded
//  filesystem. Safety measures:
//  - APFS *journaled* image (resilient to interruption).
//  - Always detach (caller uses defer); abort the pass on any I/O error rather than retrying.
//  - Single-writer lock file beside the image (two machines attaching the same bundle = corruption).
//  - Deleting files inside the image does NOT shrink it → periodic `hdiutil compact` (detached).
//  - Restore attaches READ-ONLY so a restore bug can't corrupt the backup.
//

import Foundation

struct SparsebundleManager: Sendable {

    static let imageName = "SpectaBackup.sparsebundle"
    static let lockName = ".spectabackup.lock"

    struct Attachment: Sendable {
        let imageURL: URL
        let mountPoint: URL
        let lockURL: URL?
    }

    enum SBError: Error, CustomStringConvertible {
        case locked(String)
        case missingImageForReadOnly
        case noMountPoint
        case command(String, Int32, String)

        var description: String {
            switch self {
            case let .locked(p): return "sparsebundle is locked by another writer: \(p)"
            case .missingImageForReadOnly: return "sparsebundle does not exist (read-only attach)"
            case .noMountPoint: return "hdiutil attach returned no mount point"
            case let .command(c, code, err): return "hdiutil \(c) failed (\(code)): \(err)"
            }
        }
    }

    /// Ensure the image exists (create if missing, read-write only) and attach it; returns the mount.
    static func attach(at destination: URL, maxSizeBytes: Int64, readOnly: Bool) throws -> Attachment {
        let image = destination.appendingPathComponent(imageName, isDirectory: true)
        let fm = FileManager.default

        if !fm.fileExists(atPath: image.path) {
            guard !readOnly else { throw SBError.missingImageForReadOnly }
            try create(image: image, maxSizeBytes: maxSizeBytes)
        }

        // Single-writer lock (read-write only). Best-effort: prevents same-host double-attach and
        // signals intent to other hosts. A stale lock from a crash is overwritten.
        var lockURL: URL?
        if !readOnly {
            let lock = destination.appendingPathComponent(lockName)
            if fm.fileExists(atPath: lock.path),
               let contents = try? String(contentsOf: lock, encoding: .utf8), !contents.isEmpty,
               isLockLive(contents) {
                throw SBError.locked(contents)
            }
            try? "\(ProcessInfo.processInfo.processIdentifier)@\(ProcessInfo.processInfo.hostName)"
                .write(to: lock, atomically: true, encoding: .utf8)
            lockURL = lock
        }

        let mount = try attachImage(image, readOnly: readOnly)
        return Attachment(imageURL: image, mountPoint: mount, lockURL: lockURL)
    }

    /// Detach the image and release the lock. Safe to call in a defer / on error.
    static func detach(_ attachment: Attachment) {
        _ = try? run(["detach", attachment.mountPoint.path, "-force"])
        if let lock = attachment.lockURL { try? FileManager.default.removeItem(at: lock) }
    }

    /// Reclaim space after deletions (must be detached). Slow; run opportunistically.
    static func compact(imageAt destination: URL) throws {
        let image = destination.appendingPathComponent(imageName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: image.path) else { return }
        _ = try run(["compact", image.path, "-batteryallowed"])
    }

    // MARK: - hdiutil

    private static func create(image: URL, maxSizeBytes: Int64) throws {
        // Sparse: -size is the MAX logical capacity; actual disk use grows only with real data.
        // Use the quota if set, otherwise a generous 2 TB cap.
        let size = maxSizeBytes > 0 ? "\(maxSizeBytes)b" : "2t"
        _ = try run(["create", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                     "-volname", "SpectaBackup", "-size", size, "-nospotlight", image.path])
    }

    private static func attachImage(_ image: URL, readOnly: Bool) throws -> URL {
        var args = ["attach", image.path, "-nobrowse", "-noverify", "-plist"]
        args.append(readOnly ? "-readonly" : "-readwrite")
        let out = try run(args)
        guard let mount = parseMountPoint(plistData: out) else { throw SBError.noMountPoint }
        return URL(fileURLWithPath: mount)
    }

    private static func parseMountPoint(plistData: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return mountPoint
            }
        }
        return nil
    }

    /// A lock is "live" only if its PID is still running on this host; otherwise it's stale (crash).
    private static func isLockLive(_ contents: String) -> Bool {
        guard let atIndex = contents.firstIndex(of: "@") else { return false }
        let host = String(contents[contents.index(after: atIndex)...])
        guard host == ProcessInfo.processInfo.hostName else { return true }   // different host → respect
        guard let pid = Int32(contents[..<atIndex]) else { return false }
        return kill(pid, 0) == 0   // process exists
    }

    @discardableResult
    private static func run(_ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SBError.command(args.first ?? "", process.terminationStatus, err)
        }
        return data
    }
}
