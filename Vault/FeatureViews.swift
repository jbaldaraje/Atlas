import SwiftUI
import Charts
import VaultCore

struct FeatureWorkspace: View {
    let section: String
    let select: (UUID) -> Void
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    var body: some View {
        Group {
            switch section {
            case "Storage & Cleanup": StorageWorkspace(select: select)
            case "Secure Vault": SecureWorkspace()
            case "Recently Deleted": RecoveryWorkspace()
            default: EmptyView()
            }
        }.padding(.horizontal, 24).padding(.bottom, 20)
    }
}

private struct StorageFilterRequest: Equatable { let reportID: UUID?; let kind: FileKindFilter }
private struct RecoveryFilterRequest: Equatable { let trash: UUID; let retained: UUID; let kind: FileKindFilter }

struct StorageWorkspace: View {
    @EnvironmentObject private var trash: NativeTrashService
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    let select: (UUID) -> Void
    @AppStorage("fileKindFilter") private var fileKind = FileKindFilter.all
    @State private var prepared: StoragePresentation?
    @State private var mode: Int?
    @State private var selectedDuplicate: CatalogSource?
    @State private var duplicatePage = 0
    @State private var pending: FileItem?
    @State private var minimumMB = 0.0
    @State private var oldOnly = false
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Analyze & Verify Duplicates") { workspace.analyze(store.library.files) }.disabled(workspace.working)
                if workspace.working {
                    ProgressView().controlSize(.small)
                    if workspace.processingLabel == "Analyzing storage" { Button("Cancel") { workspace.cancel() } }
                }
            }
            Text("Only indexed regular files are analyzed. Hard links and duplicate references count once. Analysis covers the indexed library; the type filter changes displayed results. Original Trash actions require an additional exact-file grant. Results describe the last analysis, not the whole Mac.").font(.caption).foregroundStyle(.secondary)
            if let report = workspace.report {
                if let prepared, prepared.id == report.id, prepared.kind == fileKind { storageContent(prepared) }
                else { ProgressView("Preparing storage groups…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .task(id: StorageFilterRequest(reportID: workspace.report?.id, kind: fileKind)) {
            guard let report = workspace.report else { prepared = nil; return }
            let kind = fileKind
            let worker = Task.detached(priority: .userInitiated) { try StoragePresentation(report, kind: kind) }
            do {
                let next = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                let reportChanged = prepared?.id != report.id
                prepared = next; duplicatePage = 0
                if reportChanged { mode = nil; selectedDuplicate = nil }
                else if let selectedDuplicate { self.selectedDuplicate = next.duplicates.first { $0.id == selectedDuplicate.id } }
            } catch {}
        }.confirmationDialog("Review file removal", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if pending?.ownership == .managedCopy {
                Button("Move managed copy to recovery area", role: .destructive) { if let pending { workspace.retain(pending, library: store) }; pending = nil }
            } else {
                Button("Move Original to macOS Trash…", role: .destructive) { if let pending { trash.trash(pending, library: store); workspace.report = nil }; pending = nil }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text("\(pending?.filename ?? "")\n\(pending?.originalLocation ?? "")\nAll collection references use this file. Its index entry is removed after a recorded filesystem operation. Managed copies go to Vault recovery; originals go to macOS Trash after another grant. These recoverable operations do not reclaim space immediately.") }
    }
    private func bytes(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    @ViewBuilder private func storageContent(_ report: StoragePresentation) -> some View {
        if let mode {
            HStack {
                Button("Storage Groups") { self.mode = nil; selectedDuplicate = nil }
                Text(mode == 0 ? "Indexed parent folders" : "Verified duplicate groups").font(.headline)
            }
            if mode == 0 {
                HStack { Slider(value: $minimumMB, in: 0...1000); Text("Minimum \(Int(minimumMB)) MB"); Toggle("Not modified in 12 months", isOn: $oldOnly) }
                FolderBrowser(section: .files, minimumBytes: Int64(minimumMB * 1_000_000), old: oldOnly, sort: "Size", listMode: true,
                              source: report.source, select: select, cleanup: { pending = $0 })
            } else if let selectedDuplicate {
                Button("All Duplicate Groups") { self.selectedDuplicate = nil }
                Text("SHA-256 matches are review candidates. The current type filter may hide other copies; choose All Types to review every member.").font(.caption).foregroundStyle(.secondary)
                FolderBrowser(section: .files, listMode: true, source: selectedDuplicate, select: select, cleanup: { pending = $0 })
            } else {
                List(Array(report.duplicates.dropFirst(duplicatePage * 60).prefix(60)), id: \.id) { source in
                    Button { selectedDuplicate = source } label: { Label("Verified group · \(source.files.count) matching files", systemImage: "folder") }
                }
                HStack {
                    Button("Previous") { duplicatePage -= 1 }.disabled(duplicatePage == 0)
                    Text("Page \(duplicatePage + 1)").font(.caption)
                    Button("Next") { duplicatePage += 1 }.disabled((duplicatePage + 1) * 60 >= report.duplicates.count)
                }
            }
        } else {
            Text("Matching logical: \(bytes(report.logical)) · Allocated: \(bytes(report.allocated)) · Unavailable in full analysis: \(report.failed)").font(.headline)
            Chart(report.categories, id: \.type) { item in BarMark(x: .value("Logical bytes", item.size), y: .value("Type", item.type)).foregroundStyle(VaultStyle.lavender) }.frame(height: 200)
            Button { mode = 0 } label: { Label("Indexed parent folders · \(report.source.files.count.formatted()) files", systemImage: "folder.fill").frame(maxWidth: .infinity, alignment: .leading).padding(18) }
            Button { mode = 1 } label: { Label("Verified duplicate groups · \(report.duplicates.count.formatted()) groups", systemImage: "square.stack").frame(maxWidth: .infinity, alignment: .leading).padding(18) }
            Text("Open a group, then a parent folder. Individual cleanup actions appear in a file’s context menu and require confirmation. Allocated bytes are not guaranteed recoverable space on APFS.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

}

struct RecoveryWorkspace: View {
    @EnvironmentObject private var trash: NativeTrashService
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var recoveryFolder: Int?
    @State private var recoveryPage = 0
    @State private var pending: RecoveryEntry?
    @AppStorage("fileKindFilter") private var fileKind = FileKindFilter.all
    @State private var filteredTrash: [TrashEntry] = []
    @State private var filteredRecovery: [RecoveryEntry] = []
    @State private var applied: RecoveryFilterRequest?
    private var request: RecoveryFilterRequest { RecoveryFilterRequest(trash: trash.listingRevision, retained: workspace.recoveryListingRevision, kind: fileKind) }
    var body: some View {
        VStack(alignment: .leading) {
            Text("Recently Deleted · recovery locations").font(.headline)
            Text("These files still occupy disk space. Managed copies use Vault recovery; originals use macOS Trash. Finder can remove Trash items independently. Restoring never overwrites an existing file.").font(.caption).foregroundStyle(.secondary)
            if applied != request {
                ProgressView("Filtering recovery records…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if recoveryFolder == nil {
                Button { recoveryFolder = 0; recoveryPage = 0 } label: { Label("macOS Trash · \(filteredTrash.count.formatted()) tracked items", systemImage: "folder.fill").padding(18).frame(maxWidth: .infinity, alignment: .leading) }
                Button { recoveryFolder = 1; recoveryPage = 0 } label: { Label("Vault-managed recovery · \(filteredRecovery.count.formatted()) retained items", systemImage: "folder.fill").padding(18).frame(maxWidth: .infinity, alignment: .leading) }
                Spacer()
            } else {
                Button("Recovery Locations") { recoveryFolder = nil }
                List {
                    if recoveryFolder == 0 {
                        ForEach(Array(filteredTrash.dropFirst(recoveryPage * 60).prefix(60))) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.file.filename); Text(entry.file.originalLocation).font(.caption)
                                Text(entry.deletedAt.formatted()).font(.caption)
                                Button("Restore to Location…") { trash.restore(entry, library: store) }
                            }
                        }
                    } else {
                        ForEach(Array(filteredRecovery.dropFirst(recoveryPage * 60).prefix(60))) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.file.filename).font(.headline); Text(entry.file.originalLocation).font(.caption)
                                Text("Retained " + entry.date.formatted()).font(.caption)
                                HStack {
                                    Button("Restore") { workspace.restore(entry, library: store) }
                                    Button("Delete Permanently…", role: .destructive) { pending = entry }
                                }.disabled(workspace.working)
                            }
                        }
                    }
                }
                HStack {
                    Button("Previous") { recoveryPage -= 1 }.disabled(recoveryPage == 0)
                    Text("Page \(recoveryPage + 1)").font(.caption)
                    Button("Next") { recoveryPage += 1 }.disabled((recoveryPage + 1) * 60 >= (recoveryFolder == 0 ? filteredTrash.count : filteredRecovery.count))
                }
            }

        }.task { workspace.refreshRecovery(); trash.refresh() }
            .task(id: request) { await filterRecords() }
            .onChange(of: filteredTrash.count) { _, count in if recoveryFolder == 0 { recoveryPage = min(recoveryPage, max(0, (count - 1) / 60)) } }
            .onChange(of: filteredRecovery.count) { _, count in if recoveryFolder == 1 { recoveryPage = min(recoveryPage, max(0, (count - 1) / 60)) } }
            .confirmationDialog("Permanently delete retained copy?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("Delete Permanently", role: .destructive) { if let pending { workspace.permanentlyDelete(pending) }; pending = nil }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { Text("\(pending?.file.filename ?? "")\nOriginal managed location: \(pending?.file.originalLocation ?? "")\nThis retained copy cannot be recovered by Vault after deletion. The source outside Vault is unaffected.") }
    }
    private func filterRecords() async {
        let current = request, records = trash.entries, retained = workspace.recoveryEntries, kind = fileKind
        let worker = Task.detached(priority: .userInitiated) { () throws -> ([TrashEntry], [RecoveryEntry]) in
            let matchingTrash = try records.filter { record in try Task.checkCancellation(); return kind.includes(fileExtension: record.file.type) }
            let matchingRecovery = try retained.filter { record in try Task.checkCancellation(); return kind.includes(fileExtension: record.file.type) }
            return (matchingTrash, matchingRecovery)
        }
        do {
            let next = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard current == request else { return }
            filteredTrash = next.0; filteredRecovery = next.1; recoveryPage = 0; applied = current
        } catch {}
    }

}

private struct StoragePresentation: Sendable {
    struct Category: Sendable { let type: String; let size: Int64 }
    let id: UUID
    let kind: FileKindFilter
    let logical: Int64
    let allocated: Int64
    let failed: Int
    let categories: [Category]
    let source: CatalogSource
    let duplicates: [CatalogSource]
    init(_ report: StorageReport, kind: FileKindFilter) throws {
        id = report.id; self.kind = kind; failed = report.failedIDs.count
        let matching = try report.files.filter { entry in try Task.checkCancellation(); return kind.includes(fileExtension: entry.file.type) }
        logical = matching.reduce(0) { $0 + $1.file.size }; allocated = matching.reduce(0) { $0 + $1.allocated }
        let all = Dictionary(grouping: matching, by: { $0.file.type.uppercased() }).map { Category(type: $0.key, size: $0.value.reduce(0) { $0 + $1.file.size }) }.sorted { $0.size > $1.size }
        categories = Array(all.prefix(12)) + (all.count > 12 ? [Category(type: "Other types", size: all.dropFirst(12).reduce(0) { $0 + $1.size })] : [])
        let revision = UUID()
        source = CatalogSource(id: "storage", revision: revision, files: matching.map(\.file))
        duplicates = try report.duplicates.enumerated().compactMap { index, group in
            try Task.checkCancellation()
            let files = group.filter { kind.includes(fileExtension: $0.file.type) }.map(\.file)
            guard !files.isEmpty else { return nil }
            return CatalogSource(id: "duplicate-\(report.id)-\(index)", revision: revision, files: files)
        }

    }
}
