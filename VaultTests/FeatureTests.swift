import XCTest
import CryptoKit
import LocalAuthentication
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

/// No real Keychain or biometric prompts: exercise the store's actual async state transitions.
@MainActor
final class SecureUnlockTests: XCTestCase {
    private final class AuthenticationGate {
        let started = XCTestExpectation(description: "Authentication requested")
        var continuation: CheckedContinuation<Void, Error>?
        func authenticate(_ context: LAContext) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        func succeed() { continuation?.resume(); continuation = nil }
    }
    private func fixtureURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("records.aesgcm")
    }
    func testAuthenticationPanelFocusLossDoesNotCancelUnlock() async throws {
        let gate = AuthenticationGate(), url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = SymmetricKey(size: .bits256)
        let store = SecureStore(url: url, authenticate: gate.authenticate, keyAccess: { _, _ in key }, applicationIsActive: { true }, observeSystemEvents: false)
        store.unlock()
        await fulfillment(of: [gate.started], timeout: 2)
        store.applicationDeactivated()
        XCTAssertTrue(store.authenticating)
        XCTAssertFalse(store.unlocked)
        gate.succeed()
        await store.waitForUnlock()
        XCTAssertTrue(store.unlocked)
        XCTAssertNil(store.error)
        store.applicationDeactivated()
        XCTAssertFalse(store.unlocked)
        XCTAssertTrue(store.records.isEmpty)
    }
    func testExplicitLockCancelsPendingAuthenticationAndPreventsKeyAccess() async throws {
        let gate = AuthenticationGate(), url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var keyAccessed = false
        let store = SecureStore(url: url, authenticate: gate.authenticate, keyAccess: { _, _ in
            keyAccessed = true; return SymmetricKey(size: .bits256)
        }, applicationIsActive: { true }, observeSystemEvents: false)
        store.unlock()
        await fulfillment(of: [gate.started], timeout: 2)
        store.lock()
        gate.succeed()
        await store.waitForUnlock()
        XCTAssertFalse(keyAccessed)
        XCTAssertFalse(store.unlocked)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.error)
    }
    func testMissingKeyPreservesEncryptedRecordFile() async throws {
        let url = fixtureURL(), key = SymmetricKey(size: .bits256)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try EncryptedRecordRepository(url: url).save([SecureRecord(title: "fixture", username: "", secret: "private", note: "")], key: key)
        let before = try Data(contentsOf: url)
        let store = SecureStore(url: url, authenticate: { _ in }, keyAccess: { _, exists in
            XCTAssertTrue(exists); throw SecureStore.UnlockError.missingKey
        }, applicationIsActive: { true }, observeSystemEvents: false)
        store.unlock(); await store.waitForUnlock()
        XCTAssertFalse(store.unlocked)
        XCTAssertTrue(store.error?.contains("encryption key was not found") == true)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testWrongKeyFailsWithoutExposingOrReplacingRecords() async throws {
        let url = fixtureURL(), key = SymmetricKey(size: .bits256)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try EncryptedRecordRepository(url: url).save([SecureRecord(title: "fixture", username: "", secret: "private", note: "")], key: key)
        let before = try Data(contentsOf: url)
        let store = SecureStore(url: url, authenticate: { _ in }, keyAccess: { _, _ in SymmetricKey(size: .bits256) }, applicationIsActive: { true }, observeSystemEvents: false)
        store.unlock(); await store.waitForUnlock()
        XCTAssertFalse(store.unlocked)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.error?.contains("could not be read or authenticated") == true)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testUserCancellationLeavesVaultLockedWithoutGenericFailure() async {
        let store = SecureStore(url: fixtureURL(), authenticate: { _ in
            throw NSError(domain: LAError.errorDomain, code: LAError.Code.userCancel.rawValue)
        }, keyAccess: { _, _ in XCTFail("Cancelled authentication must not access the key"); return SymmetricKey(size: .bits256) }, applicationIsActive: { true }, observeSystemEvents: false)
        store.unlock(); await store.waitForUnlock()
        XCTAssertFalse(store.unlocked)
        XCTAssertNil(store.error)
    }
    func testInactiveApplicationNeverReceivesUnlockedRecords() async {
        var keyAccessed = false
        let store = SecureStore(url: fixtureURL(), authenticate: { _ in }, keyAccess: { _, _ in
            keyAccessed = true; return SymmetricKey(size: .bits256)
        }, applicationIsActive: { false }, observeSystemEvents: false)
        store.unlock(); await store.waitForUnlock()
        XCTAssertFalse(keyAccessed)
        XCTAssertFalse(store.unlocked)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.error?.contains("did not regain focus") == true)
    }

}
