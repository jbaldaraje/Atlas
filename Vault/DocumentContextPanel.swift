import SwiftUI
import VaultCore

struct DocumentContextPanel: View {
    @EnvironmentObject private var runtime: RuntimeController
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var preferences: WorkspacePreferencesStore
    @Environment(\.workspaceRouting) private var routing
    @AppStorage("fileKindFilter") private var kind = FileKindFilter.all
    @StateObject private var model = DocumentExplorerModel()
    let file: FileItem
    let select: (UUID) -> Void
    var navigate: ((ExplorationHop) -> Void)?
    var find: ((String) -> Void)?
    @State private var page = 0
    @State private var compareText = false
    @State private var details = false
    @State private var removingLink: UUID?
    private var request: ExplorerRequest {
        ExplorerRequest(revision: GraphRevision(library: library.graphRevision, workspace: workspace.graphRevision), textRevision: workspace.browserRevision,
            id: file.id, kind: kind, page: page, compareText: compareText, dismissed: preferences.data.dismissedTextConnections)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let snapshot = model.snapshot, model.applied?.id == file.id {
                glance(snapshot.glance)
                topics(snapshot)
                Divider()
                HStack {
                    Text("Connected Documents").font(.headline)
                    Spacer()
                    if model.loading { ProgressView().controlSize(.mini) }
                }
                Toggle("Compare existing indexed text", isOn: $compareText).font(.caption)
                if compareText { Text("Suggestions require at least three shared terms in the first 12,000 indexed characters. This does not extract new content.").font(.caption2).foregroundStyle(.secondary) }
                if snapshot.connections.documents.isEmpty {
                    Text("No matching connections yet. Add a subject, tag, collection, or explicit map link; All Types shows connections across formats.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.connections.documents) { document in connectedRow(document) }
                HStack {
                    Button("Previous") { page = max(0, snapshot.connections.page - 1) }.disabled(snapshot.connections.page == 0 || model.loading)
                    Text("\(snapshot.connections.total) connected · \(snapshot.connections.page + 1)/\(snapshot.connections.pageCount)").font(.caption2)
                    Button("Next") { page = snapshot.connections.page + 1 }.disabled(snapshot.connections.page + 1 >= snapshot.connections.pageCount || model.loading)
                }.controlSize(.mini)
            } else if model.loading { ProgressView("Reading library context…").font(.caption) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(VaultStyle.amber) }
            if let error = workspace.error { Text(error).font(.caption).foregroundStyle(VaultStyle.amber) }
        }
        .task(id: runtime.windowVisible ? request : nil) { if runtime.windowVisible { await model.load(request, library: library.library, workspace: workspace.data, engine: library.knowledgeGraph) } }
        .onChange(of: file.id) { _, _ in page = 0; details = false }
        .onChange(of: kind) { _, _ in page = 0 }
        .onChange(of: compareText) { _, _ in page = 0 }
        .confirmationDialog("Remove this user connection?", isPresented: Binding(get: { removingLink != nil }, set: { if !$0 { removingLink = nil } }), titleVisibility: .visible) {
            Button("Remove Link", role: .destructive) {
                if let id = removingLink { workspace.change { $0.relationships.removeAll { $0.id == id } } }
                removingLink = nil
            }
            Button("Cancel", role: .cancel) { removingLink = nil }
        } message: { Text("Only the relationship is removed. Both files and their other memberships remain.") }
    }
    private func glance(_ glance: AtAGlance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("At a Glance", systemImage: "text.magnifyingglass").font(.headline)
                Spacer()
                if let showMap = routing.showMap { Button { showMap(file.id) } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }.help("Explore this document in the existing Knowledge Map").accessibilityLabel("Explore in Knowledge Map") }
            }
            if !glance.description.isEmpty { Text(glance.description).font(.callout).textSelection(.enabled) }
            if glance.hasText {
                Text("From your local text index · source excerpts, not an AI summary").font(.caption2).foregroundStyle(.secondary)
                ForEach(Array(glance.excerpts.enumerated()), id: \.offset) { _, excerpt in Text("“" + excerpt + "”").font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !glance.terms.isEmpty {
                    Text("Key terms · local frequency").font(.caption.weight(.medium))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading, spacing: 7) {
                        ForEach(glance.terms, id: \.self) { term in
                            if find != nil || routing.preview != nil { Button(term) { search(term) }.font(.caption).help("Find this term in the document or its indexed text") }
                            else { Text(term).font(.caption) }
                        }
                    }
                }
                DisclosureGroup("Source headings & dates", isExpanded: $details) {
                    if details {
                        ForEach(Array(glance.headings.enumerated()), id: \.offset) { _, heading in Text(heading).font(.caption).textSelection(.enabled) }
                        if !glance.dates.isEmpty { Text("Date strings in text: " + glance.dates.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        if glance.headings.isEmpty && glance.dates.isEmpty { Text("No heading-like lines or date strings were found in this indexed excerpt.").font(.caption).foregroundStyle(.secondary) }
                    }
                }.font(.caption)
            } else {
                Text("A content overview is unavailable. Available metadata is shown; supported text extraction is optional.").font(.caption).foregroundStyle(.secondary)
                Button("Extract Text / OCR Locally") { workspace.extract(file) }.disabled(workspace.working)
                Text("Extraction saves supported text as plaintext in the regular local index.").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(14).glassSurface(tint: VaultStyle.lavender)
    }
    private func topics(_ snapshot: ExplorerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(snapshot.subjects.prefix(5))) { subject in
                if let browse = routing.browseSubject { Button { browse(subject.id) } label: { Label(subject.name, systemImage: "books.vertical").font(.caption) } }
            }
            ForEach(Array(snapshot.collections.prefix(5))) { collection in
                if let browse = routing.browseCollection { Button { browse(collection.id) } label: { Label(collection.name, systemImage: "square.stack").font(.caption) } }
            }
            ForEach(Array(snapshot.tags.prefix(8)), id: \.self) { tag in
                if let search = routing.searchFiles { Button { search(tag) } label: { Label(tag, systemImage: "tag").font(.caption) } }
                else { Text(tag).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func connectedRow(_ document: ConnectedDocument) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { follow(document) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: VaultStyle.fileSymbol(document.file.type)).foregroundStyle(VaultStyle.lavender).frame(width: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(document.file.filename).font(.callout.weight(.medium)).lineLimit(2)
                        Text(document.file.type.uppercased() + " · " + (document.hasExplicitLink ? "User-linked" : "Shared metadata / suggestions")).font(.caption2).foregroundStyle(.secondary)
                        if !document.file.description.isEmpty { Text(String(document.file.description.prefix(150))).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        Text(document.evidence.prefix(2).map(\.label).joined(separator: " · ")).font(.caption).foregroundStyle(VaultStyle.teal).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            DisclosureGroup("Why connected") {
                ForEach(Array(document.evidence.prefix(6))) { evidence in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(evidence.label + (evidence.suggested ? " · Suggestion" : "")).font(.caption.weight(.medium))
                        Text(evidence.detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        if evidence.kind == .explicitLink, let id = evidence.contextID {
                            Button("Remove User Connection…", role: .destructive) { removingLink = id }.font(.caption2)
                        }
                        if evidence.kind == .sharedSubject, let id = evidence.contextID, let browse = routing.browseSubject { Button("Review subject membership") { browse(id) }.font(.caption2) }
                    }.padding(.vertical, 4)
                }
                if document.evidence.count > 6 { Text("Showing the first 6 of \(document.evidence.count) recorded reasons.").font(.caption2).foregroundStyle(.secondary) }
            }.font(.caption2)
            HStack {
                if let preview = routing.preview { Button("Preview") { preview(document.id, nil) } }
                if !document.hasExplicitLink { Button("Save Connection") { confirm(document) } }
                if document.evidence.contains(where: { $0.kind == .indexedTerms }) { Button("Dismiss Text Match") { preferences.dismissTextConnection(file.id, document.id) }.disabled(!preferences.canWrite) }
            }.controlSize(.mini)
        }.padding(12).quietPanel()
    }
    private func follow(_ document: ConnectedDocument) {
        let hop = ExplorationHop(document.id, source: file.id, reason: document.primaryReason)
        if let navigate { navigate(hop) } else if let inspect = routing.inspect { inspect(hop) } else { select(document.id) }
    }
    private func confirm(_ document: ConnectedDocument) {
        let ids = Set(library.library.files.map(\.id))
        guard ids.contains(file.id), ids.contains(document.id) else { workspace.error = "A file left the catalog. Refresh document context before saving a connection."; return }
        workspace.change { $0.link(file.id, document.id, label: document.evidence.contains { $0.kind == .indexedTerms } ? "Reviewed indexed-text match" : "Related · reviewed") }
    }
    private func search(_ term: String) { if let find { find(term) } else { routing.preview?(file.id, term) } }
}
