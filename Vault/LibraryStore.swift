import AppKit
import SwiftUI
import VaultCore
import UniformTypeIdentifiers

struct OpenedFileEvent: Equatable { let id: UUID; let date: Date }

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var library = Library()
    private(set) var graphRevision = UUID()
    let catalogBrowser = CatalogBrowserEngine()
    let knowledgeGraph: KnowledgeGraphEngine
    @Published private(set) var openedEvent: OpenedFileEvent?
    @Published var candidates: [ImportCandidate] = []
    @Published var presentingImport = false
    @Published var busy = false
    @Published var progress = 0
    @Published var total = 0
    private var importingExportedNotes = false
    private var preparationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    @Published var message: String?
    @Published var loadFailed = false
    @Published private(set) var operationFailed = false
    private let repository: LibraryRepository
    let managedDirectory: URL
    private let notesWriter: NotesSnapshotService

    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Vault", isDirectory: true)) {
        knowledgeGraph = KnowledgeGraphEngine(base: base)
        repository = LibraryRepository(url: base.appendingPathComponent("library.json"))
        managedDirectory = base.appendingPathComponent("Files", isDirectory: true)
        notesWriter = NotesSnapshotService(root: managedDirectory)
        do { library = try repository.load() }
        catch { loadFailed = true; message = "Library could not be loaded. It has been preserved. Restart after restoring a valid library.json in Vault’s Application Support directory." }
    }
    @discardableResult private func commit(_ next: Library, graphChanged: Bool = true) -> Bool {
        guard !loadFailed else { return false }
        do {
            try repository.save(next)
            if graphChanged { graphRevision = UUID() }
            library = next; operationFailed = false; return true
        }
        catch { operationFailed = true; message = "Metadata could not be saved. Your previous library remains unchanged."; return false }
    }
    @discardableResult func commitEncoded(_ next: Library, bytes: Data, expectedRevision: UUID) -> Bool {
        guard !loadFailed, expectedRevision == graphRevision else { return false }
        do {
            try FileManager.default.createDirectory(at: repository.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: repository.url, options: .atomic)
            graphRevision = UUID(); library = next; operationFailed = false; return true
        } catch { operationFailed = true; message = "Catalog metadata could not be saved."; return false }
    }
    @discardableResult func update(_ file: FileItem) -> Bool {
        var next = library
        guard let index = next.files.firstIndex(where: { $0.id == file.id }) else { return false }
        next.files[index] = file; return commit(next)
    }
    func removeFromIndex(_ id: UUID) { var next = library; next.removeFromIndex(id); commit(next) }
    func addCollection(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var next = library; next.collections.append(FileCollection(name: name)); commit(next)
    }
    func chooseFiles() {
        guard !busy, !loadFailed else { return }
        let panel = NSOpenPanel()
        panel.title = "Add files to Vault"
        panel.message = "Only selected files are accessed. Originals stay in place unless you choose to create managed copies."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        prepare(panel.urls)
    }
    func chooseExportedNotes() {
        guard !busy, !loadFailed else { return }
        let panel = NSOpenPanel(); panel.title = "Import exported Apple Notes"
        panel.message = "Select notes exported from Apple Notes as PDF or text. They will appear in Notes and All Files; they are not linked to an iCloud source."
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .text, .rtf, .html]
        guard panel.runModal() == .OK else { return }
        prepare(panel.urls); importingExportedNotes = true
    }
    func prepare(_ urls: [URL]) {
        guard !busy, !loadFailed else { return }
        importingExportedNotes = false
        busy = true
        preparationTask = Task {
            defer { busy = false; preparationTask = nil }
            do { candidates = try await FileAccessService.inspect(urls); presentingImport = true }
            catch { operationFailed = true; message = error.localizedDescription }
        }
    }
    func bulk(ids: Set<UUID>, tags: [String] = [], collection: UUID? = nil, favorite: Bool = false, remove: Bool = false) {
        var next = library
        if remove { next.files.removeAll { ids.contains($0.id) } }
        else {
            for i in next.files.indices where ids.contains(next.files[i].id) {
                next.files[i].tags = Array(Set(next.files[i].tags + tags)).sorted()
                if let collection { next.files[i].collectionIDs.insert(collection) }
                if favorite { next.files[i].favorite = true }
            }
        }
        commit(next)
    }
    func performImport(copy: Bool) {
        presentingImport = false; busy = true
        let pending = candidates
        let exportedNotes = importingExportedNotes; importingExportedNotes = false
        let paths = Set(library.files.map(\.originalLocation))
        progress = 0; total = pending.count
        importTask = Task {
            let report = await FileAccessService.run(pending, copy: copy, managedDirectory: managedDirectory, existingPaths: paths, progress: { [weak self] count, total in Task { @MainActor in self?.progress = count; self?.total = total } })
            var next = library
            if exportedNotes {
                for var file in report.items {
                    var source = ImportedNoteSource(accountID: "exported-files", accountName: "Exported Notes", folderID: "exports", folderName: "File import", noteID: file.id.uuidString, title: URL(fileURLWithPath: file.filename).deletingPathExtension().lastPathComponent)
                    source.exportedFile = true; file.noteSource = source
                    ImportedNoteRules.register(file, in: &next)
                }
            } else { next.files.append(contentsOf: report.items) }
            let saved = commit(next); busy = false; importTask = nil; candidates = []
            guard saved else {
                message = "Metadata could not be saved. Original files are preserved. Any verified managed copies remain at \(managedDirectory.path); inspect this directory before retrying a copy import."
                return
            }
            operationFailed = !report.failures.isEmpty
            message = (report.cancelled ? "Import cancelled; completed items were retained. " : "") + "Added \(report.items.count) files. Skipped \(report.skipped) existing references. Failed: \(report.failures.count)." + (report.failures.isEmpty ? "" : " Retry by selecting these files again: " + report.failures.joined(separator: ", "))
        }
    }
    func cancelImport() { importTask?.cancel(); preparationTask?.cancel() }
    func shutdown() async { cancelImport(); await preparationTask?.value; await importTask?.value }
    func addRestored(_ file: FileItem) -> Bool {
        var next = library
        next.files.removeAll { $0.id == file.id }; next.files.append(file)
        return commit(next)
    }
    @discardableResult func synchronize(_ entries: [ImportCandidate], folderBookmark: Data, control: ScanControl? = nil, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> CatalogSyncResult {
        guard !busy, !loadFailed else { return CatalogSyncResult(errors: ["Catalog is busy or unavailable."]) }
        busy = true
        defer { busy = false }
        do {
            let resource = try await PreviewResource.resolve(bookmark: folderBookmark, directory: true)
            defer { withExtendedLifetime(resource) {} }
            let snapshot = library.files
            let known = await Task.detached(priority: .utility) {
                Dictionary(snapshot.map { ($0.originalLocation, $0) }, uniquingKeysWith: { a, _ in a })
            }.value
            let report = await FileAccessService.run(entries, copy: false, managedDirectory: managedDirectory, existingPaths: [], existingByPath: known, control: control, progress: progress)
            // Merge and encode away from the UI. Retry preparation if a user edits metadata meanwhile.
            while true {
                let snapshot = library, expectedRevision = graphRevision
                let prepared = await Task.detached(priority: .utility) { () -> (Library, CatalogMerge, Data?) in
                    var next = snapshot; let merge = next.mergeScanned(report.items)
                    let bytes: Data? = merge.added.isEmpty && merge.updated.isEmpty ? nil : try? JSONEncoder().encode(next)
                    return (next, merge, bytes)
                }.value
                guard expectedRevision == graphRevision else { continue }
                let merge = prepared.1
                if !merge.added.isEmpty || !merge.updated.isEmpty {
                    guard let bytes = prepared.2 else { return CatalogSyncResult(attempted: report.items.count + report.failures.count, errors: ["Catalog metadata could not be encoded."]) }
                    // The final atomic replacement remains synchronous, preserving existing transaction semantics.
                    guard commitEncoded(prepared.0, bytes: bytes, expectedRevision: expectedRevision) else {
                        return CatalogSyncResult(attempted: report.items.count + report.failures.count, errors: ["Catalog metadata could not be saved."])
                    }
                }
                return CatalogSyncResult(merge: merge, attempted: report.items.count + report.failures.count, errors: report.failures.map { "Unavailable file: " + $0 })
            }
        } catch { return CatalogSyncResult(errors: [error.localizedDescription]) }
    }
    @discardableResult func applyOrganization(_ facts: [OrganizationFacts], workspace: inout Workspace) -> OrganizationCounts? {
        var next = library
        let counts = OrganizationRules.apply(facts, library: &next, workspace: &workspace)
        guard commit(next) else { return nil }
        return counts
    }
    func importNote(_ snapshot: ImportedNoteSnapshot) async throws -> FileItem {
        guard !busy, !loadFailed else { throw NotesCatalogError.unavailable }
        busy = true; defer { busy = false }
        let id = ImportedNoteRules.existingID(for: snapshot.source, in: library) ?? UUID()
        let old = library.files.first { $0.id == id }
        var file = try await notesWriter.write(snapshot, id: id, existing: old)
        if let current = library.files.first(where: { $0.id == id }) {
            file.tags = current.tags; file.description = current.description
            file.collectionIDs = current.collectionIDs; file.favorite = current.favorite
        }
        var next = library; ImportedNoteRules.register(file, in: &next)
        guard commit(next), let saved = library.files.first(where: { $0.id == id }) else { throw NotesCatalogError.unavailable }
        if let old, !library.files.contains(where: { $0.id != id && $0.originalLocation == old.originalLocation }) {
            // Cleanup failure leaves the old copy on disk; it must never undo a successfully saved note.
            try? await notesWriter.discardSuperseded(old, replacedBy: file)
        }
        return saved
    }
    enum NotesCatalogError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The note catalog could not be saved or is busy. Any completed local snapshot and all Apple Notes originals were preserved. Retry when the library is available." }
    }
    func noteExcerpt(_ file: FileItem) async -> String? { try? await notesWriter.excerpt(file) }
    func toggleFavorite(_ id: UUID) {
        var next = library
        guard let index = next.files.firstIndex(where: { $0.id == id }) else { return }
        next.files[index].favorite.toggle(); commit(next)
    }
    func updateMetadata(_ id: UUID, description: String, tags: [String]) {
        var next = library
        guard let index = next.files.firstIndex(where: { $0.id == id }) else { return }
        next.files[index].description = description; next.files[index].tags = tags; commit(next)
    }
    func open(_ file: FileItem) {
        Task {
            do {
                let resource = try await PreviewResource.resolve(file)
                defer { withExtendedLifetime(resource) {} }
                let url = resource.url
                let opened = await withCheckedContinuation { continuation in
                        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                            continuation.resume(returning: app != nil && error == nil)
                        }
                    }
                try Task.checkCancellation()
                if opened { operationFailed = false; openedEvent = OpenedFileEvent(id: file.id, date: .now) }
                else { operationFailed = true; message = "The file could not be opened in its default application." }
            } catch { operationFailed = true; message = error.localizedDescription }
        }
    }
    func reveal(_ file: FileItem) {
        Task {
            do {
                let resource = try await PreviewResource.resolve(file)
                defer { withExtendedLifetime(resource) {} }
                try Task.checkCancellation(); NSWorkspace.shared.activateFileViewerSelecting([resource.url])
            } catch { operationFailed = true; message = error.localizedDescription }
        }
    }
}

struct CatalogSyncResult {
    var merge = CatalogMerge()
    var attempted = 0
    var errors: [String] = []
}
