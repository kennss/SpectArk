//
//  @file        JobSettingsView.swift
//  @description Edit a job's content filter (skip rebuildable files), trigger (realtime vs interval),
//               retention policy, and storage limits (max backup size / minimum free space). Custom
//               grouped-card layout for a clean, aligned look. Saving persists via the coordinator and
//               restarts watcher/schedule.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-19
//
//  Notes:
//  - Sizes are entered in GB (decimal, 1 GB = 1,000,000,000 bytes); 0 means "no limit".
//

import SwiftUI
import AppKit

struct JobSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let job: BackupJob

    @State private var skipsBuildArtifacts: Bool
    @State private var isRealtime: Bool
    @State private var intervalCount: Int
    @State private var intervalUnit: IntervalUnit
    @State private var retentionKind: RetentionKind
    @State private var keepValue: Int
    @State private var quotaGB: Double
    @State private var minFreeGB: Double
    @State private var encryptionEnabled: Bool
    @State private var password: String = ""
    @State private var recoveryKey: String = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private static let bytesPerGB: Double = 1_000_000_000

    enum RetentionKind: String, CaseIterable, Identifiable {
        case automatic, keepCount, keepDays, keepAll
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Automatic (Time Machine style)"
            case .keepCount: return "Keep last N restore points"
            case .keepDays: return "Keep last N days"
            case .keepAll: return "Keep all"
            }
        }
    }

    init(job: BackupJob) {
        self.job = job
        _skipsBuildArtifacts = State(initialValue: job.skipsBuildArtifacts)
        if case .interval(let spec) = job.trigger {
            _isRealtime = State(initialValue: false)
            _intervalCount = State(initialValue: spec.count)
            _intervalUnit = State(initialValue: spec.unit)
        } else {
            _isRealtime = State(initialValue: true)
            _intervalCount = State(initialValue: 1)
            _intervalUnit = State(initialValue: .days)
        }
        switch job.retention.mode {
        case .automatic: _retentionKind = State(initialValue: .automatic); _keepValue = State(initialValue: 30)
        case .keepCount(let n): _retentionKind = State(initialValue: .keepCount); _keepValue = State(initialValue: n)
        case .keepDays(let d): _retentionKind = State(initialValue: .keepDays); _keepValue = State(initialValue: d)
        case .keepAll: _retentionKind = State(initialValue: .keepAll); _keepValue = State(initialValue: 30)
        }
        _quotaGB = State(initialValue: Double(job.retention.maxTotalBytes) / Self.bytesPerGB)
        _minFreeGB = State(initialValue: Double(job.retention.minimumFreeBytes) / Self.bytesPerGB)
        _encryptionEnabled = State(initialValue: job.encryptionEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    contentSection
                    whenSection
                    keepSection
                    storageSection
                    encryptionSection
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 600)
        .overlay { if isWorking { workingOverlay } }
        .sheet(isPresented: Binding(get: { !recoveryKey.isEmpty },
                                    set: { if !$0 { recoveryKey = ""; dismiss() } })) {
            recoveryKeySheet(recoveryKey)
        }
        .alert("Encryption Error", isPresented: Binding(get: { errorMessage != nil },
                                                        set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill").foregroundStyle(Color.wpDesignYellow)
            Text(job.name).font(.headline)
            Text("Settings").font(.headline).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") { save() }
                .buttonStyle(.borderedProminent).tint(Color.wpDesignYellow).foregroundStyle(.black)
        }
        .padding(16)
    }

    // MARK: - Sections

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("What to back up") {
                row("Skip rebuildable files") {
                    Toggle("", isOn: $skipsBuildArtifacts).labelsHidden()
                }
            }
            Text(skipsBuildArtifacts
                 ? "Skips folders your tools can regenerate — dependencies (node_modules, Pods, Python virtual environments), build outputs (Flutter/Gradle build, Cargo/Maven target, SwiftPM .build, Xcode derived data) and caches. A folder is skipped only when its tool is recognized, so your files and Git history are always backed up."
                 : "Off: everything in the source folders is backed up, including dependencies and build outputs.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private var whenSection: some View {
        section("When to back up") {
            row("Trigger") {
                Picker("", selection: $isRealtime) {
                    Text("Realtime").tag(true)
                    Text("Schedule").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            if !isRealtime {
                rowDivider
                row("Run every") {
                    HStack(spacing: 10) {
                        Stepper("\(intervalCount)", value: $intervalCount, in: 1...365).fixedSize()
                        Picker("", selection: $intervalUnit) {
                            ForEach(IntervalUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 100)
                    }
                }
            }
        }
    }

    private var keepSection: some View {
        section("Keep restore points") {
            row("Retention") {
                Picker("", selection: $retentionKind) {
                    ForEach(RetentionKind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 250)
            }
            if retentionKind == .keepCount || retentionKind == .keepDays {
                rowDivider
                row(retentionKind == .keepCount ? "Number to keep" : "Days to keep") {
                    Stepper("\(keepValue)", value: $keepValue, in: 1...3650).fixedSize()
                }
            }
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Storage limits") {
                numberRow("Max backup size", hint: "0 = unlimited", value: $quotaGB)
                rowDivider
                numberRow("Keep free space", hint: "0 = automatic (5% of the disk)", value: $minFreeGB)
            }
            Text("When a limit is reached, the oldest restore points are deleted first — for free space, those of every backup on the disk, oldest first. Keep all never deletes for space unless you set free space here.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private var encryptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Encryption") {
                row("Encrypt this backup") {
                    Toggle("", isOn: $encryptionEnabled).labelsHidden()
                }
                if encryptionEnabled {
                    rowDivider
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.encryptionEnabled ? "Password" : "Set a password")
                            Text("Unlocks the encrypted repo").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        SecureField("password", text: $password)
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            Text(encryptionEnabled
                 ? "Files are chunked, deduplicated, and encrypted (AES-256-GCM) into a repo. A recovery key is shown once when you first enable it — save it. Any existing plaintext backups are migrated into the encrypted repo (history preserved) and removed only after they are safely re-encrypted."
                 : "Off: backups are stored as browsable plaintext files.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }.cardSurface()
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(label)
            Spacer()
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func numberRow(_ label: String, hint: String, value: Binding<Double>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Text("GB").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var rowDivider: some View { Divider().padding(.leading, 14) }

    // MARK: - Save

    private func save() {
        var updated = job
        updated.skipsBuildArtifacts = skipsBuildArtifacts
        updated.trigger = isRealtime
            ? .realtime
            : .interval(IntervalSpec(unit: intervalUnit, count: intervalCount))
        let mode: RetentionPolicy.Mode
        switch retentionKind {
        case .automatic: mode = .automatic
        case .keepCount: mode = .keepCount(max(1, keepValue))
        case .keepDays: mode = .keepDays(max(1, keepValue))
        case .keepAll: mode = .keepAll
        }
        updated.retention = RetentionPolicy(
            mode: mode,
            minimumFreeBytes: Int64(max(0, minFreeGB) * Self.bytesPerGB),
            maxTotalBytes: Int64(max(0, quotaGB) * Self.bytesPerGB)
        )
        updated.encryptionEnabled = encryptionEnabled

        if encryptionEnabled {
            // A password is required to create/verify the repo (unless it's already set and unchanged).
            if password.isEmpty && !job.encryptionEnabled {
                errorMessage = "Enter a password to enable encryption."
                return
            }
            if !password.isEmpty {
                isWorking = true
                Task {
                    do {
                        let recovery = try await model.coordinator.enableEncryption(for: updated, password: password)
                        isWorking = false
                        model.coordinator.updateJob(updated)
                        // Migrate existing plaintext restore points into the encrypted repo (data + history
                        // preserved; plaintext removed only after every point is safely re-encrypted).
                        if await model.coordinator.plaintextSnapshotCount(updated.id) > 0 {
                            model.coordinator.migrateToEncrypted(updated.id)
                        }
                        if let recovery { recoveryKey = recovery }   // newly created → show once
                        else { dismiss() }
                    } catch {
                        isWorking = false
                        errorMessage = BackupErrorMessage.describe(error)
                    }
                }
                return
            }
            // Already encrypted, no new password: migrate any leftover plaintext with the stored key.
            if job.encryptionEnabled {
                model.coordinator.updateJob(updated)
                Task {
                    if await model.coordinator.plaintextSnapshotCount(updated.id) > 0 {
                        model.coordinator.migrateToEncrypted(updated.id)
                    }
                }
                dismiss()
                return
            }
        } else if job.encryptionEnabled {
            KeychainStorage.removePassword(for: updated.id)
        }

        model.coordinator.updateJob(updated)
        dismiss()
    }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView("Setting up encryption…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func recoveryKeySheet(_ key: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill").font(.largeTitle).foregroundStyle(Color.wpDesignYellow)
            Text("Save Your Recovery Key").font(.title3.weight(.semibold))
            Text("This is the ONLY way to recover this backup if you forget the password. It is shown once — store it somewhere safe.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(key)
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
                Button("I've saved it — Done") { recoveryKey = ""; dismiss() }
                    .buttonStyle(.borderedProminent).tint(Color.wpDesignYellow).foregroundStyle(.black)
            }
        }
        .padding(30).frame(width: 440)
    }
}
