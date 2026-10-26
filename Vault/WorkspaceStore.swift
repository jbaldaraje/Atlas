import SwiftUI
import AppKit
import VaultCore
import Combine

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var data = Workspace()
    private(set) var graphRevision = UUID()
    private(set) var browserRevision = UUID()
    private(set) var activityRevision = UUID()
    @Published var error: String?
    private(set) var recoveryListingRevision = UUID()
    @Published var recoveryEntries: [RecoveryEntry] = [] { didSet { recoveryListingRevision = UUID() } }
    private let recovery = RecoveryService()
    @Published var working = false
    @Published private(set) var monitoringActive = false
    @Published private(set) var processingLabel: String?
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
    @Published var scanMinimized = false
    @Published var scanCancellationRequested = false
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
    private var monitorConfiguration: Task<Void, Never>?
    private var monitorSubscriptions: Set<AnyCancellable> = []
    private let folderEvents = FolderEventMonitor()
    private var monitoringChanges = MonitoringChanges()
    private var monitoringSuspended = false
    private weak var monitoredLibrary: LibraryStore?
    let scanControl = ScanControl()
    let scanJournal: ScanJournal
    var scanJournalReadable = true
    @Published var scanPaused = false
    private var writable = true
    private(set) var mutationRevision = UUID()
    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Vault", isDirectory: true)) {
        url = base.appendingPathComponent("workspace.json")
        scanJournal = ScanJournal(base: base)
        do {
            if FileManager.default.fileExists(atPath: url.path) { data = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url)) }
            let journalURL = ScanJournal.url(base: base)
            if FileManager.default.fileExists(atPath: journalURL.path) {
                do { data.lastScan = try JSONDecoder().decode(ScanJob.self, from: Data(contentsOf: journalURL)) }
                catch { scanJournalReadable = false; self.error = "The scan journal could not be read. It was preserved; repair it before starting another scan." }
            }
            if var interrupted = data.lastScan, interrupted.stage.isRunning {
                interrupted.stage = .interrupted
                interrupted.paused = false; data.lastScan = interrupted
                // Do not rewrite the large workspace on launch. The next explicit scan journals its state.
            }
        } catch { writable = false; scanJournalReadable = false; self.error = "Workspace data could not be read. Writes are disabled; restore a valid workspace.json before restarting." }
    }
    @discardableResult func change(_ body: (inout Workspace) -> Void) -> Bool {
        guard writable else { return false }
        var next = data; body(&next)
        guard next != data else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            if next.subjects != data.subjects || next.relationships != data.relationships { graphRevision = UUID() }
            if next.subjects != data.subjects || next.sessions != data.sessions || next.locations != data.locations || next.extractedText != data.extractedText || next.lastScan?.sources != data.lastScan?.sources { browserRevision = UUID() }
            if next.openedFiles != data.openedFiles { activityRevision = UUID() }
            mutationRevision = UUID(); data = next; return true
        } catch { self.error = "Workspace changes could not be saved."; return false }
    }
    /// Call only after a successful default-app open or an explicitly requested note read.
    func recordOpened(_ id: UUID, at date: Date = .now) {
        guard (data.openedFiles?[id] ?? .distantPast) < date else { return }
        change { $0.openedFiles = ($0.openedFiles ?? [:]).merging([id: date], uniquingKeysWith: max) }
    }
    func analyze(_ files: [FileItem]) {
        guard !working else { return }; working = true; processingLabel = "Analyzing storage"
        task = Task {
            defer { working = false; processingLabel = nil }
            do { report = try await analyzer.analyze(files, hash: true) }
            catch is CancellationError {} catch { self.error = "Analysis failed." }
        }
    }
    func cancel() { task?.cancel() }
    func extract(_ file: FileItem) {
        guard !working else { return }; working = true; processingLabel = "Extracting document text"
        task = Task {
            defer { working = false; processingLabel = nil }
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
            scanMinimized = false; scanPresentation = .configuration; reviewFolder = true
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
        guard monitoredLibrary == nil else { return }
        monitoredLibrary = library
        var previousFiles = library.library.files
        library.$library.dropFirst().sink { [weak self] next in
            self?.reconcileCatalog(previous: previousFiles, library: next)
            previousFiles = next.files
        }.store(in: &monitorSubscriptions)
        library.$openedEvent.compactMap { $0 }.sink { [weak self] event in self?.recordOpened(event.id, at: event.date) }.store(in: &monitorSubscriptions)
        $data.map(\.locations).removeDuplicates().sink { [weak self] locations in self?.configureMonitoring(locations) }.store(in: &monitorSubscriptions)
        library.$busy.removeDuplicates().filter { !$0 }.sink { [weak self] _ in self?.scheduleMonitoring() }.store(in: &monitorSubscriptions)
        $working.removeDuplicates().filter { !$0 }.sink { [weak self] _ in self?.scheduleMonitoring() }.store(in: &monitorSubscriptions)
    }
    private func reconcileCatalog(previous: [FileItem], library: Library) {
        let ids = Set(library.files.map(\.id)), collections = Set(library.collections.map(\.id))
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        change { data in
            data.reconcile(validIDs: ids, additionalGraphIDs: collections)
            for file in library.files where file.noteSource == nil && (old[file.id]?.modifiedAt != file.modifiedAt || old[file.id]?.changeSignature != file.changeSignature) {
                data.extractedText.removeValue(forKey: file.id)
            }
        }
    }
    private func configureMonitoring(_ updatedLocations: [ScanLocation]? = nil) {
        let locations = updatedLocations ?? data.locations
        guard !monitoringSuspended else { return }
        monitoringChanges.reconcile(enabled: Set(locations.filter { !$0.paused }.map(\.id)))
        monitorConfiguration?.cancel()
        monitorConfiguration = Task { [weak self] in
            guard let self else { return }
            let errors = await self.folderEvents.configure(locations) { [weak self] id in
                guard let self else { return }
                self.monitoringChanges.mark(id); self.scheduleMonitoring()
            }
            guard !Task.isCancelled else { return }
            if !errors.isEmpty { self.error = errors.joined(separator: "\n") }
        }
    }
    private func scheduleMonitoring() {
        guard !monitoringSuspended, monitoring == nil, !monitoringChanges.dirty.isEmpty else { return }
        monitoring = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { self?.monitoring = nil; self?.scheduleMonitoring(); return }
            guard let self else { return }
            guard let library = self.monitoredLibrary, !library.busy, !self.working else { self.monitoring = nil; return }
            defer { self.monitoring = nil; self.scheduleMonitoring() }
            let ids = self.monitoringChanges.take()
            self.working = true; self.monitoringActive = true
            for location in self.data.locations where ids.contains(location.id) && !location.paused {
                do { try await self.refreshMonitoredFolder(location, library: library) }
                catch is CancellationError { break }
                catch { self.error = "Monitoring a folder failed. Reconnect its volume or approve the folder again." }
            }
            self.working = false; self.monitoringActive = false
        }
    }
    func suspendMonitoring() {
        monitoringSuspended = true; monitoring?.cancel(); monitorConfiguration?.cancel(); folderEvents.stop()
    }
    func resumeMonitoring() { monitoringSuspended = false; configureMonitoring(); scheduleMonitoring() }
    func publishScanCheckpoint(_ job: ScanJob) {
        if data.lastScan?.sources != job.sources { browserRevision = UUID() }
        mutationRevision = UUID(); data.lastScan = job
    }
    private func installPreparedWorkspace(_ next: Workspace, bytes: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        if next.subjects != data.subjects || next.relationships != data.relationships { graphRevision = UUID() }
        if next.subjects != data.subjects || next.sessions != data.sessions || next.locations != data.locations || next.extractedText != data.extractedText || next.lastScan?.sources != data.lastScan?.sources { browserRevision = UUID() }
        mutationRevision = UUID(); data = next
    }
    func commitOrganizationInBackground(_ facts: [OrganizationFacts], texts: [UUID: String], library: LibraryStore) async throws -> OrganizationCounts? {
        guard !facts.isEmpty else { return OrganizationCounts() }
        guard writable else { return nil }
        while true {
            let expectedWorkspace = mutationRevision, expectedLibrary = library.graphRevision
            let prepared = try await BackgroundCatalogPreparation.organization(facts, texts: texts, library: library.library, workspace: data)
            try Task.checkCancellation()
            guard expectedWorkspace == mutationRevision, expectedLibrary == library.graphRevision else { continue }
            guard library.commitEncoded(prepared.library, bytes: prepared.libraryBytes, expectedRevision: expectedLibrary) else {
                error = "Organization catalog changes could not be saved."; return nil
            }
            do { try installPreparedWorkspace(prepared.workspace, bytes: prepared.workspaceBytes); return prepared.counts }
            catch { self.error = "Organization metadata could not be saved. Retry the scan; originals are unchanged."; return nil }
        }
    }
    func setScanPaused(_ paused: Bool) {
        guard scanIsActive else { return }
        scanPaused = paused; activeScan?.paused = paused
        Task {
            if paused { await scanControl.pause() } else { await scanControl.resume() }
        }
    }
    func shutdown() async {
        suspendMonitoring(); cancelScan(); task?.cancel(); monitorSubscriptions.removeAll()
        await monitorConfiguration?.value; await monitoring?.value; await scanTask?.value; await task?.value
    }
    private func refreshMonitoredFolder(_ location: ScanLocation, library: LibraryStore) async throws {
        let cursor = try await FolderScanCursor.open(bookmark: location.bookmark, excludes: location.excludes, categories: location.fileCategories)
        do {
            while true {
                try Task.checkCancellation()
                guard data.locations.contains(where: { $0.id == location.id && !$0.paused && $0.excludes == location.excludes && $0.fileCategories == location.fileCategories }) else { break }
                let batch = try await cursor.nextBatch()
                let synced: CatalogSyncResult
                if batch.discovery.candidates.isEmpty { synced = CatalogSyncResult() }
                else { synced = await library.synchronize(batch.discovery.candidates, folderBookmark: location.bookmark) }
                let errors = batch.discovery.errors + synced.errors
                if !errors.isEmpty { error = errors.joined(separator: "\n") }
                var facts: [OrganizationFacts] = [], texts: [UUID: String] = [:]
                let snapshot = library.library.files, ids = synced.merge.fileIDs
                let matchingFiles = await Task.detached(priority: .utility) { snapshot.filter { ids.contains($0.id) } }.value
                for file in matchingFiles {
                    guard data.locations.contains(where: { $0.id == location.id && !$0.paused && $0.extractContent == location.extractContent && $0.includePhotoLocations == location.includePhotoLocations }) else { break }
                    if needsOrganization(file, source: location) {
                        let result = try await organizer.facts(for: file, source: location, existingSubjects: data.subjects.map(\.name))
                        facts.append(result.0); if let text = result.1 { texts[file.id] = text }
                    }
                }
                _ = try await commitOrganizationInBackground(facts, texts: texts, library: library)
                if batch.finished { break }
            }
            await cursor.close()
        } catch { await cursor.close(); throw error }
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
        guard !working else { return }; working = true; processingLabel = "Retaining a managed copy"
        task = Task {
            defer { working = false; processingLabel = nil }
            do { try await recovery.retain(file); library.removeFromIndex(file.id); report = nil; refreshRecovery() }
            catch { self.error = error.localizedDescription }
        }
    }
    func restore(_ entry: RecoveryEntry, library: LibraryStore) {
        guard !working else { return }; working = true; processingLabel = "Restoring a file"
        task = Task {
            defer { working = false; processingLabel = nil }
            do {
                let file = try await recovery.restore(entry)
                if library.addRestored(file) { try await recovery.finish(entry); refreshRecovery() }
                else { self.error = "Restored copy remains on disk, but metadata could not be saved. The recovery payload was retained." }
            } catch { self.error = error.localizedDescription }
        }
    }
    func permanentlyDelete(_ entry: RecoveryEntry) {
        guard !working else { return }; working = true; processingLabel = "Deleting a retained copy"
        task = Task { defer { working = false; processingLabel = nil }; do { try await recovery.finish(entry); refreshRecovery() } catch { self.error = error.localizedDescription } }
    }

}
