import AppKit
import SwiftUI
import VaultCore

struct OpenedFileEvent: Equatable { let id: UUID; let date: Date }

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var library = Library()
    @Published private(set) var openedEvent: OpenedFileEvent?
    @Published var candidates: [ImportCandidate] = []
    @Published var presentingImport = false
    @Published var busy = false
    @Published var progress = 0
    @Published var total = 0
    private var importTask: Task<Void, Never>?
    @Published var message: String?
    @Published var loadFailed = false
    @Published private(set) var operationFailed = false
    private let repository: LibraryRepository
    let managedDirectory: URL

    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Vault", isDirectory: true)) {
        repository = LibraryRepository(url: base.appendingPathComponent("library.json"))
        managedDirectory = base.appendingPathComponent("Files", isDirectory: true)
        do { library = try repository.load() }
        catch { loadFailed = true; message = "Library could not be loaded. It has been preserved. Restart after restoring a valid library.json in Vault’s Application Support directory." }
    }
    @discardableResult private func commit(_ next: Library) -> Bool {
        guard !loadFailed else { return false }
        do { try repository.save(next); library = next; operationFailed = false; return true }
        catch { operationFailed = true; message = "Metadata could not be saved. Your previous library remains unchanged."; return false }
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
    func prepare(_ urls: [URL]) {
        guard !busy, !loadFailed else { return }
        busy = true
        Task {
            defer { busy = false }
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
        let paths = Set(library.files.map(\.originalLocation))
        progress = 0; total = pending.count
        importTask = Task {
            let report = await FileAccessService.run(pending, copy: copy, managedDirectory: managedDirectory, existingPaths: paths, progress: { [weak self] count, total in Task { @MainActor in self?.progress = count; self?.total = total } })
            var next = library; next.files.append(contentsOf: report.items)
            let saved = commit(next); busy = false; importTask = nil; candidates = []
            guard saved else {
                message = "Metadata could not be saved. Original files are preserved. Any verified managed copies remain at \(managedDirectory.path); inspect this directory before retrying a copy import."
                return
            }
            operationFailed = !report.failures.isEmpty
            message = (report.cancelled ? "Import cancelled; completed items were retained. " : "") + "Added \(report.items.count) files. Skipped \(report.skipped) existing references. Failed: \(report.failures.count)." + (report.failures.isEmpty ? "" : " Retry by selecting these files again: " + report.failures.joined(separator: ", "))
        }
    }
    func cancelImport() { importTask?.cancel() }
    func addRestored(_ file: FileItem) -> Bool {
        var next = library
        next.files.removeAll { $0.id == file.id }; next.files.append(file)
        return commit(next)
    }
    @discardableResult func synchronize(_ entries: [ImportCandidate], folderBookmark: Data, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> CatalogSyncResult {
        guard !busy, !loadFailed else { return CatalogSyncResult(errors: ["Catalog is busy or unavailable."]) }
        busy = true
        defer { busy = false }
        var stale = false
        do {
            let folder = try URL(resolvingBookmarkData: folderBookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw FileAccessService.AccessError.staleBookmark }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            let report = await FileAccessService.run(entries, copy: false, managedDirectory: managedDirectory, existingPaths: [], progress: progress)
            var next = library
            for index in next.files.indices where next.files[index].fileIdentity == nil {
                next.files[index].fileIdentity = try? FileAccessService.withAccess(next.files[index]) { FileAccessService.identity(at: $0) }
            }
            let merge = next.mergeScanned(report.items)
            guard commit(next) else { return CatalogSyncResult(attempted: report.items.count + report.failures.count, errors: ["Catalog metadata could not be saved."]) }
            return CatalogSyncResult(merge: merge, attempted: report.items.count + report.failures.count, errors: report.failures.map { "Unavailable file: " + $0 })
        } catch { return CatalogSyncResult(errors: [error.localizedDescription]) }
    }
    @discardableResult func applyOrganization(_ facts: [OrganizationFacts], workspace: inout Workspace) -> OrganizationCounts? {
        var next = library
        let counts = OrganizationRules.apply(facts, library: &next, workspace: &workspace)
        guard commit(next) else { return nil }
        return counts
    }
    func open(_ file: FileItem) {
        Task {
            do {
                let opened = try await FileAccessService.withAsyncAccess(file) { url in
                    await withCheckedContinuation { continuation in
                        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                            continuation.resume(returning: app != nil && error == nil)
                        }
                    }
                }
                if opened { operationFailed = false; openedEvent = OpenedFileEvent(id: file.id, date: .now) }
                else { operationFailed = true; message = "The file could not be opened in its default application." }
            } catch { operationFailed = true; message = error.localizedDescription }
        }
    }
    func reveal(_ file: FileItem) {
        do { try FileAccessService.withAccess(file) { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
        catch { operationFailed = true; message = error.localizedDescription }
    }
}

struct CatalogSyncResult {
    var merge = CatalogMerge()
    var attempted = 0
    var errors: [String] = []
}
