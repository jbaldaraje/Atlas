import XCTest
@testable import VaultCore

final class ImportedNoteTests: XCTestCase {
    private func source(id: String = "note-1", title: String = "Research") -> ImportedNoteSource {
        ImportedNoteSource(accountID: "icloud-account", accountName: "iCloud", folderID: "folder", folderName: "Notes", noteID: id, title: title)
    }
    func testStableSourceIdentitySurvivesTitleAndFolderChanges() {
        var library = Library()
        var file = FileItem(filename: "Research.txt", type: "txt", bookmark: Data(), originalLocation: "/managed/research.txt", ownership: .managedCopy, size: 1)
        file.noteSource = source(); library.files = [file]
        var moved = source(title: "Renamed"); moved.folderID = "new-folder"
        XCTAssertEqual(ImportedNoteRules.existingID(for: moved, in: library), file.id)
        XCTAssertNil(ImportedNoteRules.existingID(for: source(id: "another-note"), in: library))
    }
    func testRegisterCreatesOneAccountCollectionAndPreservesOtherMemberships() {
        var library = Library(); let manual = FileCollection(name: "Study"); library.collections = [manual]
        var file = FileItem(filename: "Research.txt", type: "txt", bookmark: Data(), originalLocation: "/managed/research.txt", ownership: .managedCopy, size: 1)
        file.noteSource = source(); file.collectionIDs = [manual.id]; file.tags = ["Exam"]
        ImportedNoteRules.register(file, in: &library)
        ImportedNoteRules.register(library.files[0], in: &library)
        XCTAssertEqual(library.files.count, 1); XCTAssertEqual(library.collections.count, 2)
        XCTAssertTrue(library.files[0].collectionIDs.contains(manual.id)); XCTAssertEqual(library.files[0].tags, ["Exam"])
        XCTAssertEqual(library.files[0].collectionIDs.count, 2)
    }
    func testSnapshotFilenamesCannotEscapeTheirDirectory() {
        let filename = ImportedNoteRules.filename(title: "../../private:line\nnext")
        XCTAssertFalse(filename.contains("/")); XCTAssertFalse(filename.contains(":")); XCTAssertFalse(filename.contains("\n"))
        XCTAssertTrue(filename.hasSuffix(".txt"))
        XCTAssertEqual(ImportedNoteRules.filename(title: "  "), "Untitled note.txt")
    }
    func testLegacyFileMetadataStillDecodesWithoutNoteSource() throws {
        let file = FileItem(filename: "old.txt", type: "txt", bookmark: Data(), originalLocation: "/old.txt", ownership: .original, size: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
        object.removeValue(forKey: "noteSource")
        let decoded = try JSONDecoder().decode(FileItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.noteSource); XCTAssertEqual(decoded.id, file.id)
    }
}
