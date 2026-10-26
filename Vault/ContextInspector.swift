import SwiftUI
import VaultCore

struct ContextInspector: View {
    @EnvironmentObject private var runtime: RuntimeController
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    let id: UUID?
    let select: (UUID) -> Void
    let remove: (FileItem) -> Void
    let browseSubject: (UUID) -> Void
    let browseCollection: (UUID) -> Void
    @State private var removingRelationship = false
    @State private var context: SelectionContext?
    @State private var loading = false
    private var request: SelectionRequest { SelectionRequest(id: id, revision: GraphRevision(library: store.graphRevision, workspace: workspace.graphRevision), metadata: workspace.browserRevision) }
    var body: some View {
        Group {
            if id == nil {
                ContentUnavailableView("Room for context", systemImage: "sidebar.right", description: Text("Select a file, subject, or collection to inspect it."))
            } else if context?.id != id || loading && context == nil {
                ProgressView("Preparing context…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let file = context?.file {
                FileInspector(file: file, remove: { remove(file) }, select: select).id(file.id)
            } else if let subject = context?.subject {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        identity(subject.name, kind: "SUBJECT", symbol: "sparkle", color: VaultStyle.teal)
                        Text(subject.description.isEmpty ? "No description yet. Edit this subject in the Subjects workspace." : subject.description).font(.callout).foregroundStyle(.secondary)
                        if let date = subject.deadline { Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar").font(.caption) }
                        Divider(); Text("Linked files").font(.headline)
                        Text("\(subject.fileIDs.count.formatted()) total linked files").font(.caption).foregroundStyle(.secondary)
                        Button("Browse linked folders") { browseSubject(subject.id) }
                        Divider(); Text("Recorded study").font(.headline)
                        Text("\(context?.sessionCount ?? 0) sessions · \(context?.studyMinutes ?? 0) minutes").font(.caption).foregroundStyle(.secondary)
                    }.padding(22)
                }
            } else if let collection = context?.collection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        identity(collection.name, kind: "COLLECTION", symbol: "square.stack", color: VaultStyle.amber)
                        Text("A virtual collection. Membership does not change where files live.").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Button("Browse collection folders") { browseCollection(collection.id) }
                    }.padding(22)
                }
            } else if let edge = context?.relationship {
                VStack(alignment: .leading, spacing: 20) {
                    identity(edge.label, kind: "RELATIONSHIP", symbol: "link", color: VaultStyle.lavender)
                    ForEach(context?.endpoints ?? []) { file in Button(file.filename) { select(file.id) }.font(.callout).lineLimit(2) }
                    Text("This link belongs to Vault and does not modify either file.").font(.caption).foregroundStyle(.secondary)
                    Button("Remove Relationship…", role: .destructive) { removingRelationship = true }
                    Spacer()
                }.padding(22)
            } else {
                ContentUnavailableView("Room for context", systemImage: "sidebar.right", description: Text("Select a file, subject, or collection to inspect it."))
            }
        }.background { ObservatoryBackground(grid: false) }
        .task(id: runtime.windowVisible ? request : nil) {
                    guard runtime.windowVisible else { return }
            guard id != nil else { context = nil; return }
            loading = true; defer { loading = false }
            do {
                let next = try await store.knowledgeGraph.selection(request, library: store.library, workspace: workspace.data)
                try Task.checkCancellation(); context = next
            } catch {}
        }
        .confirmationDialog("Remove this relationship?", isPresented: $removingRelationship, titleVisibility: .visible) {
            Button("Remove Link", role: .destructive) { workspace.change { $0.relationships.removeAll { $0.id == id } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The original files and their index entries remain unchanged.") }
    }
    private func identity(_ title: String, kind: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind).font(.system(size: 9, weight: .medium)).tracking(1.4).foregroundStyle(.secondary)
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(color).padding(18).quietPanel()
            Text(title).font(.title3.weight(.medium)).textSelection(.enabled)
        }
    }
}
