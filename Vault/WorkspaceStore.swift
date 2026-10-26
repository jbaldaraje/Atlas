import SwiftUI
import AppKit
import VaultCore

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var data = Workspace()
    @Published var error: String?
    @Published var recoveryEntries: [RecoveryEntry] = []
    private let recovery = RecoveryService()
    @Published var working = false
    @Published var report: StorageReport?
    @Published var folderCandidates: [ImportCandidate] = []
    @Published var pendingLocation: ScanLocation?
    @Published var reviewFolder = false
    private let url = URL.applicationSupportDirectory.appendingPathComponent("Vault/workspace.json")
    private let analyzer = AnalysisService()
    private let extractor = ContentService()
    private var task: Task<Void, Never>?
    private var monitoring: Task<Void, Never>?
    private var writable = true
    init() {
        do {
            if FileManager.default.fileExists(atPath: url.path) { data = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url)) }
        } catch { writable = false; self.error = "Workspace data could not be read. Writes are disabled; restore a valid workspace.json before restarting." }
    }
    @discardableResult func change(_ body: (inout Workspace) -> Void) -> Bool {
        guard writable else { return false }
        var next = data; body(&next)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic); data = next; return true
        } catch { self.error = "Workspace changes could not be saved."; return false }
    }
    func analyze(_ files: [FileItem]) {
        guard !working else { return }; working = true
        task = Task {
            defer { working = false }
            do { report = try await analyzer.analyze(files, hash: true) }
            catch is CancellationError {} catch { self.error = "Analysis failed." }
        }
    }
    func cancel() { task?.cancel() }
    func extract(_ file: FileItem) {
        guard !working else { return }; working = true
        task = Task {
            defer { working = false }
            do { let text = try await extractor.extract(file, ocr: true); try Task.checkCancellation(); change { $0.extractedText[file.id] = text } }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func approveFolder() {
        guard !working else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Select one folder. Vault will preview regular files before indexing. Hidden files, packages, and symbolic links are excluded. Monitoring polls every 30 seconds while Vault is running."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        working = true
        task = Task {
            defer { working = false }
            do {
                let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let candidates = try await Self.enumerate(bookmark, excludes: [])
                folderCandidates = candidates; pendingLocation = ScanLocation(name: folder.lastPathComponent, bookmark: bookmark); reviewFolder = true
            } catch { self.error = error.localizedDescription }
        }
    }
    nonisolated static func enumerate(_ bookmark: Data, excludes: [String]) async throws -> [ImportCandidate] {
        let worker = Task.detached(priority: .utility) {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw FileAccessService.AccessError.staleBookmark }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            var traversalError: Error?
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in traversalError = error; return false }) else { throw CocoaError(.fileReadNoPermission) }
            var urls: [URL] = []
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let relative = String(url.path.dropFirst(folder.path.count + 1))
                if excludes.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { enumerator.skipDescendants(); continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values.isRegularFile == true { urls.append(url) }
                guard urls.count <= 10_000 else { throw ScanError.tooManyFiles }
            }
            if let traversalError { throw traversalError }
            return try await FileAccessService.inspect(urls)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    func startMonitoring(library: LibraryStore) {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self, weak library] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, let library, !Task.isCancelled else { return }
                if library.busy || self.working { continue }
                for location in self.data.locations where !location.paused {
                    do {
                        let entries = try await Self.enumerate(location.bookmark, excludes: location.excludes)
                        guard self.data.locations.contains(where: { $0.id == location.id && !$0.paused && $0.excludes == location.excludes }) else { continue }
                        await library.synchronize(entries, folderBookmark: location.bookmark)
                    } catch { self.error = "Monitoring \(location.name) failed. Pause, reconnect, or approve the folder again." }
                }
            }
        }
    }
    func confirmFolder(library: LibraryStore) {
        guard let location = pendingLocation else { return }
        guard change({ $0.locations.append(location) }) else { return }
        let candidates = folderCandidates; reviewFolder = false; pendingLocation = nil; folderCandidates = []
        Task { await library.synchronize(candidates, folderBookmark: location.bookmark) }
    }
    func refreshRecovery() {
        Task { do { recoveryEntries = try await recovery.list() } catch { self.error = "Recovery records could not be read. Files were preserved." } }
    }
    func retain(_ file: FileItem, library: LibraryStore) {
        guard !working else { return }; working = true
        Task {
            defer { working = false }
            do { try await recovery.retain(file); library.removeFromIndex(file.id); report = nil; refreshRecovery() }
            catch { self.error = error.localizedDescription }
        }
    }
    func restore(_ entry: RecoveryEntry, library: LibraryStore) {
        guard !working else { return }; working = true
        Task {
            defer { working = false }
            do {
                let file = try await recovery.restore(entry)
                if library.addRestored(file) { try await recovery.finish(entry); refreshRecovery() }
                else { self.error = "Restored copy remains on disk, but metadata could not be saved. The recovery payload was retained." }
            } catch { self.error = error.localizedDescription }
        }
    }
    func permanentlyDelete(_ entry: RecoveryEntry) {
        guard !working else { return }; working = true
        Task { defer { working = false }; do { try await recovery.finish(entry); refreshRecovery() } catch { self.error = error.localizedDescription } }
    }
    enum ScanError: LocalizedError {
        case tooManyFiles
        var errorDescription: String? { "Folder exceeds this build’s 10,000-file limit. Select a smaller folder; no partial scan was accepted." }
    }
}
