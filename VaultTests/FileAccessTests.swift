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

    func testStreamingDiscoveryContinuesPastFormerTenThousandFileCap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expectedCount = 10_003
        for index in 0..<expectedCount {
            try Data().write(to: root.appendingPathComponent("entry-\(index).txt"))
        }
        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let cursor = try FolderScanCursor(bookmark: bookmark, excludes: [], categories: [.documents])
        var discovered = 0, selected = 0, batches = 0
        while true {
            let batch = try await cursor.nextBatch()
            discovered += batch.discovery.discovered; selected += batch.discovery.candidates.count; batches += 1
            XCTAssertLessThanOrEqual(batch.discovery.candidates.count, FolderScanCursor.batchCapacity)
            XCTAssertTrue(batch.discovery.errors.isEmpty)
            if batch.finished { break }
        }
        await cursor.close()
        XCTAssertEqual(discovered, expectedCount)
        XCTAssertEqual(selected, expectedCount)
        XCTAssertGreaterThan(batches, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("entry-10002.txt").path))
    }
    func testClosingCursorStopsFurtherDiscoveryWithoutDeletingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("notes.txt"); try Data("original".utf8).write(to: original)
        let bookmark = try root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let cursor = try FolderScanCursor(bookmark: bookmark, excludes: [], categories: ScanFileCategory.all)
        await cursor.close(); await cursor.close()
        let batch = try await cursor.nextBatch()
        XCTAssertTrue(batch.finished); XCTAssertTrue(batch.discovery.candidates.isEmpty)
        XCTAssertEqual(try String(contentsOf: original), "original")
    }

}
