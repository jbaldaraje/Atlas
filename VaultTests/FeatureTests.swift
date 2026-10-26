import XCTest
import CryptoKit
import LocalAuthentication
import ImageIO
import CoreGraphics
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

@MainActor
final class SmartFolderScanTests: XCTestCase {
    func testScanPipelinePersistsCatalogGraphAndIdempotentRescan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources"), storage = root.appendingPathComponent("Storage")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("cells and genetics".utf8).write(to: sources.appendingPathComponent("Biology.txt"))
        try Data("unknown content".utf8).write(to: sources.appendingPathComponent("notes.txt"))
        let library = LibraryStore(base: storage), workspace = WorkspaceStore(base: storage)
        var source = ScanLocation(name: "Sources", bookmark: try sources.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
        source.sourcePath = sources.path; source.sourceIdentity = FileAccessService.identity(at: sources)
        workspace.pendingLocations = [source]; workspace.scanCategories = [.documents]; workspace.scanMonitorFolders = false
        workspace.startFolderScan(library: library); await workspace.scanTask?.value
        XCTAssertEqual(library.library.files.count, 2)
        XCTAssertEqual(workspace.data.lastScan?.stage, .completed)
        XCTAssertEqual(workspace.data.lastScan?.addedIDs.count, 2)
        XCTAssertTrue(workspace.data.subjects.contains { $0.name == "Biology" && !$0.fileIDs.isEmpty })
        XCTAssertTrue(library.library.collections.contains { $0.organizationKey == "needs-review" })
        XCTAssertFalse(workspace.data.organizationFacts?.isEmpty ?? true)
        XCTAssertTrue(workspace.data.locations.isEmpty)
        workspace.change { data in
            for index in data.subjects.indices { data.subjects[index].fileIDs = [] }
        }
        workspace.retryScan(library: library); await workspace.scanTask?.value
        XCTAssertTrue(workspace.data.subjects.allSatisfy { $0.fileIDs.isEmpty })
        XCTAssertEqual(library.library.files.count, 2)
        XCTAssertEqual(workspace.data.lastScan?.addedIDs.count, 0)
        XCTAssertEqual(workspace.data.lastScan?.relationshipCount, 0)
        let loaded = WorkspaceStore(base: storage)
        XCTAssertEqual(loaded.data.lastScan?.stage, .completed)
        XCTAssertEqual(loaded.data.subjects.count, workspace.data.subjects.count)
        XCTAssertEqual(try String(contentsOf: sources.appendingPathComponent("Biology.txt")), "cells and genetics")
    }
    func testInterruptedScanIsRecoveredAsRetryableWithoutRemovingCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = WorkspaceStore(base: root)
        var job = ScanJob(sources: []); job.stage = .organizing
        first.change { $0.lastScan = job }
        let reopened = WorkspaceStore(base: root)
        XCTAssertEqual(reopened.data.lastScan?.stage, .interrupted)
    }
    func testRealEXIFMetadataDrivesPhotoGroupsAndGPSOptIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2024:07:15 10:20:30"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 14.60, kCGImagePropertyGPSLatitudeRef as String: "N", kCGImagePropertyGPSLongitude as String: 120.98, kCGImagePropertyGPSLongitudeRef as String: "E"]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let file = FileItem(filename: "fixture.jpg", type: "jpg", bookmark: bookmark, originalLocation: url.path, ownership: .original, size: Int64(try Data(contentsOf: url).count))
        var source = ScanLocation(name: "Photos", bookmark: Data()); source.includePhotoLocations = true
        let service = SmartOrganizationService()
        let allowed = try await service.facts(for: file, source: source, existingSubjects: [])
        XCTAssertEqual(allowed.0.captureMonth, "2024-07")
        XCTAssertNotNil(allowed.0.gpsArea)
        XCTAssertTrue(allowed.0.gpsArea?.contains("approx.") == true)
        source.includePhotoLocations = false
        let withheld = try await service.facts(for: file, source: source, existingSubjects: [])
        XCTAssertEqual(withheld.0.captureMonth, "2024-07")
        XCTAssertNil(withheld.0.gpsArea)
    }
    func testCancelledScanRetainsOriginalAndSupportsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source"), storage = root.appendingPathComponent("Storage")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let url = sourceURL.appendingPathComponent("notes.txt"); try Data("original".utf8).write(to: url)
        let library = LibraryStore(base: storage), workspace = WorkspaceStore(base: storage)
        let bookmark = try sourceURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        workspace.pendingLocations = [ScanLocation(name: "Source", bookmark: bookmark)]
        workspace.scanMonitorFolders = false
        workspace.startFolderScan(library: library); workspace.cancelScan(); await workspace.scanTask?.value
        XCTAssertEqual(workspace.data.lastScan?.stage, .cancelled)
        XCTAssertEqual(try String(contentsOf: url), "original")
        workspace.retryScan(library: library); await workspace.scanTask?.value
        XCTAssertEqual(workspace.data.lastScan?.stage, .completed)
        XCTAssertEqual(library.library.files.count, 1)
    }

    func testCatalogScanProcessesEveryStreamingBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source"), storage = root.appendingPathComponent("Storage")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let count = FolderScanCursor.batchCapacity + 5
        for index in 0..<count { try Data().write(to: sourceURL.appendingPathComponent("notes-\(index).txt")) }
        let library = LibraryStore(base: storage), workspace = WorkspaceStore(base: storage)
        let bookmark = try sourceURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        workspace.pendingLocations = [ScanLocation(name: "Source", bookmark: bookmark)]; workspace.scanMonitorFolders = false
        workspace.startFolderScan(library: library); await workspace.scanTask?.value
        XCTAssertEqual(workspace.data.lastScan?.stage, .completed)
        XCTAssertEqual(workspace.data.lastScan?.discovered, count)
        XCTAssertEqual(workspace.data.lastScan?.processed, count)
        XCTAssertEqual(workspace.data.lastScan?.progress?.totalFiles, count)
        XCTAssertEqual(workspace.data.lastScan?.progress?.countedEntries, count)
        XCTAssertEqual(workspace.data.lastScan?.progress?.indexedFiles, count)
        XCTAssertEqual(workspace.data.lastScan?.progress?.organizedFiles, count)
        XCTAssertEqual(workspace.data.lastScan?.percentCompleted, 100)
        XCTAssertEqual(workspace.data.lastScan?.addedIDs.count, count)
        XCTAssertEqual(library.library.files.count, count)
        XCTAssertEqual(LibraryStore(base: storage).library.files.count, count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent("notes-\(count - 1).txt").path))
    }

    func testMinimizedScanFinishesWithoutReopeningSheetAndCanShowResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"), storage = root.appendingPathComponent("Storage")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try Data("image".utf8).write(to: source.appendingPathComponent("ignored.png"))
        let library = LibraryStore(base: storage), workspace = WorkspaceStore(base: storage)
        let bookmark = try source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        workspace.pendingLocations = [ScanLocation(name: "Source", bookmark: bookmark)]
        workspace.scanCategories = [.documents]; workspace.scanMonitorFolders = false
        workspace.startFolderScan(library: library)
        let jobID = workspace.activeScan?.id
        workspace.minimizeScan(); workspace.cancelFolderReview() // Matches sheet onDismiss.
        XCTAssertTrue(workspace.scanIsActive); XCTAssertTrue(workspace.scanMinimized); XCTAssertFalse(workspace.reviewFolder)
        workspace.dismissScanStatus()
        XCTAssertTrue(workspace.scanMinimized) // Running work cannot be silently hidden.
        workspace.showScanResults()
        XCTAssertTrue(workspace.reviewFolder); XCTAssertFalse(workspace.scanMinimized)
        XCTAssertEqual(workspace.activeScan?.id, jobID)
        workspace.minimizeScan()
        await workspace.scanTask?.value
        XCTAssertFalse(workspace.reviewFolder); XCTAssertTrue(workspace.scanMinimized)
        XCTAssertEqual(workspace.data.lastScan?.stage, .completed)
        XCTAssertEqual(workspace.data.lastScan?.progress?.totalFiles, 1)
        XCTAssertEqual(workspace.data.lastScan?.discovered, 2) // Counting pass is not double-counted.
        XCTAssertEqual(library.library.search("notes").count, 1)
        XCTAssertEqual(WorkspaceStore(base: storage).data.lastScan?.percentCompleted, 100)
        workspace.showScanResults()
        XCTAssertTrue(workspace.reviewFolder); XCTAssertEqual(workspace.scanPresentation, .results)
        XCTAssertEqual(workspace.activeScan?.id, jobID)
        workspace.dismissScanStatus(); XCTAssertFalse(workspace.scanMinimized)
    }
    func testCancelWhileMinimizedKeepsStatusAndRetryStartsNewJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source"), storage = root.appendingPathComponent("Storage")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("notes.txt"); try Data("original".utf8).write(to: file)
        let library = LibraryStore(base: storage), workspace = WorkspaceStore(base: storage)
        let bookmark = try source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        workspace.pendingLocations = [ScanLocation(name: "Source", bookmark: bookmark)]; workspace.scanMonitorFolders = false
        workspace.startFolderScan(library: library); let firstID = workspace.activeScan?.id
        workspace.minimizeScan(); workspace.cancelScan()
        XCTAssertTrue(workspace.scanCancellationRequested)
        await workspace.scanTask?.value
        XCTAssertEqual(workspace.data.lastScan?.stage, .cancelled)
        XCTAssertNil(workspace.data.lastScan?.percentCompleted)
        XCTAssertTrue(workspace.scanMinimized); XCTAssertFalse(workspace.reviewFolder)
        XCTAssertFalse(workspace.scanCancellationRequested)
        workspace.retryScan(library: library)
        XCTAssertNotEqual(workspace.activeScan?.id, firstID)
        XCTAssertFalse(workspace.scanMinimized); XCTAssertTrue(workspace.reviewFolder)
        await workspace.scanTask?.value
        XCTAssertEqual(workspace.data.lastScan?.percentCompleted, 100)
        XCTAssertEqual(try String(contentsOf: file), "original")
    }

    func testEmptyScanFinishesWithKnownZeroTotal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let library = LibraryStore(base: root.appendingPathComponent("Storage")), workspace = WorkspaceStore(base: root.appendingPathComponent("Storage"))
        let bookmark = try source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        workspace.pendingLocations = [ScanLocation(name: "Empty", bookmark: bookmark)]; workspace.scanMonitorFolders = false
        workspace.startFolderScan(library: library); await workspace.scanTask?.value
        XCTAssertEqual(workspace.data.lastScan?.stage, .completed)
        XCTAssertEqual(workspace.data.lastScan?.progress?.totalFiles, 0)
        XCTAssertEqual(workspace.data.lastScan?.percentCompleted, 100)
        XCTAssertTrue(library.library.files.isEmpty)
    }

}

final class VaultActivityTests: XCTestCase {
    func testMascotUsesMeasuredScanProgressAndRejectsInvalidValues() {
        var input = VaultActivityInput(); input.scanStage = .counting
        XCTAssertNil(VaultActivity.resolve(input).progress)
        input.scanStage = .indexing; input.scanProgress = 0.42
        XCTAssertEqual(VaultActivity.resolve(input).progress, 0.42)
        XCTAssertTrue(VaultActivity.resolve(input).detail.contains("42%"))
        input.scanProgress = .nan
        XCTAssertNil(VaultActivity.resolve(input).progress)
        input.scanProgress = 1
        XCTAssertEqual(VaultActivity.resolve(input).progress, 0.99)
    }
    func testScanActivityUsesRealCountsWithoutInventingCompletionPercentage() {
        var input = VaultActivityInput(); input.scanStage = .organizing
        input.discovered = 10003; input.processed = 9000; input.activeFolders = 3
        let activity = VaultActivity.resolve(input)
        XCTAssertEqual(activity.kind, .organizing)
        XCTAssertTrue(activity.detail.contains("10003")); XCTAssertTrue(activity.detail.contains("9000"))
        XCTAssertNil(activity.progress)
    }
    func testKnownImportProgressClampsAndUnknownTotalStaysIndeterminate() {
        var input = VaultActivityInput(); input.importing = true
        XCTAssertNil(VaultActivity.resolve(input).progress)
        input.importTotal = 10; input.importProgress = 3
        XCTAssertEqual(VaultActivity.resolve(input).progress, 0.3)
        input.importProgress = 20
        XCTAssertEqual(VaultActivity.resolve(input).progress, 1)
        input.importProgress = -1
        XCTAssertEqual(VaultActivity.resolve(input).progress, 0)
    }
    func testAuthenticationAndErrorsOverrideReadyOrUnlockedStatus() {
        var input = VaultActivityInput(); input.secureSelected = true; input.secureUnlocked = true
        input.authenticating = true
        XCTAssertEqual(VaultActivity.resolve(input).kind, .authenticating)
        input.hasError = true
        XCTAssertEqual(VaultActivity.resolve(input).kind, .attention)
    }
    func testMonitoringReadyAndPausedAreDifferentStates() {
        var input = VaultActivityInput(); input.activeFolders = 2
        XCTAssertEqual(VaultActivity.resolve(input).kind, .idle)
        XCTAssertTrue(VaultActivity.resolve(input).detail.contains("while open"))
        input.monitoring = true
        XCTAssertEqual(VaultActivity.resolve(input).kind, .monitoring)
        input.monitoring = false; input.activeFolders = 0; input.pausedFolders = 2
        XCTAssertEqual(VaultActivity.resolve(input).kind, .paused)
    }
    func testSecureStatusDescribesOnlySeparateSecureRecords() {
        var input = VaultActivityInput(); input.secureSelected = true; input.catalogFiles = 500
        let locked = VaultActivity.resolve(input)
        XCTAssertEqual(locked.kind, .locked)
        XCTAssertEqual(locked.detail, "Separate encrypted records")
        input.secureUnlocked = true
        XCTAssertEqual(VaultActivity.resolve(input).kind, .unlocked)
        input.secureSelected = false
        XCTAssertEqual(VaultActivity.resolve(input).kind, .idle)
    }
}

@MainActor
final class NotesSnapshotTests: XCTestCase {
    func testImportRefreshAndRestartPreserveIdentityMetadataAndOtherFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(base: root)
        let source = ImportedNoteSource(accountID: "account", accountName: "iCloud", folderID: "folder", folderName: "Notes", noteID: "note-1", title: "Research")
        let first = try await library.importNote(ImportedNoteSnapshot(source: source, text: "First text"))
        var edited = first; edited.tags = ["Study"]; edited.favorite = true
        XCTAssertTrue(library.update(edited))
        let sibling = URL(fileURLWithPath: first.originalLocation).deletingLastPathComponent().appendingPathComponent("keep.txt")
        try Data("user file".utf8).write(to: sibling)
        let refreshed = try await library.importNote(ImportedNoteSnapshot(source: source, text: "Updated text"))
        XCTAssertEqual(refreshed.id, first.id); XCTAssertEqual(library.library.files.count, 1)
        XCTAssertEqual(refreshed.tags, ["Study"]); XCTAssertTrue(refreshed.favorite)
        XCTAssertEqual(try String(contentsOfFile: refreshed.originalLocation), "Updated text")
        XCTAssertEqual(try String(contentsOf: sibling), "user file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.originalLocation))
        let unchanged = try await library.importNote(ImportedNoteSnapshot(source: source, text: "Updated text"))
        XCTAssertEqual(unchanged.originalLocation, refreshed.originalLocation)
        XCTAssertEqual(LibraryStore(base: root).library.files.first?.noteSource?.noteID, "note-1")
    }
    func testRefreshDoesNotOverwriteLocalEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(base: root)
        let source = ImportedNoteSource(accountID: "account", accountName: "iCloud", folderID: "folder", folderName: "Notes", noteID: "note-1", title: "Research")
        let first = try await library.importNote(ImportedNoteSnapshot(source: source, text: "Initial"))
        try Data("Keep my manual edits".utf8).write(to: URL(fileURLWithPath: first.originalLocation))
        do { _ = try await library.importNote(ImportedNoteSnapshot(source: source, text: "Remote update")); XCTFail("Local edit overwritten") }
        catch {}
        XCTAssertEqual(try String(contentsOfFile: first.originalLocation), "Keep my manual edits")
        XCTAssertEqual(library.library.files.first?.originalLocation, first.originalLocation)
    }
    func testNotesPermissionAndLockErrorsHaveSpecificSafeMessages() {
        XCTAssertTrue(AppleNotesBridge.NotesError.automation(-1743).errorDescription?.contains("Automation") == true)
        XCTAssertTrue(AppleNotesBridge.NotesError.automation(-2700).errorDescription?.contains("locked") == true)
        XCTAssertTrue(AppleNotesBridge.NotesError.automation(-1712).errorDescription?.contains("respond in time") == true)
    }
}
