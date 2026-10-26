import SwiftUI
import VaultCore

struct BulkEditor: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let ids: Set<UUID>
    @State private var tags = ""
    @State private var collection: UUID?
    @State private var favorite = false
    @State private var confirmRemoval = false
    private var files: [FileItem] { store.library.files.filter { ids.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Organize \(files.count) selected files").font(.title2)
            List(files) { file in VStack(alignment: .leading) { Text(file.filename); Text(file.originalLocation).font(.caption).foregroundStyle(.secondary) } }.frame(height: 220)
            TextField("Add tags (comma separated)", text: $tags)
            Picker("Add to collection", selection: $collection) {
                Text("Leave memberships unchanged").tag(nil as UUID?)
                ForEach(store.library.collections) { Text($0.name).tag(Optional($0.id)) }
            }
            Toggle("Mark selected files as favorites", isOn: $favorite)
            Text("Tags are added without removing existing tags. Source files are never changed.").font(.caption)
            if confirmRemoval {
                Text("Remove these \(files.count) index entries, descriptions, tags, and memberships? All original files and managed copies remain on disk. This metadata removal cannot be undone.").foregroundStyle(.red)
                Button("Confirm Index Removal", role: .destructive) { store.bulk(ids: ids, remove: true); dismiss() }
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Remove from Index…", role: .destructive) { confirmRemoval = true }
                Spacer()
                Button("Apply Metadata") {
                    store.bulk(ids: ids, tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, collection: collection, favorite: favorite)
                    dismiss()
                }
            }
        }.padding(24).frame(width: 620)
    }
}
