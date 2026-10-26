import SwiftUI
import VaultCore

struct ContextInspector: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    let id: UUID?
    let select: (UUID) -> Void
    let remove: (FileItem) -> Void
    @State private var removingRelationship = false
    var body: some View {
        Group {
            if let file = store.library.files.first(where: { $0.id == id }) {
                FileInspector(file: file, remove: { remove(file) }, select: select).id(file.id)
            } else if let subject = workspace.data.subjects.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        identity(subject.name, kind: "SUBJECT", symbol: "sparkle", color: VaultStyle.teal)
                        Text(subject.description.isEmpty ? "No description yet. Edit this subject in the Subjects workspace." : subject.description).font(.callout).foregroundStyle(.secondary)
                        if let date = subject.deadline { Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar").font(.caption) }
                        Divider(); Text("Linked files").font(.headline)
                        fileLinks(subject.fileIDs)
                        Divider(); Text("Recorded study").font(.headline)
                        let sessions = workspace.data.sessions.filter { $0.subjectID == subject.id }
                        Text("\(sessions.count) sessions · \(sessions.reduce(0) { $0 + $1.minutes }) minutes").font(.caption).foregroundStyle(.secondary)
                    }.padding(22)
                }
            } else if let collection = store.library.collections.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        identity(collection.name, kind: "COLLECTION", symbol: "square.stack", color: VaultStyle.amber)
                        Text("A virtual collection. Membership does not change where files live.").font(.caption).foregroundStyle(.secondary)
                        Divider(); fileLinks(Set(store.library.files.filter { $0.collectionIDs.contains(collection.id) }.map(\.id)))
                    }.padding(22)
                }
            } else if let edge = workspace.data.relationships.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 20) {
                    identity(edge.label, kind: "RELATIONSHIP", symbol: "link", color: VaultStyle.lavender)
                    fileLinks([edge.source, edge.target])
                    Text("This link belongs to Vault and does not modify either file.").font(.caption).foregroundStyle(.secondary)
                    Button("Remove Relationship…", role: .destructive) { removingRelationship = true }
                    Spacer()
                }.padding(22)
            } else {
                ContentUnavailableView("Room for context", systemImage: "sidebar.right", description: Text("Select a file, subject, or collection to inspect it."))
            }
        }.background { ObservatoryBackground(grid: false) }
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
    private func fileLinks(_ ids: Set<UUID>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if ids.isEmpty { Text("No linked files yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(store.library.files.filter { ids.contains($0.id) }) { file in
                Button { select(file.id) } label: { Label(file.filename, systemImage: "doc.text").font(.callout).lineLimit(2) }.buttonStyle(.plain)
            }
        }
    }
}
