import SwiftUI
import VaultCore

@MainActor
final class AppleNotesStore: ObservableObject {
    @Published private(set) var accounts: [NotesAccount] = []
    @Published private(set) var folders: [NotesFolder] = []
    @Published private(set) var headers: [NotesHeader] = []
    @Published private(set) var working = false
    @Published private(set) var stage = ""
    @Published private(set) var completed = 0
    @Published private(set) var failures: [String] = []
    @Published private(set) var message: String?
    private let bridge = AppleNotesBridge()
    private var operation: Task<Void, Never>?
    func connect() {
        guard !working else { return }; accounts = []; folders = []; headers = []
        perform("Connecting to Apple Notes") { self.accounts = try self.bridge.accounts(); self.folders = []; self.headers = [] }
    }
    func loadFolders(accountID: String) {
        guard !working else { return }; folders = []; headers = []
        perform("Reading Notes folders") { self.folders = try self.bridge.folders(account: accountID); self.headers = [] }
    }
    func loadHeaders(accountID: String, folderID: String) {
        guard !working else { return }; headers = []
        perform("Reading note titles") { self.headers = try self.bridge.headers(account: accountID, folder: folderID) }
    }
    private func perform(_ label: String, action: @escaping @MainActor () throws -> Void) {
        guard !working else { return }
        working = true; stage = label; message = nil; failures = []
        operation = Task {
            defer { working = false; stage = "" }
            await Task.yield()
            do { try Task.checkCancellation(); try action() }
            catch is CancellationError { message = "Cancelled. Local snapshots were preserved." }
            catch { message = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel() }
    func importSelected(_ ids: Set<String>, account: NotesAccount, folder: NotesFolder, searchable: Bool, library: LibraryStore, workspace: WorkspaceStore) {
        guard !working, !library.busy, !workspace.working else { return }
        let allowed = headers.filter { ids.contains($0.id) && !$0.locked }.map(\.id)
        startImport(allowed, account: account, folder: folder, searchable: searchable, library: library, workspace: workspace)
    }
    func refresh(_ file: FileItem, library: LibraryStore, workspace: WorkspaceStore) {
        guard let source = file.noteSource, source.exportedFile != true, !working, !library.busy, !workspace.working else { return }
        startImport([source.noteID], account: NotesAccount(id: source.accountID, name: source.accountName), folder: NotesFolder(id: source.folderID, name: source.folderName), searchable: source.searchable == true, library: library, workspace: workspace)
    }
    private func startImport(_ ids: [String], account: NotesAccount, folder: NotesFolder, searchable: Bool, library: LibraryStore, workspace: WorkspaceStore) {
        guard !ids.isEmpty else { return }
        working = true; stage = "Importing Apple Notes"; completed = 0; message = nil; failures = []
        operation = Task {
            defer { working = false; stage = "" }
            for id in ids {
                do {
                    try Task.checkCancellation()
                    var snapshot = try bridge.read(account: account, folder: folder, id: id)
                    try Task.checkCancellation()
                    snapshot.source.searchable = searchable
                    let file = try await library.importNote(snapshot)
                    completed += 1
                    let text = snapshot.text
                    guard workspace.change({ data in
                        if searchable { data.extractedText[file.id] = text }
                        else { data.extractedText.removeValue(forKey: file.id) }
                    }) else { failures.append("Note saved, but its search preference could not be saved."); continue }
                } catch is CancellationError { message = "Cancelled. Completed snapshots were kept."; return }
                catch { failures.append(error.localizedDescription) }
                // NSAppleScript must run on the main thread. Yield between bounded Notes requests.
                await Task.yield()
            }
            message = "Imported/refreshed \(completed) notes. Failed: \(failures.count). Originals in Apple Notes were not changed."
        }
    }
}
