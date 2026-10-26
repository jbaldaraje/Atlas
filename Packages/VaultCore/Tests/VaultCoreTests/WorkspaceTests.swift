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
}
