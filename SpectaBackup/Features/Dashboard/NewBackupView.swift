//
//  @file        NewBackupView.swift
//  @description "New Backup" sheet shown when the user taps +. Lets them pick the source folder and
//               destination, name it, choose the trigger, and turn on encryption (with a password and
//               a one-time recovery key) BEFORE the first backup runs — instead of immediately opening
//               a folder picker. New backups start from the global defaults (Settings).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-30
//  @lastUpdated 2026-09-19
//

import SwiftUI
import AppKit

struct NewBackupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onCreated: (UUID) -> Void = { _ in }

    @State private var source: URL?
    @State private var destination: URL?
    @State private var name = ""
    @State private var isRealtime = true
    @State private var intervalCount = 1
    @State private var intervalUnit: IntervalUnit = .days
    @State private var encryptionEnabled = false
    @State private var password = ""
    @State private var recoveryKey = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    folderSection
                    triggerSection
                    encryptionSection
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 580)
        .overlay { if isWorking { workingOverlay } }
        .sheet(isPresented: Binding(get: { !recoveryKey.isEmpty },
                                    set: { if !$0 { recoveryKey = ""; dismiss() } })) {
            recoveryKeySheet(recoveryKey)
        }
        .alert("Couldn’t create backup", isPresented: Binding(get: { errorMessage != nil },
                                                              set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .onAppear {
            let defaults = model.settings.jobDefaults
            if case .interval(let spec) = defaults.trigger {
                isRealtime = false
                intervalCount = spec.count
                intervalUnit = spec.unit
            } else {
                isRealtime = true
            }
            encryptionEnabled = defaults.encryptionEnabled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Color.wpDesignYellow)
            Text("New Backup").font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Create") { create() }
                .buttonStyle(.borderedProminent).tint(Color.wpDesignYellow).foregroundStyle(.black)
                .disabled(source == nil || destination == nil)
        }
        .padding(16)
    }

    // MARK: - Sections

    private var folderSection: some View {
        section("Folders") {
            pickerRow(label: "Source",
                      value: source?.path ?? "Choose a folder to back up",
                      chosen: source != nil) {
                if let url = FolderPicker.pick(prompt: "Choose Source",
                                               message: "Choose the folder to back up.") {
                    source = url
                    if name.isEmpty { name = url.lastPathComponent }
                }
            }
            rowDivider
            pickerRow(label: "Destination",
                      value: destination?.path ?? "Choose where backups are stored",
                      chosen: destination != nil) {
                destination = FolderPicker.pick(prompt: "Choose Destination",
                                                message: "Local disk or mounted NAS share.")
            }
            rowDivider
            HStack {
                Text("Name")
                Spacer()
                TextField("Backup name", text: $name)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 220)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("When to back up") {
                row("Trigger") {
                    Picker("", selection: $isRealtime) {
                        Text("Realtime").tag(true)
                        Text("Scheduled").tag(false)
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
            Text(isRealtime
                 ? "Realtime: SpectArk watches this folder and backs up each change within seconds — no timer, no manual runs — keeping a restore point at most every 15 minutes, thinned over time like Time Machine. Unlike most backup apps that only run on a schedule, your latest work is always protected."
                 : "Scheduled: a backup runs automatically on the interval you set, in the background, and each one is a restore point — SpectArk doesn't need to be the active app.")
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
                            Text("Password")
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
                 ? "Files are chunked, deduplicated, and encrypted (AES-256-GCM). A recovery key is shown once after you create the backup — save it."
                 : "Off: backups are stored as browsable plaintext files.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    // MARK: - Create

    private func create() {
        guard let source, let destination else {
            errorMessage = "Choose a source folder and a destination."
            return
        }
        let defaults = model.settings.jobDefaults
        let job = BackupJob(
            name: name.isEmpty ? source.lastPathComponent : name,
            sources: [source], destination: destination,
            trigger: isRealtime ? .realtime : .interval(IntervalSpec(unit: intervalUnit, count: intervalCount)),
            retention: defaults.retention,
            encryptionEnabled: encryptionEnabled)

        if encryptionEnabled, password.isEmpty {
            errorMessage = "Enter a password for encryption."
            return
        }
        // The destination folder is marked (and an encrypted repo created) before the job is added.
        isWorking = true
        let repoPassword = encryptionEnabled ? password : nil
        Task {
            do {
                let recovery = try await model.coordinator.createJob(job, password: repoPassword)
                isWorking = false
                onCreated(job.id)
                if let recovery { recoveryKey = recovery }   // show once, then dismiss
                else { dismiss() }
            } catch {
                isWorking = false
                errorMessage = BackupErrorMessage.describe(error)
            }
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
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func pickerRow(label: String, value: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Button(action: action) {
                HStack(spacing: 5) {
                    Text(value).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(chosen ? .primary : .secondary)
                        .frame(maxWidth: 280, alignment: .trailing)
                    Image(systemName: "folder")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var rowDivider: some View { Divider().padding(.leading, 14) }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView(encryptionEnabled ? "Setting up encryption…" : "Preparing the destination…")
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
                Button("I’ve saved it — Done") { recoveryKey = ""; dismiss() }
                    .buttonStyle(.borderedProminent).tint(Color.wpDesignYellow).foregroundStyle(.black)
            }
        }
        .padding(30).frame(width: 440)
    }
}
