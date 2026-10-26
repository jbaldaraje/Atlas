import XCTest
@testable import VaultCore

final class ExplorationTests: XCTestCase {
    private func file(_ name: String) -> FileItem { FileItem(filename: name, type: URL(fileURLWithPath: name).pathExtension, bookmark: Data(), originalLocation: "/approved/" + name, ownership: .original, size: 10) }
    private func library(_ files: [FileItem], collections: [FileCollection] = []) -> Library { var library = Library(); library.files = files; library.collections = collections; return library }
    func testHistoryBackForwardBranchAndDocumentOnlyNavigation() {
        var history = ExplorationHistory()
        let topic = ExplorationStep(itemID: UUID(), kind: .subject), a = ExplorationStep(itemID: UUID(), kind: .file), b = ExplorationStep(itemID: UUID(), kind: .file)
        history.visit(topic); history.visit(a); history.visit(b)
        XCTAssertEqual(history.previousIndex(kind: .file), 1)
        XCTAssertEqual(history.jump(to: 1), a); XCTAssertTrue(history.canGoForward)
        XCTAssertNil(history.previousIndex(kind: .file)); XCTAssertEqual(history.previousIndex(), 0)
        history.visit(ExplorationStep(itemID: UUID(), kind: .collection))
        XCTAssertEqual(history.steps.count, 3); XCTAssertFalse(history.canGoForward)
        let count = history.steps.count
        history.visit(history.current!)
        XCTAssertEqual(history.steps.count, count)
        XCTAssertNil(history.jump(to: Int.max))
    }
    func testHistoryIsBoundedAndMalformedCursorCannotOverflow() throws {
        var history = ExplorationHistory()
        for _ in 0..<120 { history.visit(ExplorationStep(itemID: UUID(), kind: .file)) }
        XCTAssertEqual(history.steps.count, 80); XCTAssertEqual(history.cursor, 79)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        object["cursor"] = Int.max
        let decoded = try JSONDecoder().decode(ExplorationHistory.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.cursor, 79); XCTAssertFalse(decoded.canGoForward)
        var pruned = decoded; let valid = decoded.steps[20].itemID
        pruned.reconcile(validIDs: [valid]); XCTAssertEqual(pruned.steps.map(\.itemID), [valid]); XCTAssertEqual(pruned.cursor, 0)
    }
    func testSameFolderAndAutomaticTypeCollectionsDoNotInventConnections() throws {
        let a = file("a.pdf"), b = file("b.pdf")
        var folder = FileCollection(name: "Folder"), type = FileCollection(name: "PDF")
        folder.organizationKey = "folder:/approved"; type.organizationKey = "type:pdf"
        var first = a, second = b; first.collectionIDs = [folder.id, type.id]; second.collectionIDs = first.collectionIDs
        let graph = try KnowledgeGraphIndex(library: library([first, second], collections: [folder, type]), subjects: [], relationships: [])
        XCTAssertEqual(try graph.connections(for: a.id, kind: .all, page: 0, facts: [:]).total, 0)
    }
    func testConnectionsExplainExplicitSubjectTagAndCollectionEvidence() throws {
        var a = file("a.pdf"), b = file("b.md"), c = file("c.csv")
        a.tags = ["Project"]; b.tags = ["project"]
        let collection = FileCollection(name: "Thesis project"); a.collectionIDs = [collection.id]; c.collectionIDs = [collection.id]
        var subject = Subject(name: "Biology"); subject.fileIDs = [a.id, b.id]
        let link = Relationship(source: a.id, target: b.id, label: "References my notes")
        let graph = try KnowledgeGraphIndex(library: library([a, b, c], collections: [collection]), subjects: [subject], relationships: [link])
        let result = try graph.connections(for: a.id, kind: .all, page: 0, facts: [:])
        XCTAssertEqual(result.total, 2); XCTAssertEqual(result.documents.first?.id, b.id)
        let notes = try XCTUnwrap(result.documents.first { $0.id == b.id })
        XCTAssertTrue(notes.hasExplicitLink)
        XCTAssertTrue(notes.evidence.contains { $0.detail == link.label && $0.kind == .explicitLink })
        XCTAssertTrue(notes.evidence.contains { $0.kind == .sharedSubject && !$0.suggested })
        XCTAssertTrue(notes.evidence.contains { $0.kind == .sharedTag })
        XCTAssertTrue(result.documents.first { $0.id == c.id }!.evidence.contains { $0.kind == .sharedCollection })
    }
    func testGeneratedSubjectMembershipIsLabeledAndRemovingItRemovesConnection() throws {
        let a = file("Biology.pdf"), b = file("cells.pdf")
        var subject = Subject(name: "Biology"); subject.fileIDs = [a.id, b.id]
        var first = OrganizationFacts(file: a, folderContext: "/approved"), second = OrganizationFacts(file: b, folderContext: "/approved")
        first.generatedSubjectIDs = [subject.id]; second.generatedSubjectIDs = [subject.id]; first.topics = ["Biology": "Filename contains biology"]
        let graph = try KnowledgeGraphIndex(library: library([a, b]), subjects: [subject], relationships: [])
        let reason = try XCTUnwrap(graph.connections(for: a.id, kind: .all, page: 0, facts: [a.id: first, b.id: second]).documents.first?.evidence.first)
        XCTAssertTrue(reason.suggested); XCTAssertTrue(reason.detail.contains("Filename contains biology"))
        subject.fileIDs.remove(b.id)
        let changed = try KnowledgeGraphIndex(library: library([a, b]), subjects: [subject], relationships: [])
        XCTAssertEqual(try changed.connections(for: a.id, kind: .all, page: 0, facts: [:]).total, 0)
    }
    func testIndexedTextMatchesRequireEvidenceAndDismissalDoesNotRemoveUserLink() throws {
        let a = file("a.pdf"), b = file("b.pdf"), c = file("c.pdf")
        let text = try ContentEvidenceIndex(texts: [a.id: "genetics biology cellular analysis", b.id: "cellular genetics biology experiment", c.id: "genetics only"], validIDs: [a.id, b.id, c.id])
        let matches = try text.matches(for: a.id)
        XCTAssertEqual(Set(matches[b.id] ?? []), ["genetics", "biology", "cellular"]); XCTAssertNil(matches[c.id])
        let link = Relationship(source: a.id, target: b.id, label: "Reviewed connection")
        let graph = try KnowledgeGraphIndex(library: library([a, b, c]), subjects: [], relationships: [link])
        let suggestions = try graph.connections(for: a.id, kind: .all, page: 0, facts: [:], textMatches: matches)
        XCTAssertTrue(suggestions.documents[0].evidence.contains { $0.kind == .indexedTerms && $0.sharedTermCount == 3 })
        let dismissed = try graph.connections(for: a.id, kind: .all, page: 0, facts: [:], textMatches: matches, dismissed: [DiscoveryPair(b.id, a.id)])
        XCTAssertEqual(dismissed.total, 1); XCTAssertTrue(dismissed.documents[0].hasExplicitLink)
        XCTAssertFalse(dismissed.documents[0].evidence.contains { $0.kind == .indexedTerms })
    }
    func testGlanceUsesOnlyRealIndexedTextAndMetadata() {
        var a = file("paper.pdf"); a.description = "My saved description"
        let source = "# Genetics overview\nExperiment recorded on 2026-10-26:\nCellular genetics and biology are discussed in this actual source paragraph.\nRepeated cellular genetics concepts are compared with real observations."
        let glance = AtAGlance.make(file: a, text: source)
        XCTAssertTrue(glance.hasText); XCTAssertEqual(glance.description, a.description)
        XCTAssertTrue(glance.headings.contains("# Genetics overview")); XCTAssertEqual(glance.dates, ["2026-10-26"])
        XCTAssertTrue(glance.excerpts.allSatisfy { source.contains($0) }); XCTAssertTrue(glance.terms.contains("genetics"))
        let unavailable = AtAGlance.make(file: a, text: nil)
        XCTAssertFalse(unavailable.hasText); XCTAssertTrue(unavailable.excerpts.isEmpty); XCTAssertTrue(unavailable.terms.isEmpty)
    }
    func testRealNavigationPathHasExistingEdgeIDsAndNoDecorativeEdges() throws {
        let a = file("a.pdf"), b = file("b.pdf")
        var subject = Subject(name: "Shared"); subject.fileIDs = [a.id, b.id]
        let graph = try KnowledgeGraphIndex(library: library([a, b]), subjects: [subject], relationships: [])
        var query = GraphQuery(); query.selectedID = b.id; query.originID = a.id
        let result = try graph.project(query)
        XCTAssertEqual(result.activePathEdgeIDs.count, 2)
        XCTAssertTrue(result.activePathEdgeIDs.isSubset(of: Set(result.edges.map(\.id))))
        XCTAssertTrue(result.nodes.contains { $0.id == a.id }); XCTAssertTrue(result.nodes.contains { $0.id == b.id })
    }
    func testConnectedPagingAndKindFilterRemainBoundedForLargeSubjects() throws {
        let files = (0..<30_123).map { file("document-\($0).pdf") }
        var subject = Subject(name: "Research"); subject.fileIDs = Set(files.map(\.id))
        let graph = try KnowledgeGraphIndex(library: library(files), subjects: [subject], relationships: [])
        let first = try graph.connections(for: files[0].id, kind: .documents, page: 0, facts: [:])
        XCTAssertEqual(first.total, files.count - 1); XCTAssertEqual(first.documents.count, ConnectedDocumentsPage.capacity)
        let last = try graph.connections(for: files[0].id, kind: .documents, page: Int.max, facts: [:])
        XCTAssertEqual(last.page, first.pageCount - 1); XCTAssertLessThanOrEqual(last.documents.count, ConnectedDocumentsPage.capacity)
        XCTAssertEqual(try graph.connections(for: files[0].id, kind: .photos, page: 0, facts: [:]).total, 0)
    }
}
