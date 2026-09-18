//
//  @file        RestoreView.swift
//  @description Restore sheet: pick a restore point (and source, if several), browse/select files in a
//               custom lazy tree (compact rows, circular checks, indentation, hover/selection
//               highlight), choose a target and conflict policy, then restore. Checkpoints, the latest
//               state and legacy snapshots are browsed item by item; an encrypted snapshot is restored
//               whole. Ownership can't be restored (non-root) — noted in the footer.
//  @author      Kennt Kim
//  @company     Calida Lab
//  @created     2026-06-29
//  @lastUpdated 2026-09-18
//

import SwiftUI

struct RestoreView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let job: BackupJob
    let points: [RestorePoint]

    @State private var point: RestorePoint?
    @State private var sourceName: String
    @State private var selection = Set<String>()
    @State private var useOriginalLocation = true
    @State private var customTarget: URL?
    @State private var conflict: RestoreEngine.ConflictPolicy = .keepBoth
    @State private var isRestoring = false
    @State private var resultMessage: String?

    init(job: BackupJob, points: [RestorePoint]) {
        self.job = job
        self.points = points
        _point = State(initialValue: points.first)
        _sourceName = State(initialValue: job.sources.first?.lastPathComponent ?? "")
    }

    /// The selected point is restored whole (an encrypted snapshot), not item by item.
    private var restoresWhole: Bool { point.map { !$0.isBrowsable } ?? false }

    private var browser: (any RestoreBrowser)? {
        guard let point else { return nil }
        return model.coordinator.browser(jobID: job.id, point: point, sourceName: sourceName)
    }

    private var resolvedTarget: URL? {
        if restoresWhole { return customTarget }
        return useOriginalLocation ? job.sources.first { $0.lastPathComponent == sourceName } : customTarget
    }

    private func label(for point: RestorePoint) -> String {
        let time = point.time.formatted(date: .abbreviated, time: .shortened)
        switch point.source {
        case .latest: return "\(time) · Latest · \(point.fileCount) files"
        case .checkpoint: return "\(time) · \(point.fileCount) files"
        case .legacySnapshot: return "\(time) · Earlier snapshot · \(point.fileCount) files"
        case .encryptedSnapshot: return "\(time) · Encrypted · \(point.fileCount) files"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pickerBar
            Divider()
            treeSection
            Divider()
            footer
        }
        .frame(width: 700, height: 600)
        .onChange(of: point) { _, _ in selection.removeAll() }
        .onChange(of: sourceName) { _, _ in selection.removeAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.wpDesignYellow)
            Text("Restore").font(.headline)
            Spacer()
            if !selection.isEmpty {
                Button("Clear") { selection.removeAll() }.controlSize(.small)
            }
            Button("Close") { dismiss() }
        }
        .padding(16)
    }

    // MARK: - Snapshot / source pickers

    private var pickerBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Text("Restore point").foregroundStyle(.secondary)
                Picker("", selection: $point) {
                    ForEach(points) { point in
                        Text(label(for: point)).tag(point as RestorePoint?)
                    }
                }
                .labelsHidden()
            }
            if job.sources.count > 1 {
                HStack(spacing: 8) {
                    Text("Source").foregroundStyle(.secondary)
                    Picker("", selection: $sourceName) {
                        ForEach(job.sources, id: \.self) { Text($0.lastPathComponent).tag($0.lastPathComponent) }
                    }
                    .labelsHidden().frame(width: 160)
                }
            }
            Spacer()
            if !selection.isEmpty {
                Text("\(selection.count) selected").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - File tree

    @ViewBuilder
    private var treeSection: some View {
        if restoresWhole {
            ContentUnavailableView {
                Label("Encrypted Snapshot", systemImage: "lock.doc")
            } description: {
                Text("Encrypted backups restore the whole snapshot into a chosen folder. Per-file browsing is coming soon.")
            }
            .frame(maxHeight: .infinity)
        } else if let browser {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(browser.children(of: "")) { entry in
                        SnapshotTreeRow(entry: entry, depth: 0, browser: browser, selection: $selection)
                    }
                }
                .padding(8)
            }
        } else {
            ContentUnavailableView("No restore point", systemImage: "clock.badge.questionmark")
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Restore to").foregroundStyle(.secondary)
                if restoresWhole {
                    Button(customTarget?.lastPathComponent ?? "Choose folder…") {
                        customTarget = FolderPicker.pick(prompt: "Choose Restore Target",
                                                         message: "Restore the entire snapshot into this folder.")
                    }
                } else {
                    Picker("", selection: $useOriginalLocation) {
                        Text("Original location").tag(true)
                        Text("Another folder").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                    if !useOriginalLocation {
                        Button(customTarget?.lastPathComponent ?? "Choose…") {
                            customTarget = FolderPicker.pick(prompt: "Choose Restore Target",
                                                             message: "Restore selected items into this folder.")
                        }
                    }
                }
                Spacer()
            }

            if !restoresWhole {
                HStack(spacing: 10) {
                    Text("If a file exists").foregroundStyle(.secondary)
                    Picker("", selection: $conflict) {
                        ForEach(RestoreEngine.ConflictPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                    Spacer()
                }
            }

            HStack {
                Text("Ownership isn't restored — files will be owned by you.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let resultMessage {
                    Text(resultMessage).font(.callout).foregroundStyle(.secondary)
                }
                if isRestoring { ProgressView().controlSize(.small) }
                Button(restoresWhole
                       ? "Restore entire snapshot"
                       : "Restore \(selection.count) item\(selection.count == 1 ? "" : "s")") { performRestore() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wpDesignYellow)
                    .foregroundStyle(.black)
                    .disabled((restoresWhole ? false : selection.isEmpty)
                              || resolvedTarget == nil || isRestoring || point == nil)
            }
        }
        .padding(16)
    }

    // MARK: - Action

    private func performRestore() {
        guard let point, let target = resolvedTarget else { return }
        isRestoring = true
        resultMessage = nil

        if case let .encryptedSnapshot(dir) = point.source {
            Task {
                do {
                    try await model.coordinator.restoreEncrypted(jobID: job.id, snapshotDirName: dir, to: target)
                    isRestoring = false
                    resultMessage = "Restored snapshot to \(target.lastPathComponent)"
                } catch {
                    isRestoring = false
                    resultMessage = "Failed: " + BackupErrorMessage.describe(error)
                }
            }
            return
        }

        let rels = Array(selection)
        let conflictPolicy = conflict
        let src = sourceName
        Task {
            do {
                let outcome = try await model.coordinator.restore(
                    jobID: job.id, point: point, sourceName: src,
                    relPaths: rels, to: target, conflict: conflictPolicy, progress: { _ in })
                isRestoring = false
                var msg = "Restored \(outcome.restored)"
                if outcome.skipped > 0 { msg += ", skipped \(outcome.skipped)" }
                if !outcome.failed.isEmpty { msg += ", failed \(outcome.failed.count)" }
                resultMessage = msg
            } catch {
                isRestoring = false
                resultMessage = "Failed: " + BackupErrorMessage.describe(error)
            }
        }
    }
}

/// One row in the restore point's file tree. Custom (not List) for a compact, modern look: indentation
/// by depth, an animated chevron for directories, a circular check, and hover/selection highlight.
private struct SnapshotTreeRow: View {
    let entry: SnapshotEntry
    let depth: Int
    let browser: any RestoreBrowser
    @Binding var selection: Set<String>

    @State private var expanded = false
    @State private var children: [SnapshotEntry]?
    @State private var hovering = false

    private var isSelected: Bool { selection.contains(entry.relPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            rowContent
            if expanded {
                ForEach(children ?? []) { child in
                    SnapshotTreeRow(entry: child, depth: depth + 1, browser: browser, selection: $selection)
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 7) {
            Group {
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.wpDesignYellow : Color.secondary.opacity(0.4))
                .font(.body)
                .contentShape(Rectangle())
                .onTapGesture { toggleSelect() }

            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.wpDesignYellow : .secondary)
                .frame(width: 16)

            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(depth) * 16 + 8)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.wpDesignYellow.opacity(0.14)
                                 : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { entry.isDirectory ? toggleExpand() : toggleSelect() }
        .onHover { hovering = $0 }
    }

    private func toggleExpand() {
        if children == nil { children = browser.children(of: entry.relPath) }
        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
    }

    private func toggleSelect() {
        if isSelected { selection.remove(entry.relPath) } else { selection.insert(entry.relPath) }
    }
}
