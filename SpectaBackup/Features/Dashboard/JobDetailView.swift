//
//  @file        JobDetailView.swift
//  @description Detail dashboard for a job. Layout (option C): a source⟶destination visual header
//               (Carbon Copy Cloner style), a row of status/throughput stat cards plus storage and
//               quota gauges (Arq style), and a timeline of restore points (Time Machine style). Per-job
//               actions live in the sidebar row's ⋯ menu (not a toolbar here).
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-19
//

import SwiftUI
import AppKit

struct JobDetailView: View {
    @Environment(AppModel.self) private var model
    let job: BackupJob
    @State private var plaintextCount = 0
    @State private var destinationOnline = true

    private var coordinator: BackupCoordinator { model.coordinator }
    private var state: JobRuntimeState { coordinator.state(for: job.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceDestinationHeader
                if showsLoginPrompt { loginPrompt }
                if state.isMigrating { migrationBanner }
                else if let msg = state.migrationMessage { migrationDoneBanner(msg) }
                else if job.encryptionEnabled, plaintextCount > 0 { migrationPrompt }
                if state.lastError != nil, !destinationOnline { destinationOfflineCard }
                else if let error = state.lastError { errorBanner(error) }
                statusCards
                storageSection
                snapshotsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(job.name)
        .toolbar { ToolbarItem(placement: .primaryAction) { runButton } }
        // Re-check after history changes AND when a migration ends, so the prompt clears itself.
        .task(id: "\(state.restorePoints.count)-\(state.isMigrating)-\(state.lastError ?? "")") {
            plaintextCount = job.encryptionEnabled ? await coordinator.plaintextSnapshotCount(job.id) : 0
            destinationOnline = DestinationStatus.isReachable(job.destination)
        }
    }

    /// Shown when a pass failed because the destination (external disk or NAS share) isn't mounted —
    /// so the user reconnects it instead of being wrongly told to grant Full Disk Access.
    private var destinationOfflineCard: some View {
        let isNAS = DestinationStatus.isNetworkVolume(job.destination)
        return HStack(spacing: 12) {
            Image(systemName: "externaldrive.trianglebadge.exclamationmark")
                .font(.title2).foregroundStyle(Color.wpDesignYellow)
            VStack(alignment: .leading, spacing: 3) {
                Text(isNAS ? "NAS share not connected" : "Backup destination not connected")
                    .font(.callout.weight(.semibold))
                Text("SpectArk can’t reach \(job.destination.path). Reconnect \(isNAS ? "the NAS share" : "the drive") in Finder, then back up again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Back Up Now") { coordinator.runNow(job.id) }
                .buttonStyle(.borderedProminent).tint(Color.wpDesignYellow).foregroundStyle(.black)
                .disabled(state.isRunning)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wpDesignYellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Run a backup now. Lives in the detail toolbar so it's reachable without the sidebar ⋯ menu.
    /// While a pass is running it shows progress and is disabled (the runner refuses a second pass).
    @ViewBuilder
    private var runButton: some View {
        Button {
            coordinator.runNow(job.id)
        } label: {
            if state.isRunning {
                Label("Backing up…", systemImage: "arrow.clockwise")
            } else {
                Label("Back Up Now", systemImage: "arrow.clockwise")
            }
        }
        .disabled(state.isRunning || state.isMigrating)
        .help("Run a backup now")
    }

    // MARK: - Source → Destination header

    private var sourceDestinationHeader: some View {
        HStack(spacing: 14) {
            folderBadge(icon: "folder.fill",
                        name: job.sources.first?.lastPathComponent ?? "—",
                        path: job.sources.first?.path ?? "—",
                        url: job.sources.first,
                        tint: .secondary)
            VStack(spacing: 4) {
                Image(systemName: state.isRunning ? "arrow.right.circle.fill" : "arrow.right")
                    .font(.title)
                    .foregroundStyle(Color.wpDesignYellow)
                    .symbolEffect(.pulse, isActive: state.isRunning)
            }
            folderBadge(icon: "externaldrive.fill",
                        name: job.destination.lastPathComponent,
                        path: job.destination.path,
                        url: destinationRevealURL,
                        tint: .wpDesignYellow)
        }
    }

    /// Source / destination card. Clicking it opens that folder in Finder (Time Machine / CCC style),
    /// so the backed-up drive is one click away. Disabled when there's no path (e.g. no source set).
    private func folderBadge(icon: String, name: String, path: String, url: URL?, tint: Color) -> some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 30)).foregroundStyle(tint)
                Text(name).font(.callout.weight(.medium)).lineLimit(1)
                Text(path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .help(url == nil ? "" : "Open “\(name)” in Finder")
        .onHover { inside in
            guard url != nil else { return }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    /// Where clicking the destination card takes you in Finder: straight into the latest backed-up
    /// state (current/, skipping the volume root and the opaque per-job UUID directory), else the older
    /// snapshot folders. Falls back to the job root, then the destination, when nothing is browsable —
    /// an encrypted repo, or before the first backup has run.
    private var destinationRevealURL: URL {
        let fm = FileManager.default
        let root = BackupRunner.jobRoot(for: job)
        if !job.encryptionEnabled {
            let current = URL(fileURLWithPath: HistoryLayout(jobRoot: root).currentRoot, isDirectory: true)
            let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
            for folder in [current, snapshots] where fm.fileExists(atPath: folder.path) { return folder }
        }
        if fm.fileExists(atPath: root.path) { return root }
        return job.destination
    }

    // MARK: - Status cards

    private var statusCards: some View {
        HStack(spacing: 12) {
            if state.isRunning {
                StatCard(title: "Backing up", value: "\(byteString(Int64(state.throughputBytesPerSec)))/s",
                         systemImage: "arrow.up.circle.fill", tint: .wpDesignYellow)
                StatCard(title: "Files this pass", value: "\(state.progress.filesProcessed)",
                         systemImage: "doc.on.doc")
            } else {
                StatCard(title: "Last backup", value: lastBackupText,
                         systemImage: "checkmark.circle.fill", tint: .wpDesignYellow)
                StatCard(title: nextLabel, value: nextValue, systemImage: "calendar")
            }
            StatCard(title: "Restore points", value: "\(state.restorePoints.count)",
                     systemImage: "square.stack.3d.up")
        }
    }

    // MARK: - Storage / quota

    @ViewBuilder
    private var storageSection: some View {
        VStack(spacing: 12) {
            if let free = state.destinationFreeBytes, let total = state.destinationTotalBytes, total > 0 {
                StorageGauge(label: "Destination · \(byteString(free)) free of \(byteString(total))",
                             usedFraction: Double(total - free) / Double(total))
            }
            if job.retention.maxTotalBytes > 0 {
                let used = state.storageBytes
                StorageGauge(label: "Backup quota · \(byteString(used)) of \(byteString(job.retention.maxTotalBytes))",
                             usedFraction: Double(used) / Double(job.retention.maxTotalBytes))
            }
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History").font(.headline)
            if state.restorePoints.isEmpty {
                Text("No restore points yet.").foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.restorePoints.enumerated()), id: \.element.id) { index, point in
                        timelineRow(point, isLast: index == state.restorePoints.count - 1)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .cardSurface()
            }
        }
    }

    private func timelineRow(_ point: RestorePoint, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(color(for: point.source)).frame(width: 9, height: 9).padding(.top, 5)
                if !isLast { Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(point.time.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                Text(caption(for: point))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func caption(for point: RestorePoint) -> String {
        let size = "\(point.fileCount) files · \(byteString(point.bytes))"
        switch point.source {
        case .latest: return size + " · Latest"
        case .checkpoint: return size
        case .legacySnapshot: return size + " · Earlier snapshot"
        case .encryptedSnapshot: return size + " · Encrypted"
        }
    }

    // MARK: - Helpers

    // MARK: - Open at login

    @AppStorage("spectark.loginPromptDismissed") private var loginPromptDismissed = false

    /// Offered once, on a job that runs on changes: without it, a restart ends realtime backup until the
    /// app is opened again.
    private var showsLoginPrompt: Bool {
        !loginPromptDismissed && job.isEnabled && job.trigger == .realtime
            && !LoginItem.shared.isEnabled && !LoginItem.shared.needsApproval
    }

    private var loginPrompt: some View {
        HStack(spacing: 10) {
            Image(systemName: "power.circle")
                .font(.title3).foregroundStyle(Color.wpDesignYellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep backing up after a restart").font(.callout.weight(.medium))
                Text("Realtime backup runs only while SpectArk is open. Open it at login — it starts quietly in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Not Now") { loginPromptDismissed = true }
                .controlSize(.small)
            Button("Open at Login") { LoginItem.shared.setEnabled(true) }
                .buttonStyle(.borderedProminent).tint(Color.wpDesignYellow).foregroundStyle(.black)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wpDesignYellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { LoginItem.shared.refresh() }
    }

    private var migrationPrompt: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                .font(.title3).foregroundStyle(Color.wpDesignYellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(plaintextCount) plaintext restore point\(plaintextCount == 1 ? "" : "s") not yet encrypted")
                    .font(.callout.weight(.medium))
                Text("Convert them into the encrypted repo, then remove the plaintext copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Migrate Now") { coordinator.migrateToEncrypted(job.id) }
                .buttonStyle(.borderedProminent).tint(Color.wpDesignYellow).foregroundStyle(.black)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wpDesignYellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func migrationDoneBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3).foregroundStyle(.green)
            Text(message).font(.callout.weight(.medium))
            Spacer()
            Button("Dismiss") { coordinator.clearMigrationMessage(job.id) }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var migrationBanner: some View {
        let text = state.migrationProgress.map { "Migrating to encrypted… \($0.done)/\($0.total)" }
            ?? "Migrating to encrypted…"
        return HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wpDesignYellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(Color.wpRed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.wpRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var lastBackupText: String {
        guard let last = state.lastBackup else { return "Never" }
        return last.formatted(.relative(presentation: .named))
    }

    private var nextLabel: String {
        if case .interval = job.trigger { return "Next scheduled" }
        return "Trigger"
    }

    private var nextValue: String {
        switch job.trigger {
        case .realtime:
            return "Realtime"
        case .interval(let spec):
            if let next = Scheduler.nextDue(spec: spec, lastBackup: state.lastBackup) {
                return next.formatted(.relative(presentation: .named))
            }
            return "Every \(spec.count) \(spec.unit.rawValue)"
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func color(for source: RestorePoint.Source) -> Color {
        switch source {
        case .latest, .checkpoint, .encryptedSnapshot: return .wpDesignYellow
        case .legacySnapshot: return .secondary
        }
    }
}
