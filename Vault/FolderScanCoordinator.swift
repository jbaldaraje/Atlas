import SwiftUI
import VaultCore

enum ScanPresentation: Equatable { case configuration, progress, results }

extension WorkspaceStore {
    func startFolderScan(library: LibraryStore) {
        guard scanJournalReadable, !working, !library.busy, !scanCategories.isEmpty, !pendingLocations.isEmpty else { return }
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
        guard scanJournalReadable, let previous = data.lastScan, !working, !library.busy else { return }
        runScan(previous.sources, library: library)
    }
    func showScanResults() {
        scanMinimized = false; scanPresentation = scanIsActive ? .progress : .results; reviewFolder = true
    }
    func minimizeScan() {
        guard scanIsActive else { return }
        scanMinimized = true; reviewFolder = false
    }
    func dismissScanStatus() { guard !scanIsActive else { return }; scanMinimized = false }
    func cancelScan() {
        guard scanIsActive else { return }
        scanCancellationRequested = true; scanTask?.cancel()
    }

    private func runScan(_ sources: [ScanLocation], library: LibraryStore) {
        var job = ScanJob(sources: sources); job.stage = .counting; job.progress = ScanWorkProgress()
        activeScan = job; working = true; scanMinimized = false; scanCancellationRequested = false
        scanPresentation = .progress; reviewFolder = true
        scanPaused = false
        scanTask = Task {
            if scanPaused { await scanControl.pause() } else { await scanControl.resume() }
            do {
                guard await checkpointScan() else { throw CocoaError(.fileWriteUnknown) }
                let totals = try await countScanSources(sources)
                activeScan?.progress?.countingComplete = true
                guard await checkpointScan() else { throw CocoaError(.fileWriteUnknown) }
                for source in sources {
                    try Task.checkCancellation(); try await scanControl.wait()
                    do { try await scanSource(source, countedFiles: totals[source.id] ?? 0, library: library) }
                    catch is CancellationError { throw CancellationError() }
                    catch { activeScan?.errors.append(source.name + ": " + error.localizedDescription) }
                    await checkpointScan()
                }
                try Task.checkCancellation(); try await scanControl.wait()
                activeScan?.stage = .duplicates
                let files = library.library.files
                activeScan?.progress?.duplicateTotal = files.count
                await checkpointScan()
                let jobID = activeScan?.id
                let analysis = try await scanAnalyzer.analyze(files, hash: false, control: scanControl, progress: { [weak self] count, _ in
                    Task { @MainActor in
                        guard self?.activeScan?.id == jobID, self?.scanIsActive == true, self?.activeScan?.stage == .duplicates else { return }
                        self?.activeScan?.progress?.duplicateChecks = max(self?.activeScan?.progress?.duplicateChecks ?? 0, count)
                    }
                })
                try Task.checkCancellation(); try await scanControl.wait()
                activeScan?.progress?.duplicateChecks = files.count
                if !analysis.failedIDs.isEmpty { activeScan?.errors.append("Duplicate review skipped \(analysis.failedIDs.count) unavailable catalog entries.") }
                let relevant = activeScan?.catalogIDs ?? []
                let candidateCount = await Task.detached(priority: .utility) {
                    Dictionary(grouping: analysis.files, by: { $0.file.size }).values.filter { group in
                        group.count > 1 && group.contains { relevant.contains($0.id) }
                    }.count
                }.value
                try Task.checkCancellation()
                activeScan?.possibleDuplicateGroups = candidateCount
                let allFailed = activeScan?.catalogIDs.isEmpty == true && activeScan?.errors.isEmpty == false
                activeScan?.stage = allFailed ? .failed : .completed
            } catch is CancellationError { activeScan?.stage = .cancelled }
            catch { activeScan?.errors.append("Scan stopped before all work could finish. Retry the scan."); activeScan?.stage = .failed }
            activeScan?.paused = false; scanPaused = false
            scanCurrentFile = ""; scanCancellationRequested = false
            scanPresentation = .results
            await scanControl.resume(); await checkpointScan()
            scanTask = nil; working = false
        }
    }
    /// Count without retaining candidate URLs. The second pass still indexes bounded chunks.
    /// Both passes use identical permissions, exclusions, and file-type filtering.
    private func countScanSources(_ sources: [ScanLocation]) async throws -> [UUID: Int] {
        var totals: [UUID: Int] = [:]
        for source in sources {
            try Task.checkCancellation(); try await scanControl.wait()
            scanCurrentFile = source.sourcePath ?? source.name
            do {
                let cursor = try await FolderScanCursor.open(bookmark: source.bookmark, excludes: source.excludes, categories: source.fileCategories)
                do {
                    while true {
                        try Task.checkCancellation(); try await scanControl.wait()
                        let batch = try await cursor.nextBatch()
                        totals[source.id, default: 0] += batch.discovery.candidates.count
                        activeScan?.progress?.countedEntries += batch.discovery.discovered
                        activeScan?.progress?.totalFiles += batch.discovery.candidates.count
                        if batch.finished { break }
                    }
                    await cursor.close()
                } catch { await cursor.close(); throw error }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // The processing pass retries access and records its actionable errors once.
                continue
            }
            guard await checkpointScan() else { throw CocoaError(.fileWriteUnknown) }
        }
        return totals
    }
    private func scanSource(_ source: ScanLocation, countedFiles: Int, library: LibraryStore) async throws {
        scanSourceID = source.id
        let otherSources = max(0, (activeScan?.progress?.totalFiles ?? 0) - countedFiles)
        var actualFiles = 0
        activeScan?.stage = .enumerating; scanCurrentFile = source.sourcePath ?? source.name
        await checkpointScan()
        let cursor = try await FolderScanCursor.open(bookmark: source.bookmark, excludes: source.excludes, categories: source.fileCategories)
        do {
            while true {
                try Task.checkCancellation(); try await scanControl.wait()
                activeScan?.stage = .enumerating
                scanCurrentFile = source.sourcePath ?? source.name
                let batch = try await cursor.nextBatch()
                activeScan?.discovered += batch.discovery.discovered
                activeScan?.skipped += batch.discovery.skipped
                activeScan?.errors.append(contentsOf: batch.discovery.errors)
                actualFiles += batch.discovery.candidates.count
                // The directory may change after counting. Grow the denominator before processing.
                activeScan?.progress?.totalFiles = otherSources + max(countedFiles, actualFiles)
                if !batch.discovery.candidates.isEmpty {
                    try await indexScanBatch(batch.discovery.candidates, source: source, library: library)
                }
                guard await checkpointScan() else { throw CocoaError(.fileWriteUnknown) }
                if batch.finished {
                    activeScan?.progress?.totalFiles = otherSources + actualFiles
                    break
                }
            }
            await cursor.close()
        } catch { await cursor.close(); throw error }
    }
    private func indexScanBatch(_ entries: [ImportCandidate], source: ScanLocation, library: LibraryStore) async throws {
        activeScan?.stage = .indexing
        let baseProcessed = activeScan?.processed ?? 0
        let baseIndexed = activeScan?.progress?.indexedFiles ?? 0
        let baseOrganized = activeScan?.progress?.organizedFiles ?? 0
        let jobID = activeScan?.id
        let synced = await library.synchronize(entries, folderBookmark: source.bookmark, control: scanControl, progress: { [weak self] count, _ in
            Task { @MainActor in
                guard self?.activeScan?.id == jobID, self?.scanSourceID == source.id, self?.activeScan?.stage == .indexing else { return }
                self?.activeScan?.processed = max(self?.activeScan?.processed ?? 0, baseProcessed + count)
                self?.activeScan?.progress?.indexedFiles = max(self?.activeScan?.progress?.indexedFiles ?? 0, baseIndexed + count)
            }
        })
        activeScan?.processed = baseProcessed + synced.attempted
        activeScan?.progress?.indexedFiles = baseIndexed + synced.attempted
        activeScan?.addedIDs.formUnion(synced.merge.added)
        activeScan?.catalogIDs.formUnion(synced.merge.fileIDs)
        activeScan?.skipped += synced.merge.unchanged
        activeScan?.errors.append(contentsOf: synced.errors)
        try Task.checkCancellation(); try await scanControl.wait()
        activeScan?.stage = .organizing
        var pending: [OrganizationFacts] = [], texts: [UUID: String] = [:]
        let snapshot = library.library.files, ids = synced.merge.fileIDs
        let files = await Task.detached(priority: .utility) { snapshot.filter { ids.contains($0.id) } }.value
        var progressGate = ProgressThrottle()
        for (index, file) in files.enumerated() {
            try Task.checkCancellation(); try await scanControl.wait()
            let publish = progressGate.shouldPublish(now: ProcessInfo.processInfo.systemUptime, final: index + 1 == files.count)
            if publish { scanCurrentFile = file.filename }
            if needsOrganization(file, source: source) {
                let result = try await organizer.facts(for: file, source: source, existingSubjects: data.subjects.map(\.name))
                pending.append(result.0); if let text = result.1 { texts[file.id] = text }
            }
            if publish { activeScan?.progress?.organizedFiles = baseOrganized + index + 1 }
        }
        try Task.checkCancellation(); try await scanControl.wait()
        if let counts = try await commitOrganizationInBackground(pending, texts: texts, library: library) {
            activeScan?.subjectIDs.formUnion(counts.subjectIDs)
            activeScan?.groupIDs.formUnion(counts.collectionIDs)
            activeScan?.relationshipCount += counts.relationshipCount
            activeScan?.photoDateGroups += counts.dateGroups.count
            activeScan?.photoLocationGroups += counts.locationGroups.count
        } else { activeScan?.errors.append("Organization changes could not be saved. Retry the scan.") }
        for id in synced.merge.fileIDs where data.organizationFacts?[id]?.reviewReasons.isEmpty == false { activeScan?.reviewIDs.insert(id) }
        // Unavailable and repeated references are resolved attempts, not successful additions.
        activeScan?.progress?.organizedFiles = baseOrganized + synced.attempted
    }
    func needsOrganization(_ file: FileItem, source: ScanLocation) -> Bool {
        guard let old = data.organizationFacts?[file.id] else { return true }
        return old.folderContext != URL(fileURLWithPath: file.originalLocation).deletingLastPathComponent().path || old.changeSignature != file.changeSignature || old.size != file.size || old.modifiedAt != file.modifiedAt || old.filename != file.filename || old.inputTags != file.tags ||
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
    @discardableResult private func checkpointScan() async -> Bool {
        guard scanJournalReadable, let activeScan else { return false }
        do {
            try await scanJournal.save(activeScan); publishScanCheckpoint(activeScan); return true
        } catch { self.error = "Scan progress could not be saved. Completed catalog entries are preserved."; return false }
    }
}
