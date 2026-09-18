//
//  @file        ConfigCompatTests.swift
//  @description Guards backward compatibility of the persisted job config: a config.json written by
//               an older build (before the retention `maxTotalBytes` quota field existed) must still
//               decode, defaulting the missing field — otherwise the whole job list silently vanishes.
//               Same for `skipsBuildArtifacts`, which must default to ON for existing jobs.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//

import XCTest
@testable import SpectaBackup

final class ConfigCompatTests: XCTestCase {

    func testRetentionPolicyWithoutQuotaDecodes() throws {
        let json = Data("""
        { "mode": { "automatic": {} }, "minimumFreeBytes": 0 }
        """.utf8)
        let policy = try JSONDecoder().decode(RetentionPolicy.self, from: json)
        XCTAssertEqual(policy.maxTotalBytes, 0)   // missing field defaults to unlimited
    }

    func testOldJobConfigStillDecodes() throws {
        // Mirrors a real config.json from before the quota field was added.
        let json = Data("""
        [{
          "createdAt": 804424033.417356,
          "destination": "file:///Volumes/SpectaBackup/",
          "excludeGlobs": [],
          "id": "BD1E7978-01C8-46E6-9879-01D2E6C78C45",
          "isEnabled": true,
          "name": "Developments",
          "retention": { "minimumFreeBytes": 0, "mode": { "automatic": {} } },
          "sources": ["file:///Users/kennt/Desktop/Developments/"],
          "trigger": { "realtime": {} }
        }]
        """.utf8)
        let jobs = try JSONDecoder().decode([BackupJob].self, from: json)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.name, "Developments")
        XCTAssertEqual(jobs.first?.retention.maxTotalBytes, 0)
        XCTAssertEqual(jobs.first?.skipsBuildArtifacts, true)   // absent ⇒ artifact exclusion on
    }

    func testSkipsBuildArtifactsRoundTrips() throws {
        var job = BackupJob(name: "x", sources: [URL(fileURLWithPath: "/tmp/src")],
                            destination: URL(fileURLWithPath: "/tmp/dst"))
        XCTAssertTrue(job.skipsBuildArtifacts)   // new jobs default on
        job.skipsBuildArtifacts = false
        let decoded = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        XCTAssertFalse(decoded.skipsBuildArtifacts)
    }
}
