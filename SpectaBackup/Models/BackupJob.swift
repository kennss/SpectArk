//
//  @file        BackupJob.swift
//  @description Core job model: one or more source folders → one destination, with a trigger mode,
//               exclude rules, and a retention policy. Persisted as JSON in Application Support.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//
//  Notes:
//  - `sources`/`destination` are absolute file URLs. The app is non-sandboxed, so no security-scoped
//    bookmarks are needed — paths are stored and used directly.
//  - TriggerMode is a Codable enum with an associated IntervalSpec; Swift synthesizes the coding.
//  - `skipsBuildArtifacts` defaults to true, including for jobs saved before the field existed:
//    dependency folders and build outputs are rebuildable and made up 85–95% of the entries in real
//    developer source trees (measured 2026-09-18).
//

import Foundation

/// How a backup job decides when to run.
enum TriggerMode: Codable, Sendable, Hashable {
    /// React to filesystem changes immediately (FSEvents + debounce).
    case realtime
    /// Run on a fixed time/date interval.
    case interval(IntervalSpec)
}

/// Unit for an interval-based trigger.
enum IntervalUnit: String, Codable, Sendable, Hashable, CaseIterable {
    case hours
    case days
    case weeks
}

/// A fixed schedule, e.g. every 6 hours, every 1 day at 02:00.
struct IntervalSpec: Codable, Sendable, Hashable {
    var unit: IntervalUnit
    /// Number of `unit`s between runs (>= 1).
    var count: Int
    /// Preferred hour of day (0–23) for daily/weekly runs; nil = no preference.
    var preferredHour: Int?

    init(unit: IntervalUnit, count: Int, preferredHour: Int? = nil) {
        self.unit = unit
        self.count = max(1, count)
        self.preferredHour = preferredHour
    }
}

/// A single backup job.
struct BackupJob: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Absolute source folder URLs to back up.
    var sources: [URL]
    /// Destination root (local volume path or mounted NAS share).
    var destination: URL
    var trigger: TriggerMode
    /// Relative glob patterns to exclude, in addition to the built-in excludes.
    var excludeGlobs: [String]
    /// Skip rebuildable developer artifacts (dependency folders, build outputs, caches) — see
    /// `ArtifactRules` for exactly what qualifies.
    var skipsBuildArtifacts: Bool
    var retention: RetentionPolicy
    var isEnabled: Bool
    /// When true, this job backs up into an encrypted dedup repo (DedupEngine) instead of the
    /// plaintext snapshot engine. The repo password lives in the Keychain, never in config.json.
    var encryptionEnabled: Bool
    let createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         sources: [URL],
         destination: URL,
         trigger: TriggerMode = .realtime,
         excludeGlobs: [String] = [],
         skipsBuildArtifacts: Bool = true,
         retention: RetentionPolicy = .automatic,
         isEnabled: Bool = true,
         encryptionEnabled: Bool = false,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sources = sources
        self.destination = destination
        self.trigger = trigger
        self.excludeGlobs = excludeGlobs
        self.skipsBuildArtifacts = skipsBuildArtifacts
        self.retention = retention
        self.isEnabled = isEnabled
        self.encryptionEnabled = encryptionEnabled
        self.createdAt = createdAt
    }

    // Backward-compatible decoding: `encryptionEnabled` is absent in repos created before encryption,
    // and `skipsBuildArtifacts` in configs saved before artifact exclusion existed.
    enum CodingKeys: String, CodingKey {
        case id, name, sources, destination, trigger, excludeGlobs, skipsBuildArtifacts, retention, isEnabled,
             encryptionEnabled, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sources = try c.decode([URL].self, forKey: .sources)
        destination = try c.decode(URL.self, forKey: .destination)
        trigger = try c.decode(TriggerMode.self, forKey: .trigger)
        excludeGlobs = try c.decode([String].self, forKey: .excludeGlobs)
        skipsBuildArtifacts = try c.decodeIfPresent(Bool.self, forKey: .skipsBuildArtifacts) ?? true
        retention = try c.decode(RetentionPolicy.self, forKey: .retention)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        encryptionEnabled = try c.decodeIfPresent(Bool.self, forKey: .encryptionEnabled) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}
