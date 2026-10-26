import XCTest
@testable import VaultCore

final class OrganizationTests: XCTestCase {
    private func file(_ name: String = "Biology.pdf", path: String = "/approved/Biology.pdf") -> FileItem {
        FileItem(filename: name, type: URL(fileURLWithPath: name).pathExtension, bookmark: Data([1]), originalLocation: path, ownership: .original, size: 100)
    }
    func testIdentityMergePreservesMetadataAndPreventsOverlappingFolderDuplicates() {
        var original = file(); original.fileIdentity = "1:42"; original.tags = ["Exam"]; original.favorite = true
        original.description = "My description"
        var library = Library(); library.files = [original]
        var moved = file("Biology.pdf", path: "/other/Biology.pdf"); moved.fileIdentity = "1:42"
        let result = library.mergeScanned([moved, moved])
        XCTAssertEqual(library.files.count, 1)
        XCTAssertEqual(library.files[0].id, original.id)
        XCTAssertEqual(library.files[0].tags, ["Exam"])
        XCTAssertEqual(library.files[0].description, "My description")
        XCTAssertTrue(library.files[0].favorite)
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertEqual(result.fileIDs, [original.id])
    }
    func testOrganizationIsIdempotentAndPreservesManualMembershipsAndLinks() {
        var item = file(); let manual = FileCollection(name: "My collection")
        item.collectionIDs = [manual.id]; item.description = "Unchanged"
        var library = Library(); library.files = [item]; library.collections = [manual]
        var workspace = Workspace(); let other = UUID(); workspace.link(item.id, other, label: "Manual")
        var facts = OrganizationFacts(file: item, folderContext: "/approved")
        facts.topics = ["Biology": "Filename contains biology"]
        let first = OrganizationRules.apply([facts], library: &library, workspace: &workspace)
        let subjectID = workspace.subjects[0].id
        let beforeCollections = library.collections.count
        let second = OrganizationRules.apply([facts], library: &library, workspace: &workspace)
        XCTAssertEqual(workspace.subjects.count, 1)
        XCTAssertEqual(workspace.subjects[0].id, subjectID)
        XCTAssertEqual(workspace.subjects[0].fileIDs, [item.id])
        XCTAssertEqual(library.collections.count, beforeCollections)
        XCTAssertTrue(library.files[0].collectionIDs.contains(manual.id))
        XCTAssertEqual(library.files[0].description, "Unchanged")
        XCTAssertEqual(workspace.relationships.first?.label, "Manual")
        XCTAssertGreaterThan(first.relationshipCount, 0)
        XCTAssertEqual(second.relationshipCount, 0)
    }
    func testPhotoMetadataCreatesDateAndGPSGroupsOnlyWhenFactsExist() {
        var library = Library(); let image = file("photo.jpg"); library.files = [image]
        var workspace = Workspace(); var facts = OrganizationFacts(file: image, folderContext: "/photos")
        facts.captureMonth = "2024-07"
        facts.gpsArea = OrganizationRules.gpsArea(latitude: 14.60, longitude: 120.98, latitudeRef: "N", longitudeRef: "E")
        let counts = OrganizationRules.apply([facts], library: &library, workspace: &workspace)
        XCTAssertEqual(counts.dateGroups.count, 2); XCTAssertEqual(counts.locationGroups.count, 1)
        XCTAssertTrue(library.collections.contains { $0.organizationKey == "photo-month:2024-07" })
        var unknown = file("unknown.jpg"); unknown.id = UUID(); library.files.append(unknown)
        var missing = OrganizationFacts(file: unknown, folderContext: "/photos"); missing.reviewReasons = ["No EXIF date"]
        let second = OrganizationRules.apply([missing], library: &library, workspace: &workspace)
        XCTAssertTrue(second.dateGroups.isEmpty); XCTAssertTrue(second.locationGroups.isEmpty)
        XCTAssertEqual(second.reviewIDs, [unknown.id])
    }
    func testInvalidGPSNeverInventsAnArea() {
        XCTAssertNil(OrganizationRules.gpsArea(latitude: .nan, longitude: 120, latitudeRef: "N", longitudeRef: "E"))
        XCTAssertNil(OrganizationRules.gpsArea(latitude: 100, longitude: 120, latitudeRef: "N", longitudeRef: "E"))
        XCTAssertNil(OrganizationRules.gpsArea(latitude: 14, longitude: 120, latitudeRef: "", longitudeRef: "E"))
    }
    func testTopicRulesRequireEvidenceAndDoNotInventUnsupportedContent() {
        XCTAssertTrue(OrganizationRules.topics(filename: "notes.pdf", context: "/files", tags: [], text: nil, existing: []).isEmpty)
        XCTAssertEqual(OrganizationRules.topics(filename: "Biology notes.pdf", context: "/files", tags: [], text: nil, existing: [])["Biology"], "Filename, folder, or tag contains: biology")
        XCTAssertNil(OrganizationRules.topics(filename: "notes.pdf", context: "", tags: [], text: "cells", existing: [])["Biology"])
        XCTAssertNotNil(OrganizationRules.topics(filename: "notes.pdf", context: "", tags: [], text: "cells and genetics", existing: [])["Biology"])
    }
    func testLegacyFiltersPreserveOldDocumentAndArchiveCoverage() {
        var source = ScanLocation(name: "Old source", bookmark: Data())
        source.includedCategories = [.documents, .other]
        XCTAssertTrue(source.fileCategories.isSuperset(of: [.presentations, .data, .archives]))
        source.categoryVersion = 2
        XCTAssertEqual(source.fileCategories, [.documents, .other])
    }
    func testOldWorkspaceAndFileDocumentsDecodeWithoutOrganizationFields() throws {
        let oldWorkspace = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Workspace())) as! [String: Any]
        var object = oldWorkspace; object.removeValue(forKey: "lastScan"); object.removeValue(forKey: "organizationFacts")
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.lastScan); XCTAssertNil(decoded.organizationFacts)
        let decodedFile = try JSONDecoder().decode(FileItem.self, from: JSONEncoder().encode(file()))
        XCTAssertNil(decodedFile.fileIdentity)
    }
}
