import Foundation
import Combine
import VaultCore

struct ExplorerRequest: Equatable, Sendable {
    let revision: GraphRevision
    let textRevision: UUID
    let id: UUID
    let kind: FileKindFilter
    let page: Int
    let compareText: Bool
    let dismissed: Set<DiscoveryPair>
}
struct ExplorerSnapshot: Sendable {
    let glance: AtAGlance
    let connections: ConnectedDocumentsPage
    let subjects: [VaultCore.Subject]
    let collections: [FileCollection]
    let tags: [String]
}
extension KnowledgeGraphEngine {
    func explorer(_ request: ExplorerRequest, library: Library, workspace: Workspace) throws -> ExplorerSnapshot {
        try ensureIndex(revision: request.revision, library: library, subjects: workspace.subjects, relationships: workspace.relationships)
        guard let graphIndex, let file = graphIndex.file(id: request.id) else { throw CocoaError(.fileNoSuchFile) }
        var matches: [UUID: [String]] = [:]
        if request.compareText {
            if contentIndex == nil || contentRevision != request.textRevision {
                contentIndex = try ContentEvidenceIndex(texts: workspace.extractedText, validIDs: graphIndex.fileIDs)
                contentRevision = request.textRevision
            }
            matches = try contentIndex?.matches(for: request.id) ?? [:]
        }
        let connections = try graphIndex.connections(for: request.id, kind: request.kind, page: request.page,
            facts: workspace.organizationFacts ?? [:], textMatches: matches, dismissed: request.dismissed)
        try Task.checkCancellation()
        return ExplorerSnapshot(glance: AtAGlance.make(file: file, text: workspace.extractedText[file.id]), connections: connections,
            subjects: workspace.subjects.filter { $0.fileIDs.contains(file.id) },
            collections: library.collections.filter { file.collectionIDs.contains($0.id) && ($0.organizationKey == nil || $0.organizationKey?.hasPrefix("photo-") == true || $0.organizationKey?.hasPrefix("tag:") == true) }, tags: file.tags)
    }
}
@MainActor
final class DocumentExplorerModel: ObservableObject {
    @Published private(set) var snapshot: ExplorerSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var applied: ExplorerRequest?
    private var token = UUID()
    func load(_ request: ExplorerRequest, library: Library, workspace: Workspace, engine: KnowledgeGraphEngine) async {
        guard applied != request else { return }
        let current = UUID(); token = current; loading = true; error = nil
        defer { if token == current { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(120))
            let next = try await engine.explorer(request, library: library, workspace: workspace)
            try Task.checkCancellation(); guard token == current else { return }
            snapshot = next; applied = request
        } catch is CancellationError {} catch {
            guard token == current else { return }
            self.error = "Document context is unavailable. Reconnect its source or choose another indexed item."
        }
    }
}
