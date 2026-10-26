import XCTest
@testable import VaultCore

final class CatalogBrowserTests: XCTestCase {
    private func file(_ path: String, type: String = "txt", date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> FileItem {
        FileItem(filename: URL(fileURLWithPath: path).lastPathComponent, type: type, bookmark: Data(), originalLocation: path, ownership: .original, size: 10, modifiedAt: date, indexedAt: date)
    }
    private func snapshot(_ files: [FileItem], sources: [String] = ["/approved"], subjects: [Subject] = [], collections: [FileCollection] = [], sessions: [StudySession] = [], text: [UUID: String] = [:]) -> CatalogSnapshot {
        var library = Library(); library.files = files; library.collections = collections
        return CatalogSnapshot(library: library, subjects: subjects, sessions: sessions, sourcePaths: sources, text: text)
    }
    func testThirtyThousandFilesStayHiddenUntilOpeningParentAndLastPageIsReachable() throws {
        let files = (0..<30_123).map { file("/approved/Project/entry-\($0).txt") }
        let index = try CatalogIndex(snapshot(files))
        var query = CatalogQuery(); query.sort = "Name"
        let root = try index.page(query)
        XCTAssertTrue(root.files.isEmpty); XCTAssertEqual(root.groups.count, 1)
        XCTAssertEqual(root.groups[0].subtitle, "/approved"); XCTAssertEqual(root.groups[0].count, files.count)
        query.location = root.groups[0].location
        let parent = try index.page(query)
        XCTAssertTrue(parent.files.isEmpty); XCTAssertEqual(parent.groups.map(\.title), ["Project"])
        query.location = parent.groups[0].location
        let first = try index.page(query)
        XCTAssertEqual(first.files.count, CatalogPage.capacity); XCTAssertEqual(first.itemCount, files.count)
        query.page = first.pageCount - 1
        let last = try index.page(query)
        XCTAssertTrue(Set(first.files.map(\.id)).isDisjoint(with: last.files.map(\.id)))
        XCTAssertTrue(last.files.contains { $0.id == files.last!.id })
        XCTAssertEqual(last.files.count, files.count % CatalogPage.capacity)
        query.page = 0; query.text = "entry-30122.txt"
        XCTAssertEqual(try index.page(query).files.map(\.id), [files.last!.id])
    }
    func testImmediateChildrenDoNotFlattenDescendantsAndMixedPagesStayBounded() throws {
        var files = (0..<75).map { file("/approved/Folders/child-\($0)/nested.txt") }
        files += (0..<75).map { file("/approved/Folders/direct-\($0).txt") }
        files.append(file("/approved/FoldersElsewhere/outside.txt"))
        let index = try CatalogIndex(snapshot(files))
        var query = CatalogQuery(); query.location.folder = "/approved/Folders"; query.sort = "Name"
        var seenFolders = Set<String>(), seenFiles = Set<UUID>()
        let first = try index.page(query)
        XCTAssertEqual(first.itemCount, 150); XCTAssertEqual(first.matchingFiles, 150)
        for page in 0..<first.pageCount {
            query.page = page
            let result = try index.page(query)
            XCTAssertLessThanOrEqual(result.groups.count + result.files.count, CatalogPage.capacity)
            XCTAssertTrue(result.files.allSatisfy { $0.filename.hasPrefix("direct-") })
            XCTAssertTrue(seenFolders.isDisjoint(with: result.groups.map(\.id)))
            XCTAssertTrue(seenFiles.isDisjoint(with: result.files.map(\.id)))
            seenFolders.formUnion(result.groups.map(\.id)); seenFiles.formUnion(result.files.map(\.id))
        }
        XCTAssertEqual(seenFolders.count, 75); XCTAssertEqual(seenFiles.count, 75)
        query.page = Int.max
        XCTAssertEqual(try index.page(query).page, first.pageCount - 1)
    }
    func testMediaSearchFavoritesAndSizeFiltersApplyBeforeFolderCounts() throws {
        var photo = file("/approved/Photos/image.HEIC", type: "HEIC"); photo.favorite = true; photo.tags = ["Exam"]
        let audio = file("/approved/Audio/lecture.flac", type: "flac"), video = file("/approved/Video/lecture.mkv", type: "mkv")
        let pdf = file("/approved/Docs/paper.pdf", type: "pdf")
        let index = try CatalogIndex(snapshot([photo, audio, video, pdf], text: [photo.id: "Local extracted words"]))
        var query = CatalogQuery(); query.section = .media
        let root = try index.page(query)
        XCTAssertTrue(root.files.isEmpty); XCTAssertEqual(root.groups[0].count, 3)
        query.favorites = true; query.text = "Exam"
        XCTAssertEqual(try index.page(query).groups[0].count, 1)
        query.text = "extracted"
        XCTAssertEqual(try index.page(query).groups[0].count, 1)
        query.minimumBytes = 11
        XCTAssertTrue(try index.page(query).groups.isEmpty)
    }
    func testSubjectAndCollectionRootsHideFilesAndPreserveMembershipEditing() throws {
        let collection = FileCollection(name: "Reading"), emptyCollection = FileCollection(name: "Empty")
        var linked = file("/approved/notes.txt"); linked.collectionIDs = [collection.id]
        let other = file("/approved/other.txt")
        var subject = Subject(name: "Biology"); subject.fileIDs = [linked.id]
        let index = try CatalogIndex(snapshot([linked, other], subjects: [subject], collections: [collection, emptyCollection]))
        var query = CatalogQuery(); query.section = .subjects; query.linkingFileID = linked.id
        let subjects = try index.page(query)
        XCTAssertTrue(subjects.files.isEmpty); XCTAssertTrue(subjects.groups[0].linked)
        query.location = subjects.groups[0].location; query.linkingFileID = nil
        let folders = try index.page(query)
        XCTAssertTrue(folders.files.isEmpty); XCTAssertEqual(folders.groups[0].count, 1)
        query.location = folders.groups[0].location
        XCTAssertEqual(try index.page(query).files.map(\.id), [linked.id])
        query = CatalogQuery(); query.section = .collections; query.linkingFileID = linked.id
        let groups = try index.page(query).groups
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.first { $0.title == "Reading" }!.linked)
        XCTAssertFalse(groups.first { $0.title == "Empty" }!.linked)
        XCTAssertEqual(groups.first { $0.title == "Empty" }!.count, 0)
    }
    func testTimelineDrillsThroughEventMonthAndFolderWithoutInferringStudy() throws {
        var document = file("/approved/notes.txt")
        document.modifiedAt = Date(timeIntervalSince1970: 1_703_000_000)
        let subject = Subject(name: "Physics")
        let session = StudySession(subjectID: subject.id, date: document.indexedAt, minutes: 25, note: "Explicit review")
        let index = try CatalogIndex(snapshot([document], subjects: [subject], sessions: [session]))
        var query = CatalogQuery(); query.section = .timeline
        let events = try index.page(query)
        XCTAssertTrue(events.files.isEmpty); XCTAssertTrue(events.sessions.isEmpty); XCTAssertEqual(events.groups.count, 3)
        query.location = events.groups.first { $0.location.event == .added }!.location
        let months = try index.page(query)
        XCTAssertEqual(months.groups[0].title, "2023-11"); XCTAssertTrue(months.files.isEmpty)
        query.location = months.groups[0].location
        let folders = try index.page(query); XCTAssertTrue(folders.files.isEmpty)
        query.location = folders.groups[0].location
        XCTAssertEqual(try index.page(query).files[0].indexedAt, document.indexedAt)
        query.location = events.groups.first { $0.location.event == .study }!.location
        let studyMonths = try index.page(query); query.location = studyMonths.groups[0].location
        let study = try index.page(query)
        XCTAssertTrue(study.files.isEmpty); XCTAssertEqual(study.sessions.map(\.id), [session.id])
        XCTAssertEqual(study.sessions[0].subject, "Physics")
    }
    func testNotesUseAccountAndSourceFolderInsteadOfPerSnapshotStorageFolders() throws {
        var note = file("/managed/UUID/version/note.txt")
        note.noteSource = ImportedNoteSource(accountID: "cloud", accountName: "iCloud", folderID: "lectures", folderName: "Lectures", noteID: "note1", title: "Research")
        let index = try CatalogIndex(snapshot([note, file("/approved/ordinary.txt")]))
        var query = CatalogQuery(); query.section = .notes
        let accounts = try index.page(query)
        XCTAssertEqual(accounts.groups.map(\.title), ["iCloud"]); XCTAssertTrue(accounts.files.isEmpty)
        query.location = accounts.groups[0].location
        let folders = try index.page(query)
        XCTAssertEqual(folders.groups.map(\.title), ["Lectures"]); XCTAssertTrue(folders.files.isEmpty)
        query.location = folders.groups[0].location
        XCTAssertEqual(try index.page(query).files.map(\.id), [note.id])
    }
    func testDuplicateFolderNamesHaveStablePagesAndNestedApprovedRootsAreCollapsed() throws {
        let files = (0..<150).map { file("/separate-\($0)/Photos/image.txt") }
        let index = try CatalogIndex(snapshot(files, sources: []))
        var query = CatalogQuery()
        var ids = Set<String>()
        for page in 0..<3 {
            query.page = page
            let groups = try index.page(query).groups
            XCTAssertTrue(ids.isDisjoint(with: groups.map(\.id))); ids.formUnion(groups.map(\.id))
        }
        XCTAssertEqual(ids.count, 150)
        let nested = try CatalogIndex(snapshot([file("/approved/nested/file.txt")], sources: ["/approved", "/approved/nested"]))
        XCTAssertEqual(try nested.page(CatalogQuery()).groups.map(\.subtitle), ["/approved"])
    }
    func testEmptyCatalogAndMissingScopeNeverExposeOtherFiles() throws {
        let empty = try CatalogIndex(snapshot([])).page(CatalogQuery())
        XCTAssertEqual(empty.pageCount, 1); XCTAssertEqual(empty.itemCount, 0)
        let index = try CatalogIndex(snapshot([file("/approved/notes.txt")]))
        var query = CatalogQuery(); query.location.subjectID = UUID()
        XCTAssertTrue(try index.page(query).groups.isEmpty)
        query = CatalogQuery(); query.location.folder = "/not-indexed"
        XCTAssertTrue(try index.page(query).files.isEmpty); XCTAssertTrue(try index.page(query).groups.isEmpty)
    }
}
