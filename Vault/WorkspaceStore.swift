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
    @Published var pendingLocations: [ScanLocation] = []
    @Published var reviewFolder = false
    @Published var scanCategories: Set<ScanFileCategory> = ScanFileCategory.all
    @Published var scanExtractText = false
    @Published var scanIncludeGPS = false
    @Published var scanMonitorFolders = true
    @Published var scanPresentation: ScanPresentation = .configuration
    @Published var activeScan: ScanJob?
    @Published var scanCurrentFile = ""
    var scanIsActive: Bool { activeScan?.stage.isRunning == true && working }
    let organizer = SmartOrganizationService()
    let scanAnalyzer = AnalysisService()
    var scanTask: Task<Void, Never>?
    var scanSourceID: UUID?
    private let url: URL
    private let analyzer = AnalysisService()
    private let extractor = ContentService()
    private var task: Task<Void, Never>?
    private var monitoring: Task<Void, Never>?
    private var writable = true
    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Vault", isDirectory: true)) {
        url = base.appendingPathComponent("workspace.json")
        do {
            if FileManager.default.fileExists(atPath: url.path) { data = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url)) }
            if var interrupted = data.lastScan, interrupted.stage.isRunning {
                interrupted.stage = .interrupted
                change { $0.lastScan = interrupted }
            }
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
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.message = "Select the folders to scan. Next, choose file types and review options before Start Scan. Originals stay in place."
        guard panel.runModal() == .OK else { return }
        do {
            pendingLocations = try panel.urls.map { folder in
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let identity = FileAccessService.identity(at: folder)
                var location = data.locations.first { matchesSource($0, folder: folder, identity: identity) } ?? ScanLocation(name: folder.lastPathComponent, bookmark: bookmark)
                location.name = folder.lastPathComponent; location.bookmark = bookmark; location.sourcePath = folder.standardizedFileURL.path; location.sourceIdentity = identity
                return location
            }
            scanCategories = pendingLocations.reduce(into: Set<ScanFileCategory>()) { $0.formUnion($1.fileCategories) }
            scanExtractText = pendingLocations.allSatisfy(\.extractContent)
            scanIncludeGPS = pendingLocations.allSatisfy { $0.includePhotoLocations == true }
            scanMonitorFolders = pendingLocations.contains { source in !data.locations.contains { $0.id == source.id } }
            scanPresentation = .configuration; reviewFolder = true
        } catch { self.error = "Folder access could not be saved. Select the folders again." }
    }
    private func matchesSource(_ source: ScanLocation, folder: URL, identity: String?) -> Bool {
        if let identity, source.sourceIdentity == identity { return true }
        if source.sourcePath == folder.standardizedFileURL.path { return true }
        var stale = false
        guard let existing = try? URL(resolvingBookmarkData: source.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
        return existing.standardizedFileURL == folder.standardizedFileURL
    }
    func startMonitoring(library: LibraryStore) {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self, weak library] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, let library, !Task.isCancelled else { return }
                if library.busy || self.working { continue }
                self.working = true
                for location in self.data.locations where !location.paused {
                    do {
                        let entries = try await FileAccessService.scanFolder(location.bookmark, excludes: location.excludes, categories: location.fileCategories)
                        guard self.data.locations.contains(where: { $0.id == location.id && !$0.paused && $0.excludes == location.excludes && $0.fileCategories == location.fileCategories }) else { continue }
                        let synced = await library.synchronize(entries, folderBookmark: location.bookmark)
                        if !synced.errors.isEmpty { self.error = synced.errors.joined(separator: "\n") }
                        var facts: [OrganizationFacts] = []
                        var texts: [UUID: String] = [:]
                        for file in library.library.files where synced.merge.fileIDs.contains(file.id) {
                            guard self.data.locations.contains(where: { $0.id == location.id && !$0.paused && $0.extractContent == location.extractContent && $0.includePhotoLocations == location.includePhotoLocations }) else { break }
                            if self.needsOrganization(file, source: location) {
                                let result = try await self.organizer.facts(for: file, source: location, existingSubjects: self.data.subjects.map(\.name))
                                facts.append(result.0); if let text = result.1 { texts[file.id] = text }
                            }
                        }
                        self.commitOrganization(facts, texts: texts, library: library)
                    } catch { self.error = "Monitoring \(location.name) failed. Pause, reconnect, or approve the folder again." }
                }
                self.working = false
            }
        }
    }
    func cancelFolderReview() {
        guard !scanIsActive else { return }
        reviewFolder = false; pendingLocations = []; scanCategories = ScanFileCategory.all
    }
    @discardableResult func updateScanCategories(locationID: UUID, categories: Set<ScanFileCategory>) -> Bool {
        guard !categories.isEmpty else { return false }
        guard data.locations.contains(where: { $0.id == locationID }) else {
            error = "This folder was disconnected. Approve it again to configure monitoring."; return false
        }
        return change { workspace in
            guard let index = workspace.locations.firstIndex(where: { $0.id == locationID }) else { return }
            workspace.locations[index].includedCategories = categories
            workspace.locations[index].categoryVersion = 2
        }
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

}
