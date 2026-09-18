//
//  @file        GlobalSettingsView.swift
//  @description App-wide settings sheet (opened from the sidebar bottom-left). Master-detail layout
//               (NavigationSplitView) like the sibling app: a category list on the left, a grouped
//               Form on the right. "Backup Defaults" edits the values new jobs start with (trigger /
//               retention / encryption); "General" holds app appearance.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-30
//  @lastUpdated 2026-09-19
//

import SwiftUI

struct GlobalSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pane: Pane? = .backupDefaults

    enum Pane: String, CaseIterable, Identifiable {
        case backupDefaults, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .backupDefaults: return "Backup Defaults"
            case .general: return "General"
            }
        }
        var icon: String {
            switch self {
            case .backupDefaults: return "gearshape.2"
            case .general: return "paintbrush"
            }
        }
        var group: String {
            switch self {
            case .backupDefaults: return "Defaults"
            case .general: return "App"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(groupedPanes, id: \.0) { group, panes in
                    Section(group) {
                        ForEach(panes) { p in Label(p.title, systemImage: p.icon).tag(p) }
                    }
                }
            }
            .navigationTitle("Settings")
            .frame(minWidth: 200)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        } detail: {
            NavigationStack {
                content(pane ?? .backupDefaults)
                    .navigationTitle((pane ?? .backupDefaults).title)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    // "Defaults" before "App" (descending key sort).
    private var groupedPanes: [(String, [Pane])] {
        Dictionary(grouping: Pane.allCases, by: \.group).sorted { $0.key > $1.key }
    }

    @ViewBuilder
    private func content(_ p: Pane) -> some View {
        switch p {
        case .backupDefaults: BackupDefaultsPane()
        case .general: GeneralPane()
        }
    }
}

// MARK: - Backup defaults

private struct BackupDefaultsPane: View {
    @Environment(AppModel.self) private var model

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

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Trigger", selection: triggerBinding) {
                    Text("Realtime").tag(true)
                    Text("Scheduled").tag(false)
                }
                if case .interval = settings.jobDefaults.trigger {
                    Stepper("Run every \(intervalCountBinding.wrappedValue)", value: intervalCountBinding, in: 1...365)
                    Picker("Unit", selection: intervalUnitBinding) {
                        ForEach(IntervalUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            } header: {
                Text("When to back up")
            } footer: {
                Text(triggerBinding.wrappedValue
                     ? "Realtime: SpectArk watches the folder and backs up each change within seconds, keeping a restore point at most every 15 minutes — not on a timer. New backups start with this trigger; you can change it per backup."
                     : "Scheduled: a backup runs automatically on the interval you set, in the background, and each one is a restore point. New backups start with this trigger; you can change it per backup.")
            }

            Section("Keep restore points") {
                Picker("Retention", selection: retentionBinding) {
                    ForEach(RetentionKind.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Toggle("Encrypt new backups", isOn: $settings.jobDefaults.encryptionEnabled)
            } header: {
                Text("Encryption")
            } footer: {
                Text("When on, new backups use the encrypted dedup engine. Each backup sets its own password the first time it runs.")
            }
        }
        .formStyle(.grouped)
    }

    private var triggerBinding: Binding<Bool> {
        Binding(
            get: { if case .realtime = model.settings.jobDefaults.trigger { return true }; return false },
            set: { realtime in
                if realtime {
                    model.settings.jobDefaults.trigger = .realtime
                } else if case .interval = model.settings.jobDefaults.trigger {
                    // keep the existing interval when switching back to scheduled
                } else {
                    model.settings.jobDefaults.trigger = .interval(IntervalSpec(unit: .days, count: 1))
                }
            }
        )
    }

    private var currentUnit: IntervalUnit {
        if case .interval(let spec) = model.settings.jobDefaults.trigger { return spec.unit }
        return .days
    }

    private var currentCount: Int {
        if case .interval(let spec) = model.settings.jobDefaults.trigger { return spec.count }
        return 1
    }

    private var intervalCountBinding: Binding<Int> {
        Binding(
            get: { currentCount },
            set: { model.settings.jobDefaults.trigger = .interval(IntervalSpec(unit: currentUnit, count: max(1, $0))) }
        )
    }

    private var intervalUnitBinding: Binding<IntervalUnit> {
        Binding(
            get: { currentUnit },
            set: { model.settings.jobDefaults.trigger = .interval(IntervalSpec(unit: $0, count: currentCount)) }
        )
    }

    private var retentionBinding: Binding<RetentionKind> {
        Binding(
            get: {
                switch model.settings.jobDefaults.retention.mode {
                case .automatic: return .automatic
                case .keepCount: return .keepCount
                case .keepDays: return .keepDays
                case .keepAll: return .keepAll
                }
            },
            set: { kind in
                let mode: RetentionPolicy.Mode
                switch kind {
                case .automatic: mode = .automatic
                case .keepCount: mode = .keepCount(30)
                case .keepDays: mode = .keepDays(30)
                case .keepAll: mode = .keepAll
                }
                let current = model.settings.jobDefaults.retention
                model.settings.jobDefaults.retention = RetentionPolicy(
                    mode: mode, minimumFreeBytes: current.minimumFreeBytes, maxTotalBytes: current.maxTotalBytes)
            }
        )
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage("spectabackup.appearance") private var appearance = "system"
    private let loginItem = LoginItem.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { loginItem.isEnabled || loginItem.needsApproval },
                                                      set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    HStack {
                        Text("Switched off in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(Color.wpRed)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Realtime backup runs only while SpectArk is open. At login it starts quietly in the menu bar — no window, no Dock icon.")
            }
            .onAppear { loginItem.refresh() }

            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Appearance")
            } footer: {
                Text("The app follows your system appearance by default. Choose Light or Dark to override it.")
            }
        }
        .formStyle(.grouped)
    }
}
