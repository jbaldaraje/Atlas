import SwiftUI
import VaultCore

private struct TrailTitleRequest: Equatable { let revision: GraphRevision; let ids: [UUID] }
extension KnowledgeGraphEngine {
    func titles(ids: [UUID], revision: GraphRevision, library: Library, workspace: Workspace) throws -> [UUID: String] {
        try ensureIndex(revision: revision, library: library, subjects: workspace.subjects, relationships: workspace.relationships)
        return graphIndex?.titles(for: ids) ?? [:]
    }
}
struct ExplorationTrailView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var navigator: ExplorationNavigator
    @Environment(\.workspaceRouting) private var routing
    var documentsOnly = false
    @State private var titles: [UUID: String] = [:]
    private var request: TrailTitleRequest { TrailTitleRequest(revision: GraphRevision(library: library.graphRevision, workspace: workspace.graphRevision), ids: navigator.history.steps.map(\.itemID)) }
    var body: some View {
        if !navigator.history.steps.isEmpty {
            HStack(spacing: 10) {
                Button { restore(navigator.history.previousIndex(kind: documentsOnly ? .file : nil)) } label: { Image(systemName: "chevron.left") }
                    .disabled(navigator.history.previousIndex(kind: documentsOnly ? .file : nil) == nil).help("Back to previous document or topic").accessibilityLabel("Back to previous document")
                Button { restore(navigator.history.nextIndex(kind: documentsOnly ? .file : nil)) } label: { Image(systemName: "chevron.right") }
                    .disabled(navigator.history.nextIndex(kind: documentsOnly ? .file : nil) == nil).help("Forward in exploration").accessibilityLabel("Forward in exploration")
                Menu {
                    ForEach(Array(navigator.history.steps.enumerated()), id: \.element.id) { index, step in
                        Button { restore(index) } label: { Label(titles[step.itemID] ?? "Unavailable item", systemImage: index == navigator.history.cursor ? "location.fill" : "arrow.turn.down.right") }
                            .disabled(documentsOnly && step.kind != .file)
                    }
                } label: {
                    Text(navigator.history.steps.prefix(max(0, min(navigator.history.cursor + 1, navigator.history.steps.count))).suffix(3).map { titles[$0.itemID] ?? "Item" }.joined(separator: " → ")).lineLimit(1).truncationMode(.middle)
                }.menuStyle(.borderlessButton)
                Spacer(minLength: 0)
            }.font(.caption).controlSize(.small)
                .task(id: request) {
                    do {
                        let next = try await library.knowledgeGraph.titles(ids: request.ids, revision: request.revision, library: library.library, workspace: workspace.data)
                        try Task.checkCancellation(); titles = next
                    } catch {}
                }
        }
    }
    private func restore(_ index: Int?) { if let index { routing.restore?(index) } }
}
