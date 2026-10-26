import XCTest
@testable import VaultCore

final class DashboardTests: XCTestCase {
    private func file(_ name: String, type: String, date: TimeInterval = 1) -> FileItem { FileItem(filename: name, type: type, bookmark: Data(), originalLocation: "/fixtures/" + name, ownership: .original, size: 100, indexedAt: Date(timeIntervalSince1970: date)) }
    private func allWidgets() -> WorkspacePreferences {
        var preferences = WorkspacePreferences()
        preferences.dashboard.widgets = DashboardWidgetKind.allCases.map { .init(kind: $0, visible: true) }
        return preferences
    }
    func testDefaultsAreFocusedAndNormalizationPreservesOrderAndVisibility() {
        var layout = DashboardLayout()
        XCTAssertEqual(layout.widgets.filter(\.visible).count, 3)
        layout.widgets = [.init(kind: .photos, visible: true, size: .expanded), .init(kind: .photos, visible: false)]
        layout.normalize()
        XCTAssertEqual(layout.widgets.count, DashboardWidgetKind.allCases.count)
        XCTAssertEqual(layout.widgets[0].kind, .photos); XCTAssertTrue(layout.widgets[0].visible)
        XCTAssertEqual(layout.widgets[0].size, .expanded); XCTAssertTrue(layout.widgets.dropFirst().allSatisfy { !$0.visible })
    }
    func testReorderResizePriorityAndResetRoundTrip() throws {
        var preferences = allWidgets()
        preferences.dashboard.move(.storage, before: .notes)
        preferences.dashboard.widgets[0].size = .expanded; preferences.dashboard.widgets[0].priority = .favorites
        let decoded = try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences); XCTAssertEqual(decoded.dashboard.widgets.first?.kind, .storage)
        var reset = decoded; reset.dashboard = DashboardLayout()
        XCTAssertEqual(reset.dashboard.widgets, DashboardLayout.defaults)
        let old = try JSONDecoder().decode(WorkspacePreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(old.dashboard, DashboardLayout())
    }
    func testWidgetContentUsesCorrectKindsFavoritesAndRealOpenedEvents() throws {
        var library = Library()
        var note = file("note.txt", type: "txt"), favorite = file("favorite.pdf", type: "pdf", date: 2)
        note.noteSource = ImportedNoteSource(accountID: "cloud", accountName: "iCloud", folderID: "notes", folderName: "Notes", noteID: "note", title: "Note")
        favorite.favorite = true
        let photo = file("photo.heic", type: "heic"), media = file("lecture.flac", type: "flac")
        library.files = [note, favorite, photo, media]
        let preferences = allWidgets()
        let snapshot = try DashboardSnapshot.build(library: library, subjects: [], opened: [media.id: Date(timeIntervalSince1970: 10)], facts: [:], text: [note.id: "Actual indexed note excerpt"], preferences: preferences)
        XCTAssertEqual(snapshot.files[.notes]?.map(\.id), [note.id]); XCTAssertEqual(snapshot.files[.notes]?.first?.excerpt, "Actual indexed note excerpt")
        XCTAssertEqual(snapshot.files[.documents]?.map(\.id), [favorite.id]); XCTAssertEqual(snapshot.files[.photos]?.map(\.id), [photo.id])
        XCTAssertEqual(snapshot.files[.media]?.map(\.id), [media.id]); XCTAssertEqual(snapshot.files[.recent]?.map(\.id), [media.id])
        XCTAssertEqual(snapshot.files[.recent]?.first?.dateLabel, "Opened through Vault")
        XCTAssertEqual(snapshot.files[.favorites]?.map(\.id), [favorite.id])
        XCTAssertEqual(library.files.count, 4)
    }
    func testHiddenWidgetsDoNotProduceRowsAndLargeCatalogTopKStaysSmall() throws {
        var library = Library(); library.files = (0..<30_123).map { file("\($0).pdf", type: "pdf", date: Double($0)) }
        let snapshot = try DashboardSnapshot.build(library: library, subjects: [], opened: [:], facts: [:], text: [:], preferences: WorkspacePreferences())
        XCTAssertNil(snapshot.files[.photos]); XCTAssertNil(snapshot.files[.media]); XCTAssertNil(snapshot.storage)
        XCTAssertEqual(snapshot.files[.documents]?.count, 3)
        XCTAssertEqual(snapshot.files[.documents]?.first?.id, library.files.last?.id)
        var preferences = WorkspacePreferences(); preferences.dashboard.widgets = []
        let hidden = try DashboardSnapshot.build(library: library, subjects: [], opened: [:], facts: [:], text: [:], preferences: preferences)
        XCTAssertTrue(hidden.files.isEmpty); XCTAssertNil(hidden.storage)
    }
    func testPriorityUsesActualFavoritesAndExpandedLimit() throws {
        var library = Library()
        var favorite = file("older.pdf", type: "pdf", date: 1); favorite.favorite = true
        library.files = [favorite] + (2..<20).map { file("new-\($0).pdf", type: "pdf", date: Double($0)) }
        var preferences = WorkspacePreferences()
        preferences.dashboard.widgets = [.init(kind: .documents, visible: true, size: .expanded, priority: .favorites)]
        let result = try DashboardSnapshot.build(library: library, subjects: [], opened: [:], facts: [:], text: [:], preferences: preferences)
        XCTAssertEqual(result.files[.documents]?.count, 6); XCTAssertEqual(result.files[.documents]?.first?.id, favorite.id)
    }
    func testStorageCountsKnownIdentitiesAndManagedCopiesWithoutClaimingDiskUsage() throws {
        var first = file("a.pdf", type: "pdf"), hardLink = file("hard.pdf", type: "pdf"), copy = file("copy.pdf", type: "pdf")
        first.fileIdentity = "1:10"; hardLink.fileIdentity = "1:10"; copy.fileIdentity = "1:11"; copy.ownership = .managedCopy
        var library = Library(); library.files = [first, hardLink, copy]
        let result = try DashboardSnapshot.build(library: library, subjects: [], opened: [:], facts: [:], text: [:], preferences: allWidgets())
        XCTAssertEqual(result.storage?.indexedLogicalBytes, 200); XCTAssertEqual(result.storage?.managedLogicalBytes, 100)
        hardLink.ownership = .managedCopy; library.files = [first, hardLink, copy]
        let overlapping = try DashboardSnapshot.build(library: library, subjects: [], opened: [:], facts: [:], text: [:], preferences: allWidgets())
        XCTAssertEqual(overlapping.storage?.indexedLogicalBytes, 200); XCTAssertEqual(overlapping.storage?.managedLogicalBytes, 200)
    }
    func testPinnedCollectionsAndExplorationUseExistingIDsAndCurrentTrail() throws {
        let collection = FileCollection(name: "Project"), other = FileCollection(name: "Other")
        let document = file("a.pdf", type: "pdf"), later = file("later.pdf", type: "pdf")
        var library = Library(); library.collections = [collection, other]; library.files = [document, later]
        var preferences = allWidgets(); preferences.pinnedCollections = [collection.id]
        preferences.history.visit(ExplorationStep(itemID: document.id, kind: .file))
        preferences.history.visit(ExplorationStep(itemID: later.id, kind: .file))
        preferences.history.jump(to: 0)
        let result = try DashboardSnapshot.build(library: library, subjects: [], opened: [:], facts: [:], text: [:], preferences: preferences)
        XCTAssertEqual(result.collections.map(\.id), [collection.id]); XCTAssertEqual(result.trail.map(\.id), [document.id])
    }
    func testPreferencesStoreIDsNotDocumentContents() throws {
        var preferences = allWidgets()
        let source = UUID(), target = UUID()
        preferences.dismissedTextConnections = [DiscoveryPair(source, target)]
        preferences.history.visit(ExplorationStep(itemID: source, kind: .file, originID: target, reason: .indexedTerms))
        let encoded = try JSONEncoder().encode(preferences)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(source.uuidString)); XCTAssertFalse(text.contains("originalLocation")); XCTAssertFalse(text.contains("extractedText")); XCTAssertFalse(text.contains("bookmark"))
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePreferences.self, from: encoded), preferences)
    }
}
