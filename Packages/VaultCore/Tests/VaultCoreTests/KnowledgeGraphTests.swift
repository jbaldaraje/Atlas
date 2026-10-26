import XCTest
@testable import VaultCore

final class KnowledgeGraphTests: XCTestCase {
    private func file(_ name: String) -> FileItem {
        FileItem(filename: name, type: "txt", bookmark: Data(), originalLocation: "/fixture/" + name, ownership: .original, size: 1)
    }
    func testThirtyThousandFileCatalogStaysBoundedAndSearchFindsLastFile() throws {
        var library = Library(); library.files = (0..<30_123).map { file("Document-\($0).txt") }
        let collection = FileCollection(name: "Research"); library.collections = [collection]
        var subject = Subject(name: "Science")
        for index in library.files.indices {
            library.files[index].collectionIDs.insert(collection.id)
            subject.fileIDs.insert(library.files[index].id)
        }
        let graph = try KnowledgeGraphIndex(library: library, subjects: [subject], relationships: [])
        let first = try graph.project(GraphQuery())
        XCTAssertEqual(first.total, 30_125); XCTAssertEqual(first.matching, first.total)
        XCTAssertEqual(first.nodes.count, GraphProjection.nodeBudget)
        XCTAssertLessThanOrEqual(first.edges.count, GraphProjection.edgeBudget)
        let visible = Set(first.nodes.map(\.id))
        XCTAssertTrue(first.edges.allSatisfy { visible.contains($0.source) && visible.contains($0.target) })
        var query = GraphQuery(); query.text = "Document-30122.txt"
        let found = try graph.project(query)
        XCTAssertEqual(found.nodes.map(\.id), [library.files.last!.id])
        query.text = ""; query.page = first.pageCount - 1
        let last = try graph.project(query)
        XCTAssertTrue(last.nodes.contains { $0.id == library.files.last!.id })
        XCTAssertLessThanOrEqual(last.nodes.count, GraphProjection.nodeBudget)
    }
    func testPagingCanReachEveryNodeWithoutDuplicatePages() throws {
        var library = Library(); library.files = (0..<453).map { file("File-\($0).txt") }
        let graph = try KnowledgeGraphIndex(library: library, subjects: [], relationships: [])
        var seen = Set<UUID>(), query = GraphQuery()
        let first = try graph.project(query)
        for page in 0..<first.pageCount {
            query.page = page
            let result = try graph.project(query)
            XCTAssertTrue(seen.isDisjoint(with: result.nodes.map(\.id)))
            seen.formUnion(result.nodes.map(\.id))
        }
        XCTAssertEqual(seen, Set(library.files.map(\.id)))
        query.page = Int.max
        XCTAssertEqual(try graph.project(query).page, first.pageCount - 1)
        query.page = -5
        XCTAssertEqual(try graph.project(query).page, 0)
    }
    func testFocusUsesStoredConnectionsAndRespectsMembershipAndLayers() throws {
        var library = Library(); library.files = [file("Selected.txt"), file("Linked.txt"), file("Unrelated.txt")]
        let selected = library.files[0].id, linked = library.files[1].id
        var subject = Subject(name: "Topic"); subject.fileIDs = [selected]
        let relationship = Relationship(source: selected, target: linked, label: "Related")
        let graph = try KnowledgeGraphIndex(library: library, subjects: [subject], relationships: [relationship])
        var query = GraphQuery(); query.selectedID = selected; query.focus = true
        let focused = try graph.project(query)
        XCTAssertEqual(focused.nodes.first?.id, selected)
        XCTAssertEqual(Set(focused.nodes.map(\.id)), [selected, linked, subject.id])
        query.membership = false
        let manualOnly = try graph.project(query)
        XCTAssertEqual(Set(manualOnly.nodes.map(\.id)), [selected, linked])
        XCTAssertEqual(manualOnly.edges.map(\.id), [relationship.id.uuidString])
        query.membership = true; query.subjects = false
        XCTAssertFalse(try graph.project(query).nodes.contains { $0.kind == .subject })
        query.selectedID = UUID()
        let missing = try graph.project(query)
        XCTAssertFalse(missing.selectedExists); XCTAssertTrue(missing.nodes.isEmpty)
    }
    func testDenseVisibleGraphCapsEdgesAndOmitsDanglingAndSelfLinks() throws {
        var library = Library(); library.files = (0..<60).map { file("\($0).txt") }
        var links: [Relationship] = []
        for a in 0..<60 {
            for b in (a + 1)..<60 { links.append(Relationship(source: library.files[a].id, target: library.files[b].id, label: "Related")) }
        }
        links.append(Relationship(source: library.files[0].id, target: UUID(), label: "Missing"))
        links.append(Relationship(source: library.files[0].id, target: library.files[0].id, label: "Self"))
        let graph = try KnowledgeGraphIndex(library: library, subjects: [], relationships: links)
        let result = try graph.project(GraphQuery())
        XCTAssertEqual(result.edges.count, GraphProjection.edgeBudget)
        XCTAssertTrue(result.edgesTruncated)
        XCTAssertEqual(Set(result.edges.map(\.id)).count, result.edges.count)
        XCTAssertTrue(result.edges.allSatisfy { $0.source != $0.target })
        let empty = try KnowledgeGraphIndex(library: Library(), subjects: [], relationships: []).project(GraphQuery())
        XCTAssertEqual(empty.pageCount, 1); XCTAssertTrue(empty.nodes.isEmpty)
    }
    func testThirtyThousandFileCachedProjectionPerformance() throws {
        var library = Library(); library.files = (0..<30_123).map { file("File-\($0).txt") }
        let graph = try KnowledgeGraphIndex(library: library, subjects: [], relationships: [])
        measure {
            do { XCTAssertEqual(try graph.project(GraphQuery()).nodes.count, GraphProjection.nodeBudget) }
            catch { XCTFail("Projection failed") }
        }
    }
}
