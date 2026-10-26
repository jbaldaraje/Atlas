import SwiftUI
import VaultCore

/// Extends the existing review workflow, using the same picker, indexer, category controls, and graph.
struct FolderScanReview: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let select: (UUID) -> Void
    let openMap: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch workspace.scanPresentation {
            case .configuration: configuration
            case .progress: progress
            case .results: results
            }
        }.padding(24).frame(width: 690)
            .background { ObservatoryBackground(grid: workspace.scanIsActive) }
            .interactiveDismissDisabled(workspace.scanIsActive)
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan Folders").font(.title2.weight(.medium))
            Text("Review your sources and file types before Start Scan. Originals remain in place.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workspace.pendingLocations) { source in
                        Label(source.sourcePath ?? source.name, systemImage: "folder").font(.caption).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 95)
            ScanCategoryPicker(selection: $workspace.scanCategories)
            Text("A counting pass measures matching files before batch processing, with no file-count cap. Hidden files, packages, excluded folders, and symbolic links are skipped. All file types can be cataloged; previews and text support vary.").font(.caption).foregroundStyle(.secondary)
            Toggle("Enable / update monitoring for selected folders after scanning", isOn: $workspace.scanMonitorFolders)
            Text("Leave monitoring off to preserve any existing folder monitoring preferences.").font(.caption).foregroundStyle(.secondary)
            Toggle("Extract supported document text locally for topic suggestions", isOn: $workspace.scanExtractText)
            Toggle("Use available photo GPS metadata for approximate area groups", isOn: $workspace.scanIncludeGPS)
            Text("Text extraction stores searchable plaintext in your regular library. GPS groups can expose where photos were taken. Both options are local and optional. Topic suggestions are rule-based and editable; uncertain items go to Needs Review.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { workspace.cancelFolderReview() }
                Button("Change Folders…") { workspace.approveFolder() }
                Spacer()
                Button("Start Scan") { workspace.startFolderScan(library: store) }
                    .buttonStyle(CinematicButtonStyle(prominent: true))
                    .disabled(workspace.scanCategories.isEmpty || workspace.pendingLocations.isEmpty || workspace.working || store.busy)
            }
        }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Scanning your folders").font(.title2.weight(.medium))
                Spacer()
                Button { workspace.minimizeScan() } label: { Label("Minimize", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .help("Keep scanning while you navigate Vault").accessibilityIdentifier("minimizeScan")
            }
            if let scan = workspace.activeScan {
                HStack(spacing: 24) {
                    ScanRadar(scan: scan)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(workspace.scanCancellationRequested ? "Cancelling safely…" : scan.stage.title).font(.headline)
                        Text(workspace.scanCurrentFile).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        Label("Local processing · Originals stay in place", systemImage: "checkmark.shield").font(.caption).foregroundStyle(VaultStyle.teal)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(18).glassSurface(radius: 16, tint: VaultStyle.teal)
                ScanProgressMeter(scan: scan)
                scanNumbers(scan)
                Text("Minimize to keep browsing while scanning continues. Keep Vault open; completed catalog entries are kept if you cancel.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(workspace.scanCancellationRequested ? "Cancelling…" : "Cancel Scan") { workspace.cancelScan() }
                    .disabled(workspace.scanCancellationRequested)
            }
        }.frame(minHeight: 260)
    }
    @ViewBuilder private var results: some View {
        if let scan = workspace.data.lastScan {
            resultContent(scan)
        } else {
            Text("No scan results are available.")
            Button("Done") { dismiss() }
        }
    }
    private func resultContent(_ scan: ScanJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(scan.stage == .completed && !scan.errors.isEmpty ? "Scan finished · review issues" : resultTitle(scan.stage)).font(.title2.weight(.medium))
            ScanProgressMeter(scan: scan, compact: true)
            scanNumbers(scan)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                summary("Catalog files added", scan.addedIDs.count)
                summary("Subjects detected", scan.subjectIDs.count)
                summary("Photo date groups created", scan.photoDateGroups)
                summary("Photo GPS groups created", scan.photoLocationGroups)
                summary("Graph connections added", scan.relationshipCount)
                summary("Items needing review", scan.reviewIDs.count)
            }
            if let duplicateCount = scan.possibleDuplicateGroups {
                Text("\(duplicateCount) possible duplicate size groups. Content equality is not verified; use Storage & Cleanup for SHA-256 verification.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Duplicate review did not complete.").font(.caption).foregroundStyle(.secondary) }
            if !scan.errors.isEmpty {
                DisclosureGroup("Unavailable items / errors · \(scan.errors.count)") {
                    ScrollView { VStack(alignment: .leading) { ForEach(Array(scan.errors.prefix(100).enumerated()), id: \.offset) { _, message in Text(message).font(.caption) } } }.frame(maxHeight: 100)
                }
            }
            resultLinks(scan)
            HStack {
                Button("Done") { dismiss() }
                Button("Retry Scan") { workspace.retryScan(library: store) }.disabled(workspace.working || store.busy)
                Spacer()
                Button("Open Knowledge Map") { openMap(); dismiss() }
            }
        }
    }
    private func resultLinks(_ scan: ScanJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.library.files.filter { scan.catalogIDs.contains($0.id) }.prefix(30)) { file in
                    Button { select(file.id); dismiss() } label: {
                        Label(file.filename + (scan.reviewIDs.contains(file.id) ? " · Needs Review" : ""), systemImage: VaultStyle.fileSymbol(file.type)).font(.caption)
                    }.buttonStyle(.plain)
                }
                ForEach(workspace.data.subjects.filter { scan.subjectIDs.contains($0.id) }) { subject in
                    Button { select(subject.id); dismiss() } label: { Label(subject.name, systemImage: "sparkle").font(.caption) }.buttonStyle(.plain)
                }
                ForEach(store.library.collections.filter { scan.groupIDs.contains($0.id) }.prefix(20)) { group in
                    Button { select(group.id); dismiss() } label: { Label(group.name, systemImage: "square.stack").font(.caption) }.buttonStyle(.plain)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 160)
    }
    private func scanNumbers(_ scan: ScanJob) -> some View {
        HStack(spacing: 18) {
            summary("Entries discovered", scan.discovered)
            summary("Files processed", scan.processed)
            summary("Skipped / unchanged", scan.skipped)
            summary("Errors", scan.errors.count)
        }
    }
    private func summary(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text("\(value)").font(.title3.monospacedDigit()); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func resultTitle(_ stage: ScanStage) -> String {
        switch stage {
        case .cancelled: "Scan cancelled · completed entries kept"
        case .interrupted: "Scan interrupted · retry safely"
        case .failed: "Scan needs attention"
        default: "Scan complete"
        }
    }
}
