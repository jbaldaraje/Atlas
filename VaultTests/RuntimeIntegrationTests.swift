import XCTest
import VaultCore

@MainActor
final class RuntimeIntegrationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testPausedWorkResumesAndCancellationDrainsWaiters() async throws {
        let control = ScanControl(); await control.pause()
        let waiting = Task { try await control.wait() }
        for _ in 0..<1000 {
            let pending = await control.waitingCount
            if pending == 1 { break }
            await Task.yield()
        }
        let count = await control.waitingCount; XCTAssertEqual(count, 1)
        waiting.cancel()
        do { try await waiting.value; XCTFail("A cancelled paused operation must throw") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        let remaining = await control.waitingCount; XCTAssertEqual(remaining, 0)
        await control.resume(); try await control.wait()
    }
    func testScanJournalRestoresInterruptedStateWithoutRewritingWorkspace() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceStore(base: root); workspace.change { $0.openedFiles = [UUID(): .now] }
        let workspaceURL = root.appendingPathComponent("workspace.json"), original = try Data(contentsOf: workspaceURL)
        var job = ScanJob(sources: []); job.stage = .indexing; job.catalogIDs = [UUID()]; job.paused = true
        try await ScanJournal(base: root).save(job)
        let restored = WorkspaceStore(base: root)
        XCTAssertEqual(restored.data.lastScan?.stage, .interrupted); XCTAssertEqual(restored.data.lastScan?.catalogIDs, job.catalogIDs)
        XCTAssertEqual(restored.data.lastScan?.paused, false)
        XCTAssertEqual(try Data(contentsOf: workspaceURL), original)
    }
    func testCorruptJournalIsPreservedAndScanWritesAreRefused() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = ScanJournal.url(base: root), original = Data("broken journal".utf8); try original.write(to: url)
        let store = WorkspaceStore(base: root)
        XCTAssertFalse(store.scanJournalReadable); XCTAssertNotNil(store.error)
        store.retryScan(library: LibraryStore(base: root)); XCTAssertNil(store.scanTask)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testHashCacheReusesUnchangedDataAndInvalidatesRestoredMtimeChanges() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("aaaa".utf8).write(to: a); try Data("aaaa".utf8).write(to: b)
        let candidates = try await FileAccessService.inspect([a, b])
        let report = await FileAccessService.run(candidates, copy: false, managedDirectory: root, existingPaths: [])
        let service = AnalysisService()
        let first = try await service.analyze(report.items, hash: true); XCTAssertEqual(first.duplicates.count, 1)
        let initialCount = await service.hashComputationCount; XCTAssertEqual(initialCount, 2)
        _ = try await service.analyze(report.items, hash: true)
        let reused = await service.hashComputationCount
        let uncacheable = [a, b].filter { FileAccessService.changeSignature(at: $0)?.hasSuffix(":0") != false }.count
        XCTAssertEqual(reused, initialCount + uncacheable)
        let modified = try b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let signature = FileAccessService.changeSignature(at: b)
        try Data("bbbb".utf8).write(to: b)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: b.path) }
        XCTAssertNotEqual(FileAccessService.changeSignature(at: b), signature)
        let changed = try await service.analyze(report.items, hash: true); XCTAssertTrue(changed.duplicates.isEmpty)
        XCTAssertEqual(try Data(contentsOf: a), Data("aaaa".utf8))
    }
    func testUnchangedSyncKeepsCatalogRevisionAndCurrentUserMetadata() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fileURL = source.appendingPathComponent("a.txt"); try Data("actual content".utf8).write(to: fileURL)
        let bookmark = try source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let library = LibraryStore(base: root.appendingPathComponent("metadata")), entries = try await FileAccessService.inspect([fileURL])
        _ = await library.synchronize(entries, folderBookmark: bookmark)
        let id = try XCTUnwrap(library.library.files.first?.id); library.toggleFavorite(id)
        let revision = library.graphRevision
        let second = await library.synchronize(entries, folderBookmark: bookmark)
        if FileAccessService.changeSignature(at: fileURL)?.hasSuffix(":0") == false {
            XCTAssertEqual(second.merge.unchanged, 1); XCTAssertEqual(library.graphRevision, revision)
        }
        XCTAssertTrue(second.errors.isEmpty)
        XCTAssertTrue(library.library.files[0].favorite); XCTAssertEqual(library.library.files[0].id, id)
        let workspace = WorkspaceStore(base: root.appendingPathComponent("metadata"))
        workspace.startMonitoring(library: library)
        workspace.change { $0.extractedText[id] = "Old indexed content" }
        var changed = library.library.files[0]; changed.modifiedAt = .distantFuture; changed.changeSignature = "Changed while no window is open"
        XCTAssertTrue(library.update(changed)); XCTAssertNil(workspace.data.extractedText[id])
        await workspace.shutdown()
    }
    func testSyncRenewsInvalidBookmarksForUnchangedFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fileURL = source.appendingPathComponent("a.txt"); try Data("actual content".utf8).write(to: fileURL)
        let bookmark = try source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let library = LibraryStore(base: root.appendingPathComponent("metadata")), entries = try await FileAccessService.inspect([fileURL])
        _ = await library.synchronize(entries, folderBookmark: bookmark)
        var broken = try XCTUnwrap(library.library.files.first); broken.bookmark = Data("invalid reference".utf8)
        XCTAssertTrue(library.update(broken))
        _ = await library.synchronize(entries, folderBookmark: bookmark)
        let restored = try XCTUnwrap(library.library.files.first)
        XCTAssertEqual(restored.id, broken.id); XCTAssertNotEqual(restored.bookmark, broken.bookmark)
        let resource = try await PreviewResource.resolve(restored); XCTAssertEqual(resource.url.resolvingSymlinksInPath().standardizedFileURL, fileURL.resolvingSymlinksInPath().standardizedFileURL)
    }
    func testStalePreparedCatalogCannotOverwriteAUserEdit() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(base: root)
        let file = FileItem(filename: "a.txt", type: "txt", bookmark: Data(), originalLocation: "/fixture/a.txt", ownership: .original, size: 4)
        XCTAssertTrue(library.addRestored(file)); let revision = library.graphRevision
        let prepared = try await BackgroundCatalogPreparation.organization([], texts: [:], library: library.library, workspace: Workspace())
        library.toggleFavorite(file.id)
        XCTAssertFalse(library.commitEncoded(prepared.library, bytes: prepared.libraryBytes, expectedRevision: revision))
        XCTAssertTrue(LibraryStore(base: root).library.files[0].favorite)
    }
    func testCacheReleasePreservesGraphDataAndRebuildsOnlyOnDemand() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var library = Library(); library.files = [FileItem(filename: "a.txt", type: "txt", bookmark: Data(), originalLocation: "/fixture/a.txt", ownership: .original, size: 4)]
        let engine = KnowledgeGraphEngine(base: root), request = GraphRequest(revision: GraphRevision(library: UUID(), workspace: UUID()), query: GraphQuery())
        let first = try await engine.prepare(request: request, library: library, subjects: [], relationships: [], legacyPositions: [:])
        await engine.releaseTransientCaches(); let count = await engine.buildCount; XCTAssertEqual(count, 1)
        let second = try await engine.prepare(request: request, library: library, subjects: [], relationships: [], legacyPositions: [:])
        XCTAssertEqual(first.projection.nodes, second.projection.nodes)
        let rebuilt = await engine.buildCount; XCTAssertEqual(rebuilt, 2)
    }
    func testApprovedFolderEventsDeliverChangesWithoutAnIdlePoller() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let location = ScanLocation(name: "Fixture", bookmark: bookmark), monitor = FolderEventMonitor()
        let change = expectation(description: "FSEvents delivers the approved root change")
        var ready = false, delivered = false
        let errors = await monitor.configure([location]) { id in
            if ready && !delivered && id == location.id { delivered = true; change.fulfill() }
        }
        XCTAssertTrue(errors.isEmpty); ready = true
        try Data("changed".utf8).write(to: root.appendingPathComponent("new.txt"))
        await fulfillment(of: [change], timeout: 10); monitor.stop()
    }
    func testCancelledPreviewResolutionCannotKeepAResource() async throws {
        let file = FileItem(filename: "a.txt", type: "txt", bookmark: Data(), originalLocation: "/fixture/a.txt", ownership: .original, size: 4)
        let task = Task { try await PreviewResource.resolve(file) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled resolution must not succeed") } catch is CancellationError {} catch { XCTFail("Expected cancellation before bookmark access") }
    }
}
