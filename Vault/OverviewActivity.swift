import SwiftUI
import VaultCore

private struct ActivityRow: Identifiable, Sendable {
    var id: UUID { file.id }
    let file: FileItem
    let date: Date
}
struct OverviewActivity: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let select: (UUID) -> Void
    @State private var group: String?
    @State private var rows: [ActivityRow] = []
    @State private var page = 0
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Recent activity").font(.title2); Spacer(); Button("Done") { dismiss() } }
            if let group {
                Button("Activity Groups") { self.group = nil; rows = [] }
                Text(group).font(.headline)
                if loading { ProgressView() }
                List(Array(rows.dropFirst(page * 60).prefix(60))) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.file.filename).lineLimit(1)
                            Text(row.date.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { store.open(row.file) }
                        Button("Inspect") { select(row.id); dismiss() }
                    }
                }
                HStack {
                    Button("Previous") { page -= 1 }.disabled(page == 0 || loading)
                    Text("Page \(page + 1)").font(.caption)
                    Button("Next") { page += 1 }.disabled((page + 1) * 60 >= rows.count || loading)
                }
            } else {
                Button { group = "Recently opened" } label: { Label("Recently opened", systemImage: "folder").padding(18).frame(maxWidth: .infinity, alignment: .leading) }
                Button { group = "Recently added" } label: { Label("Recently added", systemImage: "folder").padding(18).frame(maxWidth: .infinity, alignment: .leading) }
                Spacer()
            }
        }.padding(24).frame(width: 730, height: 540).task(id: group) { await load() }
    }
    private func load() async {
        guard let group else { return }
        loading = true; rows = []; page = 0; defer { loading = false }
        let files = store.library.files, opened = workspace.data.openedFiles ?? [:]
        let worker = Task.detached(priority: .userInitiated) { () throws -> [ActivityRow] in
            var rows: [ActivityRow] = []
            for file in files {
                try Task.checkCancellation()
                if group == "Recently opened" {
                    if let date = opened[file.id] { rows.append(ActivityRow(file: file, date: date)) }
                } else { rows.append(ActivityRow(file: file, date: file.indexedAt)) }
            }
            return rows.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
        }
        do {
            let next = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation(); rows = next
        } catch {}
    }
}
