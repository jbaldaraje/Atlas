import XCTest
import CryptoKit
import VaultCore

final class FeatureTests: XCTestCase {
    private func fixture(_ url: URL, ownership: StorageOwnership = .original) throws -> FileItem {
        FileItem(filename: url.lastPathComponent, type: "txt", bookmark: try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), originalLocation: url.path, ownership: ownership, size: Int64(try Data(contentsOf: url).count))
    }
    func testHashingGroupsEqualFilesAndDeduplicatesHardLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt"), c = root.appendingPathComponent("c.txt"), hard = root.appendingPathComponent("hard.txt")
        try Data("same".utf8).write(to: a); try Data("same".utf8).write(to: b); try Data("diff".utf8).write(to: c)
        try FileManager.default.linkItem(at: a, to: hard)
        let files = try [a, b, c, hard].map { try fixture($0) }
        let report = try await AnalysisService().analyze(files, hash: true)
        XCTAssertEqual(report.files.count, 3); XCTAssertEqual(report.logicalBytes, 12)
        XCTAssertEqual(report.duplicates.count, 1); XCTAssertEqual(report.duplicates.first?.count, 2)
        XCTAssertTrue(report.failedIDs.isEmpty)
    }
    func testManagedRecoveryPreservesPayloadAndOriginalSafety() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Files/unique")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("notes.txt")
        try Data("retain".utf8).write(to: url)
        let service = RecoveryService(base: base)
        do { try await service.retain(fixture(url)); XCTFail("Original accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try await service.retain(fixture(url, ownership: .managedCopy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let entries = try await service.list()
        let entry = try XCTUnwrap(entries.first)
        let restored = try await service.restore(entry)
        XCTAssertEqual(try String(contentsOfFile: restored.originalLocation), "retain")
        do { _ = try await service.restore(entry); XCTFail("Overwrite accepted") } catch {}
        try await service.finish(entry)
        let remaining = try await service.list()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testAuthenticatedEncryptionRejectsTamperingAndWrongKey() throws {
        let key = SymmetricKey(size: .bits256), other = SymmetricKey(size: .bits256)
        let plaintext = Data("sensitive fixture".utf8)
        let box = try AES.GCM.seal(plaintext, using: key)
        XCTAssertEqual(try AES.GCM.open(box, using: key), plaintext)
        XCTAssertThrowsError(try AES.GCM.open(box, using: other))
        var altered = try XCTUnwrap(box.combined); altered[altered.count - 1] ^= 1
        let tampered = try AES.GCM.SealedBox(combined: altered)
        XCTAssertThrowsError(try AES.GCM.open(tampered, using: key))
    }
    func testLocalTextExtraction() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Biology study notes".utf8).write(to: url)
        let result = try await ContentService().extract(fixture(url), ocr: false)
        XCTAssertEqual(result, "Biology study notes")
    }
}

final class SecurePersistenceTests: XCTestCase {
    func testEncryptedRecordRepositoryRoundTripAndCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("records.aesgcm")
        let repository = EncryptedRecordRepository(url: url)
        let key = SymmetricKey(size: .bits256)
        let item = SecureRecord(title: "private-title-fixture", username: "private-user-fixture", secret: "private-secret-fixture", note: "private-note-fixture")
        try repository.save([item], key: key)
        let encrypted = try Data(contentsOf: url)
        XCTAssertNil(encrypted.range(of: Data(item.secret.utf8)))
        XCTAssertNil(encrypted.range(of: Data(item.title.utf8)))
        let loaded = try repository.load(key: key)
        XCTAssertEqual(loaded.first?.secret, item.secret)
        XCTAssertThrowsError(try repository.load(key: SymmetricKey(size: .bits256)))
        var corrupted = encrypted; corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: url)
        XCTAssertThrowsError(try repository.load(key: key))
        XCTAssertEqual(try Data(contentsOf: url), corrupted)
    }
    @MainActor func testLockedStoreRejectsWrites() {
        let store = SecureStore()
        XCTAssertFalse(store.unlocked)
        store.save(SecureRecord(title: "fixture", username: "", secret: "test", note: ""))
        XCTAssertTrue(store.records.isEmpty)
        store.lock()
        XCTAssertFalse(store.unlocked)
    }
}
