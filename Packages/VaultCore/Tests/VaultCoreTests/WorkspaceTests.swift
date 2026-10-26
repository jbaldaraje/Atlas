import XCTest
@testable import VaultCore

final class WorkspaceTests: XCTestCase {
    func testRelationshipUniquenessAndReconciliation() {
        let a = UUID(), b = UUID(), missing = UUID()
        var data = Workspace()
        data.link(a, b, label: "Related"); data.link(b, a, label: "Duplicate"); data.link(a, a, label: "Self")
        XCTAssertEqual(data.relationships.count, 1)
        data.link(a, missing, label: "Missing")
        var subject = Subject(name: "Physics"); subject.fileIDs = [a, missing]
        data.subjects = [subject]; data.extractedText = [a: "kept", missing: "removed"]
        data.reconcile(validIDs: [a, b])
        XCTAssertEqual(data.relationships.count, 1)
        XCTAssertEqual(data.subjects[0].fileIDs, [a])
        XCTAssertNil(data.extractedText[missing])
    }
    func testWorkspaceRoundTripAndExplicitStudyEvents() throws {
        var data = Workspace(); let subject = Subject(name: "Biology")
        data.subjects.append(subject)
        data.sessions.append(StudySession(subjectID: subject.id, minutes: 20, note: "Cell diagrams"))
        data.locations.append(ScanLocation(name: "Chosen folder", bookmark: Data([4])))
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded, data)
        XCTAssertEqual(decoded.sessions.count, 1)
    }
    func testScanCategoriesSeparatePDFsDocumentsImagesAndMedia() {
        let examples: [(String, ScanFileCategory)] = [
            ("doc", .documents), ("docx", .documents), ("pptx", .presentations),
            ("xlsx", .data), ("pages", .documents), ("md", .documents),
            ("PDF", .pdf), (".pdf", .pdf), ("jpg", .images), ("HEIC", .images),
            ("png", .images), ("mp4", .media), ("mov", .media), ("mp3", .media),
            ("flac", .media), ("zip", .archives), ("unknown", .other), ("", .other)
        ]
        for (fileExtension, expected) in examples {
            XCTAssertEqual(ScanFileCategory.classify(fileExtension: fileExtension), expected, fileExtension)
        }
    }
    func testLegacyScanLocationKeepsAllTypesWhenCategoryFieldIsMissing() throws {
        let location = ScanLocation(name: "Existing folder", bookmark: Data([1]))
        let encoded = try JSONEncoder().encode(location)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "includedCategories")
        let decoded = try JSONDecoder().decode(ScanLocation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.fileCategories, ScanFileCategory.all)
    }
    func testScanCategorySelectionsSurvivePersistenceIncludingExplicitNone() throws {
        var location = ScanLocation(name: "Study", bookmark: Data([1]))
        location.includedCategories = [.documents, .pdf]
        location.categoryVersion = 2
        var decoded = try JSONDecoder().decode(ScanLocation.self, from: JSONEncoder().encode(location))
        XCTAssertEqual(decoded.fileCategories, [.documents, .pdf])
        XCTAssertFalse(decoded.fileCategories.contains(.images))
        location.includedCategories = []
        decoded = try JSONDecoder().decode(ScanLocation.self, from: JSONEncoder().encode(location))
        XCTAssertTrue(decoded.fileCategories.isEmpty)
    }

}
