import XCTest
@testable import VaultCore

final class FileKindFilterTests: XCTestCase {
    private func file(_ name: String, type: String) -> FileItem {
        FileItem(filename: name, type: type, bookmark: Data(), originalLocation: "/approved/" + name, ownership: .original, size: 10)
    }
    private func index(_ files: [FileItem], subjects: [Subject] = [], collections: [FileCollection] = [], sessions: [StudySession] = []) throws -> CatalogIndex {
        var library = Library(); library.files = files; library.collections = collections
        return try CatalogIndex(CatalogSnapshot(library: library, subjects: subjects, sessions: sessions, sourcePaths: ["/approved"], text: [:]))
    }
    func testDocsCoverDocumentFormatsAndAllIncludesUnclassifiedFiles() {
        for ext in ["PDF", ".docx", "md", "pptx", "xlsx", "csv", "json", "rtf"] {
            XCTAssertTrue(FileKindFilter.documents.includes(fileExtension: ext), ext)
            XCTAssertFalse(FileKindFilter.photos.includes(fileExtension: ext), ext)
            XCTAssertFalse(FileKindFilter.media.includes(fileExtension: ext), ext)
        }
        for ext in ["zip", "unknown", ""] {
            XCTAssertTrue(FileKindFilter.all.includes(fileExtension: ext))
            XCTAssertFalse(FileKindFilter.documents.includes(fileExtension: ext))
            XCTAssertFalse(FileKindFilter.media.includes(fileExtension: ext))
            XCTAssertFalse(FileKindFilter.photos.includes(fileExtension: ext))
        }
    }
    func testMediaAndPhotosAreSeparateForCommonAndUppercaseFormats() {
        for ext in ["MP4", "mov", "mkv", "mp3", "FLAC", "m4a"] {
            XCTAssertTrue(FileKindFilter.media.includes(fileExtension: ext))
            XCTAssertFalse(FileKindFilter.photos.includes(fileExtension: ext))
        }
        for ext in ["HEIC", "png", "jpeg", "gif", "svg", "dng", "psd"] {
            XCTAssertTrue(FileKindFilter.photos.includes(fileExtension: ext))
            XCTAssertFalse(FileKindFilter.media.includes(fileExtension: ext))
        }
    }
    func testCategoryCountsPrecedeFolderPagingAndSwitchingDoesNotChangeIndex() throws {
        let files = (0..<183).map { i in file("\(i).\(i % 3 == 0 ? "pdf" : i % 3 == 1 ? "png" : "mp3")", type: i % 3 == 0 ? "pdf" : i % 3 == 1 ? "png" : "mp3") }
        let index = try index(files)
        var query = CatalogQuery(); query.kind = .photos
        let parents = try index.page(query)
        XCTAssertTrue(parents.files.isEmpty); XCTAssertEqual(parents.groups[0].count, 61)
        query.location = parents.groups[0].location
        let first = try index.page(query)
        XCTAssertEqual(first.itemCount, 61); XCTAssertEqual(first.files.count, 60)
        XCTAssertTrue(first.files.allSatisfy { $0.type == "png" })
        query.page = 1
        let last = try index.page(query)
        XCTAssertEqual(last.files.count, 1)
        XCTAssertTrue(Set(first.files.map(\.id)).isDisjoint(with: last.files.map(\.id)))
        query.kind = .documents; query.page = 0
        XCTAssertTrue(try index.page(query).files.allSatisfy { $0.type == "pdf" })
        query.kind = .media
        XCTAssertTrue(try index.page(query).files.allSatisfy { $0.type == "mp3" })
        query.kind = .all
        XCTAssertEqual(try index.page(query).itemCount, 183)
        query.section = .media; query.kind = .documents
        XCTAssertEqual(try index.page(query).itemCount, 0)
    }
    func testSubjectAndCollectionParentsOnlyCountMatchingMembers() throws {
        let docCollection = FileCollection(name: "Reading"), photoCollection = FileCollection(name: "Gallery"), empty = FileCollection(name: "Empty")
        var doc = file("paper.pdf", type: "pdf"), photo = file("image.png", type: "png")
        doc.collectionIDs = [docCollection.id]; photo.collectionIDs = [photoCollection.id]
        var study = Subject(name: "Study"), travel = Subject(name: "Travel")
        study.fileIDs = [doc.id]; travel.fileIDs = [photo.id]
        let index = try index([doc, photo], subjects: [study, travel], collections: [docCollection, photoCollection, empty])
        var query = CatalogQuery(); query.section = .subjects; query.kind = .documents
        XCTAssertEqual(try index.page(query).groups.map(\.title), ["Study"])
        query.kind = .photos
        XCTAssertEqual(try index.page(query).groups.map(\.title), ["Travel"])
        query.section = .collections
        XCTAssertEqual(try index.page(query).groups.map(\.title), ["Gallery"])
        query.kind = .all
        XCTAssertEqual(try index.page(query).groups.count, 3)
    }
    func testTypedTimelineDoesNotClassifyStudyRecordsAsPhotosOrDocs() throws {
        let photo = file("image.png", type: "png"), doc = file("paper.pdf", type: "pdf")
        let session = StudySession(subjectID: UUID(), minutes: 25, note: "Explicit study")
        let index = try index([photo, doc], sessions: [session])
        var query = CatalogQuery(); query.section = .timeline; query.kind = .photos
        let groups = try index.page(query).groups
        XCTAssertFalse(groups.contains { $0.location.event == .study })
        XCTAssertEqual(groups.first { $0.location.event == .added }?.count, 1)
        query.location.event = .study
        XCTAssertTrue(try index.page(query).groups.isEmpty)
        query.location = CatalogLocation(); query.kind = .all
        XCTAssertEqual(try index.page(query).groups.first { $0.location.event == .study }?.count, 1)
    }
    func testNotesAndFolderFiltersRetainTheirExistingScope() throws {
        var note = file("note.txt", type: "txt")
        note.noteSource = ImportedNoteSource(accountID: "cloud", accountName: "iCloud", folderID: "notes", folderName: "Notes", noteID: "note", title: "Research")
        let index = try index([note, file("image.png", type: "png")])
        var query = CatalogQuery(); query.section = .notes; query.kind = .documents
        XCTAssertEqual(try index.page(query).groups.first?.count, 1)
        query.kind = .photos
        XCTAssertTrue(try index.page(query).groups.isEmpty)
        query = CatalogQuery(); query.kind = .documents; query.text = "image"
        XCTAssertTrue(try index.page(query).groups.isEmpty)
    }
    func testGraphKindsRetainOnlyMatchingFilesAndTheirRelatedParents() throws {
        let doc = file("paper.pdf", type: "pdf"), photo = file("image.png", type: "png"), media = file("lecture.mp3", type: "mp3")
        var reading = Subject(name: "Reading"), gallery = Subject(name: "Gallery")
        reading.fileIDs = [doc.id]; gallery.fileIDs = [photo.id]
        var library = Library(); library.files = [doc, photo, media]
        let index = try KnowledgeGraphIndex(library: library, subjects: [reading, gallery], relationships: [])
        var query = GraphQuery(); query.kind = .documents
        XCTAssertEqual(Set(try index.project(query).nodes.map(\.id)), [doc.id, reading.id])
        query.kind = .photos
        let photos = try index.project(query)
        XCTAssertEqual(Set(photos.nodes.map(\.id)), [photo.id, gallery.id])
        XCTAssertTrue(photos.nodes.first { $0.id == gallery.id }?.subtitle.contains("1 MATCHING FILES") == true)
        let visible = Set(photos.nodes.map(\.id))
        XCTAssertTrue(photos.edges.allSatisfy { visible.contains($0.source) && visible.contains($0.target) })
        query.kind = .media
        XCTAssertEqual(try index.project(query).nodes.map(\.id), [media.id])
        query.kind = .all
        XCTAssertEqual(try index.project(query).nodes.count, 5)
    }
}
