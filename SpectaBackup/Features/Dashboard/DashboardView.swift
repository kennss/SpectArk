//
//  @file        DashboardView.swift
//  @description Dashboard window: a sidebar (brand lockup header + backup job list) plus a detail pane. Add a job with the
//               toolbar +; per-job actions live in a ⋯ menu on each row (Back Up Now / Restore /
//               Settings / Remove). The sidebar bottom-left opens GLOBAL settings (defaults for new
//               jobs). The empty state shows the wordmark and a Full Disk Access card when needed.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-07-05
//

import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedJobID: UUID?
    @State private var fdaGranted = FullDiskAccess.isGranted
    @AppStorage("spectark.fdaCardDismissed") private var fdaDismissed = false
    @State private var showGlobalSettings = false
    @State private var settingsJob: BackupJob?
    @State private var restoreJob: BackupJob?
    @State private var jobToRemove: BackupJob?
    @State private var showNewBackup = false

    private var coordinator: BackupCoordinator { model.coordinator }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedJobID) {
                ForEach(coordinator.jobs) { job in
                    JobRow(job: job, state: coordinator.state(for: job.id), coordinator: coordinator,
                           onSettings: { settingsJob = job }, onRestore: { restoreJob = job },
                           onRemove: { jobToRemove = job })
                        .tag(job.id)
                }
            }
            .navigationTitle("Backups")
            .frame(minWidth: 240)
            .toolbar {
                ToolbarItem {
                    Button { showNewBackup = true } label: { Label("Add Backup", systemImage: "plus") }
                }
            }
            // Top-left: app icon + wordmark lockup (brand header).
            .safeAreaInset(edge: .top) { sidebarHeader }
            // Bottom-left: destination disk capacity + global settings (defaults for new jobs).
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            if let id = selectedJobID, let job = coordinator.jobs.first(where: { $0.id == id }) {
                JobDetailView(job: job)
            } else {
                emptyState
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { fdaGranted = FullDiskAccess.isGranted }
        }
        .background(WindowSizeFit())   // shrink an oversized restored window to fit the screen on launch
        .sheet(isPresented: $showGlobalSettings) { GlobalSettingsView().environment(model) }
        .sheet(isPresented: $showNewBackup) {
            NewBackupView(onCreated: { selectedJobID = $0 }).environment(model)
        }
        .sheet(item: $settingsJob) { JobSettingsView(job: $0) }
        .sheet(item: $restoreJob) { job in
            RestoreView(job: job, history: coordinator.state(for: job.id).history)
        }
        .confirmationDialog(
            "Remove this backup?",
            isPresented: Binding(get: { jobToRemove != nil }, set: { if !$0 { jobToRemove = nil } }),
            presenting: jobToRemove
        ) { job in
            Button("Remove & Delete All Snapshots", role: .destructive) {
                if selectedJobID == job.id { selectedJobID = nil }
                coordinator.removeJob(job.id, deleteSnapshots: true)
            }
            Button("Remove Only (Keep Snapshots on Disk)") {
                if selectedJobID == job.id { selectedJobID = nil }
                coordinator.removeJob(job.id, deleteSnapshots: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: { job in
            Text("“\(job.name)” will stop being backed up. Also delete its snapshots on \(job.destination.lastPathComponent) to free the space, or keep them on disk.")
        }
    }

    // MARK: - Sidebar header (brand lockup)

    private var sidebarHeader: some View {
        Button {
            selectedJobID = nil   // deselect → the detail pane shows the start screen
        } label: {
            HStack {
                Image("Lockup")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 30)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
        .help("Home — show the start screen")
    }

    // MARK: - Sidebar footer (destination capacity + settings)

    private var sidebarFooter: some View {
        let usages = coordinator.destinationUsages()
        return VStack(spacing: 8) {
            if !usages.isEmpty {
                VStack(spacing: 8) {
                    ForEach(usages) { DestinationUsageRow(usage: $0) }
                }
                Divider()
            }
            HStack {
                Button { showGlobalSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings — defaults for new backups")
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 28) {
            Image("Wordmark")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300)
            if fdaGranted || fdaDismissed {
                Text("Add a folder to back up with the + button.")
                    .foregroundStyle(.secondary)
            } else {
                fdaCard
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fdaCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.wpDesignYellow)
            Text("Full Disk Access Needed")
                .font(.title3.bold())
            Text("SpectArk needs Full Disk Access to read protected folders like Desktop, Documents, and Downloads. After granting it, quit and reopen SpectArk for the change to take effect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open System Settings…") { FullDiskAccess.openSystemSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wpDesignYellow)
                    .foregroundStyle(.black)
                Button("Quit & Reopen") { FullDiskAccess.relaunchApp() }
            }
            .controlSize(.large)
            .padding(.top, 4)
            Button("Already have access? Dismiss") { fdaDismissed = true }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.top, 2)
        }
        // Re-check periodically so the card clears itself once access becomes effective.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            fdaGranted = FullDiskAccess.isGranted
        }
        .padding(28)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.wpDesignYellow.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }

}

/// Sidebar row: status dot, job name + destination, and a ⋯ menu of per-job actions.
private struct JobRow: View {
    let job: BackupJob
    let state: JobRuntimeState
    let coordinator: BackupCoordinator
    var onSettings: () -> Void
    var onRestore: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isRunning ? Color.wpDesignYellow : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(job.name).font(.body)
                    if showsLock {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.wpDesignYellow)
                            .help("Encrypted — no plaintext copies remain")
                    }
                }
                Text(job.destination.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
                    .background(hovering ? Color.secondary.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Right-click any row for its actions — no need to select the job first.
        .contextMenu { actions }
    }

    /// Per-job actions, shared by the row's ⋯ menu and its right-click context menu,
    /// so they're reachable whether or not the row is selected.
    @ViewBuilder private var actions: some View {
        Button { coordinator.runNow(job.id) } label: { Label("Back Up Now", systemImage: "arrow.clockwise") }
            .disabled(state.isRunning)
        Button(action: onRestore) { Label("Restore…", systemImage: "clock.arrow.circlepath") }
            .disabled(state.history.isEmpty)
        Button(action: onSettings) { Label("Settings…", systemImage: "gearshape") }
        Divider()
        Button(role: .destructive, action: onRemove) {
            Label("Remove", systemImage: "trash")
        }
    }

    /// Lock only when encryption is ON and NO plaintext snapshots remain (fully encrypted). A job with
    /// encryption enabled but plaintext still to migrate shows no lock — the migrate banner covers it.
    private var showsLock: Bool {
        guard job.encryptionEnabled, !state.history.isEmpty else { return false }
        return !state.history.contains {
            $0.status == .complete && !$0.dirName.isEmpty && !$0.dirName.hasPrefix("enc-")
        }
    }
}

/// Sidebar footer row: one backup destination volume's name + free-space bar.
private struct DestinationUsageRow: View {
    let usage: DestinationUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "externaldrive.fill")
                    .font(.caption2).foregroundStyle(Color.wpDesignYellow)
                Text(usage.name).font(.caption).lineLimit(1)
                if usage.jobCount > 1 {
                    Text("· \(usage.jobCount)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(byteString(usage.freeBytes)) free").font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(usage.usedFraction > 0.9 ? Color.wpRed : Color.wpDesignYellow)
                        .frame(width: max(0, min(1, usage.usedFraction)) * geo.size.width)
                }
            }
            .frame(height: 4)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
