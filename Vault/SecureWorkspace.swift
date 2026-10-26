import SwiftUI
import VaultCore

struct SecureWorkspace: View {
    @EnvironmentObject private var secure: SecureStore
    @State private var title = ""
    @State private var username = ""
    @State private var secret = ""
    @State private var note = ""
    @State private var pending: SecureRecord?
    @State private var editingID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !secure.unlocked {
                ContentUnavailableView {
                    Label("Your private space", systemImage: "lock.shield")
                } description: { Text("Encrypted records are separate from your library. Unlock with Touch ID or your Mac’s authentication fallback. The local Keychain key is device-bound; copying the encrypted file alone is not a recoverable backup.") } actions: {
                    Button(secure.authenticating ? "Authenticating…" : "Unlock") { secure.unlock() }.disabled(secure.authenticating)
                }
            } else {
                HStack { Label("Unlocked · auto-lock after 2 minutes idle", systemImage: "lock.open"); Spacer(); Button("Lock Now") { secure.lock() } }
                Text("Clipboard clears after 20 seconds if unchanged, and on lock. Vault also locks when it loses focus, the session changes, or the Mac sleeps. Secrets may be visible to other apps while on the clipboard.").font(.caption).foregroundStyle(.secondary)
                List(secure.records) { record in
                    HStack {
                        VStack(alignment: .leading) { Text(record.title).font(.headline); Text(record.username).font(.caption) }
                        Spacer()
                        Button("Copy Secret") { secure.copy(record.secret) }
                        Button("Edit") { editingID = record.id; title = record.title; username = record.username; secret = record.secret; note = record.note; secure.touch() }
                        Button("Delete…", role: .destructive) { pending = record }
                    }
                }
                Form {
                    TextField("Title / website", text: $title)
                    TextField("Username", text: $username)
                    SecureField("Password, recovery code, or license key", text: $secret)
                    TextField("Private note", text: $note, axis: .vertical).lineLimit(3...6)
                    HStack {
                        Button(editingID == nil ? "Save Encrypted Record" : "Save Changes") {
                            var record = SecureRecord(title: title, username: username, secret: secret, note: note)
                            if let editingID { record.id = editingID }
                            secure.save(record)
                            if secure.error == nil { clear() }
                        }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Clear Editor") { clear() }
                    }
                }
            }
        }
        .onChange(of: title) { _, _ in secure.touch() }
        .onChange(of: username) { _, _ in secure.touch() }
        .onChange(of: secret) { _, _ in secure.touch() }
        .onChange(of: note) { _, _ in secure.touch() }
        .onChange(of: secure.unlocked) { _, unlocked in if !unlocked { clear(); pending = nil } }
        .onDisappear { secure.lock(); clear() }
        .alert("Secure Vault", isPresented: Binding(get: { secure.error != nil }, set: { if !$0 { secure.error = nil } })) { Button("OK") { secure.error = nil } } message: { Text(secure.error ?? "") }
        .confirmationDialog("Delete encrypted record permanently?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Delete Record", role: .destructive) { if let pending { secure.delete(pending.id) }; pending = nil; clear() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text("This record cannot be restored by Vault. External backups may still contain older encrypted versions.") }
    }
    private func clear() { title = ""; username = ""; secret = ""; note = ""; editingID = nil }
}

struct MonitoringWorkspace: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var exclusions: [UUID: String] = [:]
    @State private var editingLocation: ScanLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("APPROVED LOCATIONS").font(.caption.bold())
                Spacer()
                Button("Approve Folder…") { workspace.approveFolder() }.disabled(workspace.working || store.busy)
            }
            Text("Choose which file types to index in each approved folder. Polling runs every 30 seconds while Vault is open. Disconnect keeps existing index entries. Hidden files, packages, and symlinks are skipped.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(workspace.data.locations) { location in locationRow(location) }
        }
        .sheet(isPresented: $workspace.reviewFolder, onDismiss: workspace.cancelFolderReview) {
            FolderScanReview()
        }
        .sheet(item: $editingLocation) { location in
            LocationScanCategoryEditor(location: location)
        }
    }

    private func locationRow(_ location: ScanLocation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(location.name).font(.headline)
                Spacer()
                Toggle("Paused", isOn: pauseBinding(location))
                Button("Disconnect") { workspace.change { $0.locations.removeAll { $0.id == location.id } } }
            }
            HStack {
                Label(categorySummary(location), systemImage: "line.3.horizontal.decrease.circle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("File Types…") { editingLocation = location }
            }
            HStack {
                TextField("Excluded relative folders, comma separated", text: exclusionBinding(location))
                Button("Save Exclusions") { saveExclusions(location) }
            }
        }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    private func categorySummary(_ location: ScanLocation) -> String {
        if location.fileCategories == ScanFileCategory.all { return "All file types" }
        if location.fileCategories.isEmpty { return "No file types selected" }
        return ScanFileCategory.allCases.filter { location.fileCategories.contains($0) }.map(\.title).joined(separator: ", ")
    }
    private func pauseBinding(_ location: ScanLocation) -> Binding<Bool> {
        Binding(get: { location.paused }, set: { value in
            workspace.change { data in
                if let index = data.locations.firstIndex(where: { $0.id == location.id }) { data.locations[index].paused = value }
            }
        })
    }
    private func exclusionBinding(_ location: ScanLocation) -> Binding<String> {
        Binding(get: { exclusions[location.id] ?? location.excludes.joined(separator: ", ") }, set: { exclusions[location.id] = $0 })
    }
    private func saveExclusions(_ location: ScanLocation) {
        let input = exclusions[location.id] ?? location.excludes.joined(separator: ", ")
        let values = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            workspace.error = "Use relative subfolder paths without parent traversal."; return
        }
        workspace.change { data in
            if let index = data.locations.firstIndex(where: { $0.id == location.id }) { data.locations[index].excludes = values.filter { !$0.isEmpty } }
        }
    }
}

private struct ScanCategoryPicker: View {
    @Binding var selection: Set<ScanFileCategory>
    var counts: [ScanFileCategory: Int]? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("File types to include").font(.headline)
                Spacer()
                Button("All Types") { selection = ScanFileCategory.all }
                Button("None") { selection = [] }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(ScanFileCategory.allCases) { category in
                    Toggle(isOn: inclusionBinding(category)) {
                        HStack(spacing: 6) {
                            Label(category.title, systemImage: category.symbol)
                            if let counts { Text("(\(counts[category, default: 0]))").foregroundStyle(.secondary) }
                        }.font(.callout)
                    }.toggleStyle(.checkbox).help(category.detail)
                }
            }
            Text("Documents excludes PDFs. Media includes audio and video. Other includes archives and unrecognized types.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func inclusionBinding(_ category: ScanFileCategory) -> Binding<Bool> {
        Binding(get: { selection.contains(category) }, set: { included in
            if included { selection.insert(category) } else { selection.remove(category) }
        })
    }
}

private struct FolderScanReview: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    private var matches: [ImportCandidate] { workspace.matchingFolderCandidates }
    private var counts: [ScanFileCategory: Int] {
        Dictionary(grouping: workspace.folderCandidates, by: \.category).mapValues { $0.count }
    }
    private var totalBytes: Int64 { matches.reduce(0) { $0 + $1.size } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Index and monitor \(workspace.pendingLocation?.name ?? "folder")?").font(.title2)
            ScanCategoryPicker(selection: $workspace.scanCategories, counts: counts)
            Text("\(matches.count) of \(workspace.folderCandidates.count) files selected · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                .font(.headline)
            preview
            Text("Only matching file types will be indexed now and on future scans. Originals stay in place, and no content is extracted automatically. Review sensitive file names and locations before approving. Preview support varies by format.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { workspace.cancelFolderReview() }
                Spacer()
                Button("Index and Monitor") { workspace.confirmFolder(library: store) }
                    .disabled(workspace.scanCategories.isEmpty || store.busy)
            }
        }.padding(24).frame(width: 650)
    }
    @ViewBuilder private var preview: some View {
        if workspace.scanCategories.isEmpty {
            ContentUnavailableView("Choose at least one file type", systemImage: "line.3.horizontal.decrease.circle")
                .frame(height: 230)
        } else if matches.isEmpty {
            ContentUnavailableView("No matching files yet", systemImage: "doc.text.magnifyingglass", description: Text("You can still monitor this folder for new files of the selected types."))
                .frame(height: 230)
        } else {
            List(matches) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(entry.url.lastPathComponent); Spacer(); Text(entry.category.title).font(.caption).foregroundStyle(.secondary) }
                    Text(entry.url.path).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(height: 230)
        }
    }
}

private struct LocationScanCategoryEditor: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let location: ScanLocation
    @State private var categories: Set<ScanFileCategory>
    init(location: ScanLocation) {
        self.location = location
        _categories = State(initialValue: location.fileCategories)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("File types · \(location.name)").font(.title3.bold())
            ScanCategoryPicker(selection: $categories)
            Text("Changes apply to future scans of this folder. Previously indexed files stay in your library. No files are moved or deleted.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save File Types") {
                    if workspace.updateScanCategories(locationID: location.id, categories: categories) { dismiss() }
                }.disabled(categories.isEmpty || store.busy || workspace.working)
            }
        }.padding(24).frame(width: 590)
    }
}
