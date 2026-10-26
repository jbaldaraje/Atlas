import XCTest
import VaultCore

@MainActor
final class ExplorationIntegrationTests: XCTestCase {
    private func file(_ name: String) -> FileItem { FileItem(filename: name, type: "pdf", bookmark: Data(), originalLocation: "/fixture/" + name, ownership: .original, size: 10) }
    func testExplorerAndMapShareIndexAndSuggestionsRemainReviewable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = file("a.pdf"), b = file("b.pdf")
        var library = Library(); library.files = [a, b]
        var workspace = Workspace(); workspace.link(a.id, b.id, label: "Actual user link")
        workspace.extractedText = [a.id: "biology genetics cellular", b.id: "cellular biology genetics"]
        let engine = KnowledgeGraphEngine(base: root), revision = GraphRevision(library: UUID(), workspace: UUID()), textRevision = UUID()
        let request = ExplorerRequest(revision: revision, textRevision: textRevision, id: a.id, kind: .all, page: 0, compareText: true, dismissed: [])
        let context = try await engine.explorer(request, library: library, workspace: workspace)
        XCTAssertTrue(context.glance.hasText); XCTAssertEqual(context.connections.documents.map(\.id), [b.id])
        XCTAssertTrue(context.connections.documents[0].evidence.contains { $0.kind == .indexedTerms && $0.suggested })
        var query = GraphQuery(); query.selectedID = b.id; query.originID = a.id
        let map = try await engine.prepare(request: GraphRequest(revision: revision, query: query), library: library, subjects: [], relationships: workspace.relationships, legacyPositions: [:])
        XCTAssertEqual(map.projection.activePathEdgeIDs.count, 1)
        let builds = await engine.buildCount; XCTAssertEqual(builds, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let dismissed = ExplorerRequest(revision: revision, textRevision: textRevision, id: a.id, kind: .all, page: 0, compareText: true, dismissed: [DiscoveryPair(a.id, b.id)])
        let reviewed = try await engine.explorer(dismissed, library: library, workspace: workspace)
        XCTAssertTrue(reviewed.connections.documents[0].hasExplicitLink)
        XCTAssertFalse(reviewed.connections.documents[0].evidence.contains { $0.kind == .indexedTerms })
    }
    func testCancelledExplorerCannotPublishOldContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = file("a.pdf"), b = file("b.pdf")
        var library = Library(); library.files = [a, b]
        let workspace = Workspace(), engine = KnowledgeGraphEngine(base: root), model = DocumentExplorerModel()
        let revision = GraphRevision(library: UUID(), workspace: UUID()), text = UUID()
        let first = ExplorerRequest(revision: revision, textRevision: text, id: a.id, kind: .all, page: 0, compareText: false, dismissed: [])
        let worker = Task { await model.load(first, library: library, workspace: workspace, engine: engine) }
        worker.cancel(); await worker.value
        XCTAssertNil(model.snapshot); XCTAssertFalse(model.loading)
        let next = ExplorerRequest(revision: revision, textRevision: text, id: b.id, kind: .all, page: 0, compareText: false, dismissed: [])
        await model.load(next, library: library, workspace: workspace, engine: engine)
        XCTAssertEqual(model.applied?.id, b.id); XCTAssertNotNil(model.snapshot)
    }
    func testGraphPresentationPositionsDoNotReplaceAnotherViewLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var library = Library(); library.files = [file("a.pdf"), file("b.pdf")]
        let engine = KnowledgeGraphEngine(base: root), request = GraphRequest(revision: GraphRevision(library: UUID(), workspace: UUID()), query: GraphQuery())
        let first = try await engine.prepare(request: request, library: library, subjects: [], relationships: [], legacyPositions: [:])
        var previous = first.positions; let id = library.files[0].id; previous[id] = SpatialPoint(x: 500, y: -500)
        let next = try await engine.prepare(request: request, library: library, subjects: [], relationships: [], legacyPositions: [:], previousPositions: previous)
        XCTAssertEqual(next.positions[id], previous[id]); XCTAssertEqual(first.positions[id], SpatialPoint(x: 0, y: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testPreferencesPersistCustomizationPinsDismissalsAndTrail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspacePreferencesStore(base: root)
        store.setWidget(.photos) { $0.visible = true; $0.size = .expanded; $0.priority = .favorites }
        store.moveWidget(.photos, before: .notes)
        let collection = UUID(), source = UUID(), target = UUID()
        store.toggleCollectionPin(collection); store.dismissTextConnection(source, target)
        store.change { $0.history.visit(ExplorationStep(itemID: source, kind: .file)) }
        await store.flush()
        let reopened = WorkspacePreferencesStore(base: root)
        XCTAssertEqual(reopened.data, store.data); XCTAssertEqual(reopened.data.dashboard.widgets.first?.kind, .photos)
        XCTAssertTrue(reopened.data.pinnedCollections.contains(collection)); XCTAssertTrue(reopened.data.dismissedTextConnections.contains(DiscoveryPair(target, source)))
        XCTAssertEqual(reopened.data.history.current?.itemID, source)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["workspace-preferences.json"])
    }
    func testCorruptPreferencesArePreservedAndWritesDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspace-preferences.json"), original = Data("not valid JSON".utf8)
        try original.write(to: url)
        let store = WorkspacePreferencesStore(base: root)
        XCTAssertFalse(store.canWrite); XCTAssertNotNil(store.error)
        store.change { $0.dashboard.widgets = [] }; await store.flush()
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testBoundedNoteExcerptDoesNotCreateAnotherRecordOrTextIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(base: root)
        let source = ImportedNoteSource(accountID: "cloud", accountName: "iCloud", folderID: "notes", folderName: "Notes", noteID: "note", title: "Research")
        let text = String(repeating: "Génétique 🧬 actual note content. ", count: 1000)
        let note = try await library.importNote(ImportedNoteSnapshot(source: source, text: text))
        let original = try Data(contentsOf: URL(fileURLWithPath: note.originalLocation))
        let loadedExcerpt = await library.noteExcerpt(note)
        let excerpt = try XCTUnwrap(loadedExcerpt)
        XCTAssertLessThanOrEqual(excerpt.count, 180); XCTAssertTrue(text.hasPrefix(excerpt)); XCTAssertFalse(excerpt.contains("�"))
        XCTAssertEqual(library.library.files.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: note.originalLocation)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace.json").path))
    }
    func testMetadataEditingPreservesLatestBookmarkOwnershipAndFavorite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(base: root)
        let original = file("a.pdf"); XCTAssertTrue(library.addRestored(original))
        var current = original; current.bookmark = Data([2]); current.originalLocation = "/moved/a.pdf"; current.favorite = true
        XCTAssertTrue(library.update(current))
        library.updateMetadata(original.id, description: "Edited", tags: ["Research"])
        let saved = try XCTUnwrap(library.library.files.first)
        XCTAssertEqual(saved.bookmark, current.bookmark); XCTAssertEqual(saved.originalLocation, current.originalLocation); XCTAssertTrue(saved.favorite)
        XCTAssertEqual(saved.description, "Edited"); XCTAssertEqual(saved.tags, ["Research"])
    }
    func testActualAccessUpdatesExistingActivityWithoutMarkingStudy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(base: root), id = UUID(), initialRevision = store.activityRevision
        XCTAssertNil(store.data.openedFiles)
        store.recordOpened(id, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.data.openedFiles?[id], Date(timeIntervalSince1970: 100))
        XCTAssertNotEqual(initialRevision, store.activityRevision); XCTAssertTrue(store.data.sessions.isEmpty)
        let revision = store.activityRevision
        store.recordOpened(id, at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(store.activityRevision, revision)
        XCTAssertEqual(WorkspaceStore(base: root).data.openedFiles, store.data.openedFiles)
    }
    func testDashboardPreparationUsesOnlyVisibleWidgetsAndActualActivity() async throws {
        let a = file("a.pdf")
        var library = Library(); library.files = [a]
        var workspace = Workspace(); workspace.openedFiles = [a.id: Date()]
        var preferences = WorkspacePreferences(); preferences.dashboard.widgets = [.init(kind: .recent, visible: true)]
        let request = DashboardRequest(revision: CatalogRevision(library: UUID(), workspace: UUID()), activity: UUID(), layout: preferences.dashboard,
            pins: [], history: preferences.history, analysisID: nil)
        let engine = CatalogBrowserEngine()
        let result = try await engine.dashboard(request, library: library, workspace: workspace, preferences: preferences, report: nil)
        XCTAssertEqual(result.snapshot.files[.recent]?.map(\.id), [a.id]); XCTAssertNil(result.snapshot.storage); XCTAssertNil(result.analysis)
    }
}
