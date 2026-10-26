import SwiftUI
import VaultCore

private struct RelatedPage: Sendable {
    let edges: [Relationship]
    let names: [UUID: String]
    let count: Int
}
private struct RelatedRequest: Equatable { let revision: GraphRevision; let page: Int }
struct RelatedFileLinks: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    let fileID: UUID
    let select: (UUID) -> Void
    @State private var page = 0
    @State private var result: RelatedPage?
    @State private var loading = false
    private var request: RelatedRequest { RelatedRequest(revision: GraphRevision(library: store.graphRevision, workspace: workspace.graphRevision), page: page) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading { ProgressView() }
            if let result {
                if result.count == 0 { Text("Create a connection from a file’s Knowledge Map context menu.").font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(result.edges) { edge in
                            let target = edge.source == fileID ? edge.target : edge.source
                            HStack {
                                Button(result.names[target] ?? "Unavailable file") { select(target) }.lineLimit(2)
                                Spacer()
                                Button { select(edge.id) } label: { Image(systemName: "link") }.help("Inspect relationship").accessibilityLabel("Inspect relationship")
                            }
                        }
                    }
                }
                HStack {
                    Button("Previous") { page -= 1 }.disabled(page == 0 || loading)
                    Text("\(result.count) links").font(.caption)
                    Button("Next") { page += 1 }.disabled((page + 1) * 60 >= result.count || loading)
                }.controlSize(.mini)
            }
        }.task(id: request) { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        let files = store.library.files, links = workspace.data.relationships, currentPage = page, targetID = fileID
        let worker = Task.detached(priority: .userInitiated) { () throws -> RelatedPage in
            try Task.checkCancellation()
            let related = links.filter { $0.source == targetID || $0.target == targetID }
            let edges = Array(related.dropFirst(currentPage * 60).prefix(60))
            let ids = Set(edges.flatMap { [$0.source, $0.target] })
            let names = Dictionary(files.lazy.filter { ids.contains($0.id) }.map { ($0.id, $0.filename) }, uniquingKeysWith: { a, _ in a })
            try Task.checkCancellation()
            return RelatedPage(edges: edges, names: names, count: related.count)
        }
        do {
            let next = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation(); result = next
        } catch {}
    }
}
