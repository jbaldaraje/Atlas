import SwiftUI
import VaultCore

struct NotesWorkspace: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var notes: AppleNotesStore
    let query: String
    let select: (UUID) -> Void
    let addNotes: () -> Void
    var initialNoteID: UUID?
    @State private var selectedID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: addNotes) { Label("Add iCloud / Apple Notes", systemImage: "note.text.badge.plus") }.disabled(notes.working || library.busy || workspace.working)
                Spacer()
                Text("Browse accounts → folders → notes").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.top, 18)
            Text("Notes are read from Apple Notes on this Mac. iCloud syncing is handled by macOS; Vault keeps snapshots and refreshes only when requested.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22)
            if let message = notes.message { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22) }
            FolderBrowser(section: .notes, query: query, listMode: true, select: { selectedID = $0 })
                .padding(.horizontal, 22).padding(.bottom, 18)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { selectedID = initialNoteID }
            .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Spacer(); Button("Done") { selectedID = nil } }.padding(16)
                    if let file = library.library.files.first(where: { $0.id == selectedID && $0.noteSource != nil }) {
                        NoteSnapshotReader(file: file, inspect: { select(file.id) }).id(file.id)
                    }
                }.frame(width: 760, height: 580)
            }
    }
}

private struct NoteSnapshotReader: View {
    @EnvironmentObject private var runtime: RuntimeController
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var notes: AppleNotesStore
    let file: FileItem
    let inspect: () -> Void
    @State private var text: String?
    @State private var error: String?
    @State private var preview = false
    @State private var truncated = false
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
                if truncated { Text("Showing a bounded text excerpt. Open Local Copy to read the entire note.").font(.caption).foregroundStyle(.secondary) }
                ScrollView { Text(text.isEmpty ? "This note has no plain text." : text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10) }
            } else if let error { Text(error).foregroundStyle(.secondary); Spacer() }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(22).frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(isPresented: $preview) { FilePreview(file: file) }
            .task(id: "\(runtime.windowVisible)-\(file.noteSource?.importedAt.timeIntervalSinceReferenceDate ?? 0)") {
                guard runtime.windowVisible else { text = nil; return }
                guard plainText else { return }
                text = nil; error = nil
                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        try FileAccessService.withAccess(file) { url -> (String, Bool) in
                            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                            let limit = 1024 * 1024
                            var data = try handle.read(upToCount: limit) ?? Data()
                            let actualSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                            let truncated = actualSize.map { $0 > data.count } ?? (data.count == limit)
                            for _ in 0..<4 {
                                if let text = String(data: data, encoding: .utf8) { return (text, truncated) }
                                if !data.isEmpty { data.removeLast() }
                            }
                            throw CocoaError(.fileReadInapplicableStringEncoding)
                        }
                    }
                    let loaded = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    try Task.checkCancellation(); text = loaded.0; truncated = loaded.1
                    workspace.recordOpened(file.id)
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
