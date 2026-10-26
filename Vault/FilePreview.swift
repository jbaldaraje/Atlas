import SwiftUI
import Quartz
import VaultCore

private struct PreviewLookupRequest: Equatable { let id: UUID; let revision: GraphRevision }

/// The existing preview, extended with connected reading; every file keeps its original bookmark.
struct FilePreview: View {
    @EnvironmentObject private var runtime: RuntimeController
    let file: FileItem
    var initialSearchTerm = ""
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var navigator: ExplorationNavigator
    @Environment(\.workspaceRouting) private var routing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    @StateObject private var graph = KnowledgeMapModel()
    @State private var currentID: UUID?
    @State private var focused: FileItem?
    @State private var verifiedID: UUID?
    @State private var resource: PreviewResource?
    private var url: URL? { resource?.url }
    @State private var error: String?
    @State private var search = ""
    @State private var submittedSearch = ""
    @State private var readingMode = 0
    @State private var mapVisible = false
    private var lookup: PreviewLookupRequest { PreviewLookupRequest(id: currentID ?? file.id, revision: GraphRevision(library: library.graphRevision, workspace: workspace.graphRevision)) }
    private var current: FileItem? {
        let id = currentID ?? file.id
        if verifiedID == id { return focused }
        return file.id == id ? file : nil
    }
    private var supportsPDFSearch: Bool { current?.type.lowercased() == "pdf" && (current?.size ?? .max) <= 50 * 1024 * 1024 }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(current?.filename ?? (verifiedID == lookup.id ? "Unavailable document" : "Loading document…")).font(.headline).lineLimit(1)
                        .id(current?.id).transition(.opacity)
                        .animation(reducedMotion || !cinematicMotion ? nil : .easeOut(duration: 0.18), value: current?.id)
                    ExplorationTrailView(documentsOnly: true)
                }
                Spacer()
                if let current { Button("Open in Default App") { library.open(current) } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let current {
                HSplitView {
                    VStack(spacing: 10) {
                        HStack {
                            TextField(supportsPDFSearch ? "Find in PDF…" : "Find in indexed text…", text: $search).onSubmit { find(search) }
                            Button("Find") { find(search) }.disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Picker("Read", selection: $readingMode) { Text("Preview").tag(0); Text("Indexed text").tag(1) }.labelsHidden().frame(width: 125)
                        }.padding(.horizontal, 14).padding(.top, 12)
                        reader(current).id(current.id).transition(.opacity)
                            .animation(reducedMotion || !cinematicMotion ? nil : .easeOut(duration: 0.18), value: current.id)
                        Toggle("Show map context", isOn: $mapVisible).font(.caption).padding(.horizontal, 14)
                        if mapVisible {
                            KnowledgeMap(model: graph, selectedID: graphSelection, select: chooseMapItem, compact: true).frame(height: 285)
                        }
                    }.frame(minWidth: 440, maxWidth: .infinity)
                    ScrollView {
                        DocumentContextPanel(file: current, select: { navigate(ExplorationHop($0, source: current.id)) }, navigate: navigate, find: find).id(current.id).padding(18)
                    }.frame(minWidth: 290, idealWidth: 330, maxWidth: 420)
                }
            } else if verifiedID != lookup.id { ProgressView("Preparing document…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView("Document left the catalog", systemImage: "doc.questionmark", description: Text("Use the exploration trail to return to another document.")) }
        }.frame(minWidth: 840, idealWidth: 1100, minHeight: 520, idealHeight: 760)
            .background { ObservatoryBackground(grid: false) }
            .task(id: runtime.windowVisible ? lookup : nil) {
                guard runtime.windowVisible else { releaseScope(); return }
                let request = lookup
                do {
                    let item = try await library.knowledgeGraph.file(id: request.id, revision: request.revision, library: library.library, workspace: workspace.data)
                    try Task.checkCancellation(); focused = item; verifiedID = request.id; await openCurrent()
                } catch is CancellationError {} catch { self.error = "The indexed document could not be resolved." }
            }
            .onAppear { search = initialSearchTerm; routing.inspect?(ExplorationHop(file.id)); if !initialSearchTerm.isEmpty { find(initialSearchTerm) } }
            .onChange(of: file.id) { _, id in if currentID != id { releaseScope(); currentID = id; search = initialSearchTerm; submittedSearch = initialSearchTerm; readingMode = 0 } }
            .onChange(of: initialSearchTerm) { _, term in search = term; submittedSearch = term; if !term.isEmpty { find(term) } }
            .onChange(of: navigator.history.cursor) { _, _ in
                if let step = navigator.history.current, step.kind == .file, step.itemID != current?.id { releaseScope(); currentID = step.itemID; search = ""; submittedSearch = ""; readingMode = 0 }
            }
            .onDisappear { releaseScope() }
    }
    private var graphSelection: Binding<UUID?> { Binding(get: { current?.id }, set: { _ in }) }
    @ViewBuilder private func reader(_ file: FileItem) -> some View {
        if !runtime.windowVisible { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if readingMode == 1 {
            IndexedTextFinder(text: workspace.data.extractedText[file.id], term: submittedSearch)
        } else if let url {
            if supportsPDFSearch { SearchablePDFPreview(url: url, term: submittedSearch) }
            else { NativePreview(url: url) }
        } else if let error { ContentUnavailableView("Preview unavailable", systemImage: "doc.questionmark", description: Text(error)) }
        else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private func navigate(_ hop: ExplorationHop) {
        releaseScope(); currentID = hop.target; search = ""; submittedSearch = ""; readingMode = 0; routing.inspect?(hop)
    }
    private func chooseMapItem(_ id: UUID) {
        if library.library.files.contains(where: { $0.id == id }) { navigate(ExplorationHop(id, source: current?.id)) }
        else { routing.showMap?(id) }
    }
    private func find(_ term: String) { search = term; submittedSearch = term; readingMode = supportsPDFSearch ? 0 : 1 }
    private func openCurrent() async {
        releaseScope(); error = nil
        guard let current else { return }
        do {
            let next = try await PreviewResource.resolve(current)
            try Task.checkCancellation(); resource = next
        } catch is CancellationError {} catch { self.error = error.localizedDescription; releaseScope() }
    }
    private func releaseScope() { resource = nil }

}
private struct IndexedTextFinder: View {
    let text: String?
    let term: String
    private var excerpt: String? {
        guard let text, !text.isEmpty else { return nil }
        guard !term.isEmpty, let range = text.range(of: term, options: .caseInsensitive) else { return String(text.prefix(4000)) }
        let start = text.index(range.lowerBound, offsetBy: -300, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 900, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
    var body: some View {
        if let excerpt {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Existing local text index").font(.caption).foregroundStyle(.secondary)
                    if !term.isEmpty && text?.range(of: term, options: .caseInsensitive) == nil { Text("No match for “\(term)” in the indexed text.").font(.caption) }
                    Text(highlight(excerpt)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Showing an indexed excerpt. It may be partial or older than the original file; extraction refresh is explicit.").font(.caption).foregroundStyle(.secondary)
                }.padding(18)
            }
        } else { ContentUnavailableView("No indexed text", systemImage: "text.magnifyingglass", description: Text("Use the existing Extract Text / OCR action for supported files, or read the native preview.")) }
    }
    private func highlight(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        if !term.isEmpty, let range = result.range(of: term, options: .caseInsensitive) { result[range].backgroundColor = Color.yellow.opacity(0.3) }
        return result
    }
}
private struct NativePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return NSTextField(labelWithString: "Native preview is unavailable. Open the file in its default app.") }
        preview.previewItem = url as NSURL; return preview
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? QLPreviewView)?.previewItem = url as NSURL }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) { (nsView as? QLPreviewView)?.previewItem = nil }
}
