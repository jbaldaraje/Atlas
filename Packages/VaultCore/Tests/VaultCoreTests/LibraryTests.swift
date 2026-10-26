import XCTest
@testable import VaultCore

final class LibraryTests: XCTestCase {
    func fixture() -> FileItem {
        FileItem(filename: "Biology notes.pdf", type: "pdf", bookmark: Data([1, 2]), originalLocation: "/user/notes.pdf", ownership: .original, size: 123, description: "Cell structure", tags: ["Exam"])
    }
    func testMetadataRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LibraryRepository(url: directory.appendingPathComponent("library.json"))
        var library = Library(); library.files = [fixture()]; library.collections = [FileCollection(name: "Study")]
        library.files[0].collectionIDs.insert(library.collections[0].id)
        try repository.save(library)
        XCTAssertEqual(try repository.load(), library)
    }
    func testSearchCombinesTermsAndFilters() {
        var library = Library(); library.files = [fixture()]
        XCTAssertEqual(library.search("biology EXAM").count, 1)
        XCTAssertEqual(library.search("cell").count, 1)
        XCTAssertTrue(library.search("unknown").isEmpty)
        XCTAssertTrue(library.search("", favoritesOnly: true).isEmpty)
        XCTAssertTrue(library.search("", collectionID: UUID()).isEmpty)
    }
    func testIndexRemovalPreservesUnderlyingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("original".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var file = fixture(); file.originalLocation = url.path
        var library = Library(); library.files = [file]; library.removeFromIndex(file.id)
        XCTAssertTrue(library.files.isEmpty)
        XCTAssertEqual(try String(contentsOf: url), "original")
    }
    func testRemovingCollectionPreservesFilesAndOtherMemberships() {
        let a = FileCollection(name: "A"), b = FileCollection(name: "B")
        var library = Library(); library.collections = [a, b]; library.files = [fixture()]
        library.files[0].collectionIDs = [a.id, b.id]
        library.removeCollection(a.id)
        XCTAssertEqual(library.files.count, 1)
        XCTAssertEqual(library.files[0].collectionIDs, [b.id])
        XCTAssertEqual(library.collections, [b])
    }
    func testCorruptionIsNotTreatedAsEmptyLibrary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try LibraryRepository(url: url).load())
        XCTAssertEqual(try String(contentsOf: url), "broken")
    }
    func testLargeLibrarySearch() {
        var library = Library()
        library.files = (0..<10000).map { number in var file = fixture(); file.filename = "Document \(number)"; return file }
        XCTAssertEqual(library.search("Document").count, 10000)
    }
}
