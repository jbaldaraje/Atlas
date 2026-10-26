import XCTest
import VaultCore

final class FileAccessTests: XCTestCase {
    func testVerifiedCopyAndConflictIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("notes.txt")
        try Data("Study notes".utf8).write(to: source)
        let candidates = try await FileAccessService.inspect([source])
        let managed = root.appendingPathComponent("Managed")
        let first = await FileAccessService.run(candidates, copy: true, managedDirectory: managed, existingPaths: [])
        let second = await FileAccessService.run(candidates, copy: true, managedDirectory: managed, existingPaths: [])
        XCTAssertTrue(first.failures.isEmpty); XCTAssertTrue(second.failures.isEmpty)
        let a = try XCTUnwrap(first.items.first), b = try XCTUnwrap(second.items.first)
        XCTAssertNotEqual(a.originalLocation, b.originalLocation)
        XCTAssertEqual(a.ownership, .managedCopy)
        XCTAssertEqual(try String(contentsOf: source), "Study notes")
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: source.path, andPath: a.originalLocation))
        let content = try FileAccessService.withAccess(a) { try String(contentsOf: $0) }
        XCTAssertEqual(content, "Study notes")
    }
    func testDuplicateReferenceAndMissingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: source)
        let candidates = try await FileAccessService.inspect([source])
        let duplicate = await FileAccessService.run(candidates, copy: false, managedDirectory: root, existingPaths: [source.path])
        XCTAssertEqual(duplicate.skipped, 1); XCTAssertTrue(duplicate.items.isEmpty)
        let imported = await FileAccessService.run(candidates, copy: false, managedDirectory: root, existingPaths: [])
        let item = try XCTUnwrap(imported.items.first)
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try FileAccessService.withAccess(item) { url in url.path })
    }
    func testRejectsFoldersAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { _ = try await FileAccessService.inspect([root]); XCTFail("Folder accepted") } catch {}
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        do { _ = try await FileAccessService.inspect([link]); XCTFail("Symlink accepted") } catch {}
    }
    func testFolderScanFiltersCategoriesAndExcludesHiddenAndLinkedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["notes.docx", "paper.PDF", "image.png", "video.mp4", "audio.mp3", "archive.zip", ".hidden.pdf"] {
            try Data("category fixture".utf8).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.pdf"), withDestinationURL: root.appendingPathComponent("paper.PDF"))
        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let selected = try await FileAccessService.scanFolder(bookmark, excludes: [], categories: [.documents, .pdf])
        XCTAssertEqual(Set(selected.map { $0.url.lastPathComponent }), ["notes.docx", "paper.PDF"])
        let media = try await FileAccessService.scanFolder(bookmark, excludes: [], categories: [.media])
        XCTAssertEqual(Set(media.map { $0.url.lastPathComponent }), ["video.mp4", "audio.mp3"])
        let all = try await FileAccessService.scanFolder(bookmark, excludes: [])
        XCTAssertEqual(all.count, 6)
        let none = try await FileAccessService.scanFolder(bookmark, excludes: [], categories: [])
        XCTAssertTrue(none.isEmpty)
    }

}
