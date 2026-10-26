import SwiftUI
import VaultCore

enum ScanPresentation { case configuration, progress, results }

extension WorkspaceStore {
    func startFolderScan(library: LibraryStore) {
        guard !working, !library.busy, !scanCategories.isEmpty, !pendingLocations.isEmpty else { return }
        let sources = pendingLocations.map { original -> ScanLocation in
            var location = original; location.includedCategories = scanCategories; location.categoryVersion = 2
            location.extractContent = scanExtractText; location.includePhotoLocations = scanIncludeGPS
            if scanMonitorFolders { location.paused = false }
            return location
        }
        if scanMonitorFolders {
            guard change({ workspace in
                for source in sources {
                    if let index = workspace.locations.firstIndex(where: { $0.id == source.id }) { workspace.locations[index] = source }
                    else { workspace.locations.append(source) }
                }
            }) else { return }
        }
        runScan(sources, library: library)
    }
    func retryScan(library: LibraryStore) {
        guard let previous = data.lastScan, !working, !library.busy else { return }
        runScan(previous.sources, library: library)
    }
    func showScanResults() { scanPresentation = .results; reviewFolder = true }
    func cancelScan() { scanTask?.cancel() }

    private func runScan(_ sources: [ScanLocation], library: LibraryStore) {
        activeScan = ScanJob(sources: sources); working = true; scanPresentation = .progress; reviewFolder = true
        guard checkpointScan() else { activeScan?.stage = .failed; working = false; scanPresentation = .results; return }
        scanTask = Task {
            defer { working = false; scanCurrentFile = ""; scanPresentation = .results; checkpointScan() }
            do {
                for source in sources {
                    try Task.checkCancellation()
                    do { try await scanSource(source, library: library) }
                    catch is CancellationError { throw CancellationError() }
                    catch { activeScan?.errors.append(source.name + ": " + error.localizedDescription) }
                    checkpointScan()
                }
                try Task.checkCancellation()
                activeScan?.stage = .duplicates; checkpointScan()
                let analysis = try await scanAnalyzer.analyze(library.library.files, hash: false)
                if !analysis.failedIDs.isEmpty { activeScan?.errors.append("Duplicate review skipped \(analysis.failedIDs.count) unavailable catalog entries.") }
                let relevant = activeScan?.catalogIDs ?? []
                let candidates = Dictionary(grouping: analysis.files, by: { $0.file.size }).values.filter { group in
                    group.count > 1 && group.contains { relevant.contains($0.id) }
                }
                activeScan?.possibleDuplicateGroups = candidates.count
                let allFailed = activeScan?.catalogIDs.isEmpty == true && activeScan?.errors.isEmpty == false
                activeScan?.stage = allFailed ? .failed : .completed
            } catch is CancellationError { activeScan?.stage = .cancelled }
            catch { activeScan?.errors.append("Duplicate analysis unavailable."); activeScan?.stage = .completed }
        }
    }
    private func scanSource(_ source: ScanLocation, library: LibraryStore) async throws {
        scanSourceID = source.id
        activeScan?.stage = .enumerating; scanCurrentFile = source.sourcePath ?? source.name
        checkpointScan()
        let cursor = try FolderScanCursor(bookmark: source.bookmark, excludes: source.excludes, categories: source.fileCategories)
        do {
            while true {
                try Task.checkCancellation()
                activeScan?.stage = .enumerating
                scanCurrentFile = source.sourcePath ?? source.name
                let batch = try await cursor.nextBatch()
                activeScan?.discovered += batch.discovery.discovered
                activeScan?.skipped += batch.discovery.skipped
                activeScan?.errors.append(contentsOf: batch.discovery.errors)
                if !batch.discovery.candidates.isEmpty {
                    try await indexScanBatch(batch.discovery.candidates, source: source, library: library)
                }
                guard checkpointScan() else { throw CocoaError(.fileWriteUnknown) }
                if batch.finished { break }
            }
            await cursor.close()
        } catch { await cursor.close(); throw error }
    }
    private func indexScanBatch(_ entries: [ImportCandidate], source: ScanLocation, library: LibraryStore) async throws {
        activeScan?.stage = .indexing
        let baseProcessed = activeScan?.processed ?? 0
        let jobID = activeScan?.id
        let synced = await library.synchronize(entries, folderBookmark: source.bookmark, progress: { [weak self] count, _ in
            Task { @MainActor in
                guard self?.activeScan?.id == jobID, self?.scanSourceID == source.id, self?.activeScan?.stage == .indexing else { return }
                self?.activeScan?.processed = max(self?.activeScan?.processed ?? 0, baseProcessed + count)
            }
        })
        activeScan?.processed = baseProcessed + synced.attempted
        activeScan?.addedIDs.formUnion(synced.merge.added)
        activeScan?.catalogIDs.formUnion(synced.merge.fileIDs)
        activeScan?.skipped += synced.merge.unchanged
        activeScan?.errors.append(contentsOf: synced.errors)
        try Task.checkCancellation()
        activeScan?.stage = .organizing
        var pending: [OrganizationFacts] = [], texts: [UUID: String] = [:]
        for file in library.library.files where synced.merge.fileIDs.contains(file.id) {
            try Task.checkCancellation(); scanCurrentFile = file.filename
            if needsOrganization(file, source: source) {
                let result = try await organizer.facts(for: file, source: source, existingSubjects: data.subjects.map(\.name))
                pending.append(result.0); if let text = result.1 { texts[file.id] = text }
            }
        }
        try Task.checkCancellation()
        if let counts = commitOrganization(pending, texts: texts, library: library) {
            activeScan?.subjectIDs.formUnion(counts.subjectIDs)
            activeScan?.groupIDs.formUnion(counts.collectionIDs)
            activeScan?.relationshipCount += counts.relationshipCount
            activeScan?.photoDateGroups += counts.dateGroups.count
            activeScan?.photoLocationGroups += counts.locationGroups.count
        }
        for id in synced.merge.fileIDs where data.organizationFacts?[id]?.reviewReasons.isEmpty == false { activeScan?.reviewIDs.insert(id) }
    }
    func needsOrganization(_ file: FileItem, source: ScanLocation) -> Bool {
        guard let old = data.organizationFacts?[file.id] else { return true }
        return old.folderContext != URL(fileURLWithPath: file.originalLocation).deletingLastPathComponent().path || old.size != file.size || old.modifiedAt != file.modifiedAt || old.filename != file.filename || old.inputTags != file.tags ||
            old.textRequested != source.extractContent || old.locationsRequested != (source.includePhotoLocations == true)
    }
    @discardableResult func commitOrganization(_ facts: [OrganizationFacts], texts: [UUID: String], library: LibraryStore) -> OrganizationCounts? {
        guard !facts.isEmpty else { return OrganizationCounts() }
        var next = data
        guard let counts = library.applyOrganization(facts, workspace: &next) else {
            activeScan?.errors.append("Organization catalog changes could not be saved."); return nil
        }
        for (id, text) in texts { next.extractedText[id] = text }
        guard change({ $0 = next }) else { activeScan?.errors.append("Organization metadata could not be saved; retry the scan."); return nil }
        return counts
    }
    @discardableResult private func checkpointScan() -> Bool {
        guard let activeScan else { return false }
        return change { $0.lastScan = activeScan }
    }
}
