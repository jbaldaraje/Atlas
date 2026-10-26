import SwiftUI

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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("APPROVED LOCATIONS").font(.caption.bold()); Spacer(); Button("Approve Folder…") { workspace.approveFolder() }.disabled(workspace.working) }
            Text("Polling runs every 30 seconds while Vault is open. Disconnect stops monitoring but keeps indexed files. Hidden files, packages, and symlinks are skipped. Content extraction always requires a separate action.").font(.caption).foregroundStyle(.secondary)
            ForEach(workspace.data.locations) { location in
                VStack(alignment: .leading) {
                    HStack {
                        Text(location.name).font(.headline)
                        Toggle("Paused", isOn: Binding(get: { location.paused }, set: { value in workspace.change { data in if let i = data.locations.firstIndex(where: { $0.id == location.id }) { data.locations[i].paused = value } } }))
                        Button("Disconnect") { workspace.change { $0.locations.removeAll { $0.id == location.id } } }
                    }
                    HStack {
                        TextField("Excluded relative folders, comma separated", text: Binding(get: { exclusions[location.id] ?? location.excludes.joined(separator: ", ") }, set: { exclusions[location.id] = $0 }))
                        Button("Save Exclusions") {
                            let values = (exclusions[location.id] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            guard values.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else { workspace.error = "Use relative subfolder paths without parent traversal."; return }
                            workspace.change { data in if let i = data.locations.firstIndex(where: { $0.id == location.id }) { data.locations[i].excludes = values.filter { !$0.isEmpty } } }
                        }
                    }
                }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .sheet(isPresented: $workspace.reviewFolder) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Index and monitor \(workspace.pendingLocation?.name ?? "folder")?").font(.title2)
                Text("\(workspace.folderCandidates.count) regular files · \(ByteCountFormatter.string(fromByteCount: workspace.folderCandidates.reduce(0) { $0 + $1.size }, countStyle: .file))")
                List(workspace.folderCandidates) { entry in VStack(alignment: .leading) { Text(entry.url.lastPathComponent); Text(entry.url.path).font(.caption).foregroundStyle(.secondary) } }.frame(height: 260)
                Text("Originals stay in place. No content is extracted automatically. Review sensitive file names and locations before approving. Native preview support varies by format. Existing file references are refreshed; inaccessible or externally deleted files remain indexed and show an access error when opened.").font(.caption)
                HStack {
                    Button("Cancel") { workspace.reviewFolder = false; workspace.pendingLocation = nil; workspace.folderCandidates = [] }
                    Spacer(); Button("Index and Monitor") { workspace.confirmFolder(library: store) }
                }
            }.padding(24).frame(width: 620)
        }
    }
}
