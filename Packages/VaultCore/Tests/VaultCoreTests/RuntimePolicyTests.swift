import XCTest
@testable import VaultCore

final class RuntimePolicyTests: XCTestCase {
    func testQuietDefaultAndMeaningfulNotificationPolicy() {
        let stages: [ScanStage] = [.counting, .enumerating, .indexing, .organizing, .duplicates, .completed, .cancelled, .interrupted, .failed]
        for stage in stages { XCTAssertFalse(NotificationPreference.off.shouldNotify(stage: stage, hasErrors: true)) }
        XCTAssertFalse(NotificationPreference.important.shouldNotify(stage: .completed, hasErrors: false))
        XCTAssertTrue(NotificationPreference.important.shouldNotify(stage: .completed, hasErrors: true))
        XCTAssertTrue(NotificationPreference.important.shouldNotify(stage: .failed, hasErrors: true))
        XCTAssertTrue(NotificationPreference.scanCompletion.shouldNotify(stage: .completed, hasErrors: false))
        XCTAssertFalse(NotificationPreference.scanCompletion.shouldNotify(stage: .cancelled, hasErrors: true))
        XCTAssertFalse(NotificationPreference.scanCompletion.shouldNotify(stage: .indexing, hasErrors: true))
    }
    func testProgressCoalescesRapidUpdatesButAlwaysPublishesFinalCount() {
        var throttle = ProgressThrottle()
        let emitted = (0..<1000).filter { throttle.shouldPublish(now: Double($0) / 1000) }
        XCTAssertLessThanOrEqual(emitted.count, 10); XCTAssertEqual(emitted.first, 0)
        XCTAssertTrue(throttle.shouldPublish(now: 0.999, final: true))
    }
    func testMonitoringCoalescesOnlyEnabledRootsAndKeepsLaterChanges() {
        let a = UUID(), b = UUID(); var changes = MonitoringChanges()
        changes.mark(a); changes.mark(a); changes.mark(b)
        changes.reconcile(enabled: [a]); XCTAssertEqual(changes.take(), [a]); XCTAssertTrue(changes.dirty.isEmpty)
        changes.mark(a); XCTAssertEqual(changes.dirty, [a])
        changes.reconcile(enabled: []); XCTAssertTrue(changes.dirty.isEmpty)
    }
    func testSignaturesDecodeFromOldCatalogAndChangeDetectionDoesNotUseMtimeAlone() throws {
        var old = FileItem(filename: "a.txt", type: "txt", bookmark: Data(), originalLocation: "/fixture/a.txt", ownership: .original, size: 4)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "changeSignature")
        XCTAssertNil(try JSONDecoder().decode(FileItem.self, from: JSONSerialization.data(withJSONObject: object)).changeSignature)
        old.changeSignature = "first"; var library = Library(); library.files = [old]
        var refreshed = old; refreshed.changeSignature = "changed ctime, same size and mtime"
        let merge = library.mergeScanned([refreshed]); XCTAssertEqual(merge.updated, [old.id])
        XCTAssertEqual(library.files[0].changeSignature, refreshed.changeSignature)
    }
}
