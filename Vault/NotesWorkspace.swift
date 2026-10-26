import SwiftUI
import VaultCore

struct NotesWorkspace: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var notes: AppleNotesStore
    let query: String
    let select: (UUID) -> Void
    let addNotes: () -> Void
    @State private var selectedID: UUID?
    private var files: [FileItem] {
        library.library.files.filter { file in
            guard let source = file.noteSource else { return false }
            return query.isEmpty || source.title.localizedCaseInsensitiveContains(query) ||
                (workspace.data.extractedText[file.id]?.localizedCaseInsensitiveContains(query) ?? false)
        }.sorted { ($0.noteSource?.sourceModifiedAt ?? $0.indexedAt) > ($1.noteSource?.sourceModifiedAt ?? $1.indexedAt) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: addNotes) { Label("Add iCloud / Apple Notes", systemImage: "note.text.badge.plus") }.disabled(notes.working || library.busy || workspace.working)
                Spacer()
                Text("\(files.count) local snapshots").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.top, 18)
            Text("Notes are read from Apple Notes on this Mac. iCloud syncing is handled by macOS; Vault keeps snapshots and refreshes only when requested.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22)
            if let message = notes.message { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22) }
            if files.isEmpty {
                ContentUnavailableView("Your notes, alongside your files", systemImage: "note.text", description: Text("Add notes from your iCloud account in Apple Notes, or import exported PDF/text notes through the same dialog."))
            } else { content }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var content: some View {
        HSplitView {
            List(files, selection: $selectedID) { file in
                VStack(alignment: .leading, spacing: 5) {
                    Label(file.noteSource?.title ?? file.filename, systemImage: "note.text").font(.callout).lineLimit(2)
                    Text(file.noteSource?.folderName ?? "Apple Notes").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 7).tag(file.id)
            }.frame(minWidth: 160, idealWidth: 210, maxWidth: 280).scrollContentBackground(.hidden)
            if let file = library.library.files.first(where: { $0.id == selectedID && $0.noteSource != nil }) {
                NoteSnapshotReader(file: file, inspect: { select(file.id) }).id(file.id)
            } else {
                ContentUnavailableView("Select a note", systemImage: "doc.text.magnifyingglass", description: Text("Read your imported snapshot here."))
            }
        }
    }
}

private struct NoteSnapshotReader: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var notes: AppleNotesStore
    let file: FileItem
    let inspect: () -> Void
    @State private var text: String?
    @State private var error: String?
    @State private var preview = false
    private var plainText: Bool { ["txt", "md", "markdown"].contains(file.type.lowercased()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(file.noteSource?.title ?? file.filename).font(.title2.weight(.medium)).textSelection(.enabled)
            if let source = file.noteSource {
                Text(source.accountName + " · " + source.folderName).font(.caption).foregroundStyle(.secondary)
                Text((source.exportedFile == true ? "File imported " : "Snapshot refreshed ") + source.importedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                if file.noteSource?.exportedFile != true {
                    Button("Refresh from Notes") { notes.refresh(file, library: library, workspace: workspace) }.disabled(notes.working || library.busy || workspace.working)
                }
                if !plainText { Button("Preview Note") { preview = true } }
                Button("Inspect", action: inspect)
                Button("Open Local Copy") { library.open(file) }
            }.controlSize(.small)
            Divider()
            if !plainText {
                Text("Use Preview Note to read this exported document with native Quick Look.").foregroundStyle(.secondary)
                Spacer()
            } else if let text {
                ScrollView { Text(text.isEmpty ? "This note has no plain text." : text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10) }
            } else if let error { Text(error).foregroundStyle(.secondary); Spacer() }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(22).frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(isPresented: $preview) { FilePreview(file: file) }
            .task(id: file.noteSource?.importedAt) {
                guard plainText else { return }
                text = nil; error = nil
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) {
                        try FileAccessService.withAccess(file) { try String(contentsOf: $0, encoding: .utf8) }
                    }.value
                    try Task.checkCancellation(); text = loaded
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
    }
}

struct AppleNotesImportSheet: View {
    @EnvironmentObject private var notes: AppleNotesStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let exportedFiles: () -> Void
    @State private var accountID: String?
    @State private var folderID: String?
    @State private var selectedIDs: Set<String> = []
    @State private var searchable = false
    private var account: NotesAccount? { notes.accounts.first { $0.id == accountID } }
    private var folder: NotesFolder? { notes.folders.first { $0.id == folderID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add iCloud / Apple Notes").font(.title2.weight(.medium))
            Text("Choose the iCloud account already synced in Apple Notes on your Mac. macOS will ask to let Vault control Notes; Vault only reads the notes you explicitly select. No Apple ID password is requested.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(notes.accounts.isEmpty ? "Connect to Apple Notes" : "Reconnect") { accountID = nil; folderID = nil; selectedIDs = []; notes.connect() }.disabled(notes.working)
                Button("Import Exported PDF / Text…") { dismiss(); exportedFiles() }.disabled(notes.working)
            }
            selectors
            if !notes.headers.isEmpty { selectionActions }
            noteList
            Toggle("Make imported note text searchable in Vault", isOn: $searchable).disabled(notes.working)
            Text("Imports are unencrypted local plain-text snapshots in the regular library. Formatting, attachments, drawings, and checklists are not preserved. Locked notes are excluded. Locking the original later will not lock an already imported snapshot. Refresh updates the local snapshot only; Apple Notes originals stay unchanged.").font(.caption).foregroundStyle(.secondary)
            if let message = notes.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !notes.failures.isEmpty {
                DisclosureGroup("Import issues · \(notes.failures.count)") {
                    ScrollView { VStack(alignment: .leading) { ForEach(Array(notes.failures.enumerated()), id: \.offset) { _, message in Text(message).font(.caption) } } }.frame(maxHeight: 90)
                }
            }
            footer
        }.padding(26).frame(width: 680)
            .interactiveDismissDisabled(notes.working)
            .onChange(of: accountID) { _, id in folderID = nil; selectedIDs = []; if let id { notes.loadFolders(accountID: id) } }
            .onChange(of: folderID) { _, id in selectedIDs = []; if let accountID, let id { notes.loadHeaders(accountID: accountID, folderID: id) } }
    }
    private var selectors: some View {
        VStack(alignment: .leading) {
            Picker("Account", selection: $accountID) {
                Text("Choose an account (iCloud or local)").tag(nil as String?)
                ForEach(notes.accounts) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(notes.working || notes.accounts.isEmpty)
            Picker("Folder", selection: $folderID) {
                Text("Choose a folder").tag(nil as String?)
                ForEach(notes.folders) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(notes.working || accountID == nil)
        }
    }
    private var selectionActions: some View {
        HStack {
            Button("Select All Unlocked") { selectedIDs = Set(notes.headers.filter { !$0.locked }.map(\.id)) }
            Button("Clear") { selectedIDs = [] }
            Spacer(); Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(.secondary)
        }.disabled(notes.working)
    }
    private var noteList: some View {
        List(notes.headers) { header in
            Toggle(isOn: Binding(get: { selectedIDs.contains(header.id) }, set: { value in
                if value { selectedIDs.insert(header.id) } else { selectedIDs.remove(header.id) }
            })) {
                Label(header.title + (header.locked ? " · Locked / unavailable" : ""), systemImage: header.locked ? "lock" : "note.text")
            }.toggleStyle(.checkbox).disabled(header.locked || notes.working)
        }.frame(height: 175)
    }
    private var footer: some View {
        HStack {
            Button("Done") { dismiss() }.disabled(notes.working)
            if notes.working { ProgressView().controlSize(.small); Text(notes.stage).font(.caption); Button("Cancel") { notes.cancel() } }
            Spacer()
            Button("Import Selected") {
                if let account, let folder { notes.importSelected(selectedIDs, account: account, folder: folder, searchable: searchable, library: library, workspace: workspace) }
            }.disabled(notes.working || library.busy || workspace.working || selectedIDs.isEmpty || account == nil || folder == nil)
        }
    }
}
