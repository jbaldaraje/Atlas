import SwiftUI
import AppKit
import VaultCore

struct FolderBrowser: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @StateObject private var model = FolderBrowserModel()
    let section: CatalogSection
    var query = ""
    var favorites = false
    var type = ""
    var minimumBytes: Int64 = 0
    var recent = false
    var old = false
    var sort = "Added"
    var listMode = false
    var initialLocation = CatalogLocation()
    var source: CatalogSource?
    var linkingSubjectID: UUID?
    var linkingFileID: UUID?
    var selectedIDs: Set<UUID> = []
    let select: (UUID) -> Void
    var remove: ((FileItem) -> Void)?
    var cleanup: ((FileItem) -> Void)?
    var openSubject: ((UUID) -> Void)?
    var openCollection: ((UUID) -> Void)?
    @State private var path: [CatalogGroup] = []
    @State private var pageNumber = 0

    private var location: CatalogLocation { path.last?.location ?? initialLocation }
    private var request: CatalogRequest {
        var query = CatalogQuery(); query.section = section; query.location = location
        query.text = self.query; query.favorites = favorites; query.type = type; query.minimumBytes = minimumBytes
        query.recent = recent; query.old = old; query.sort = sort; query.page = pageNumber
        query.linkingFileID = linkingFileID
        return CatalogRequest(dataset: source?.id ?? "library", revision: CatalogRevision(library: source?.revision ?? store.graphRevision, workspace: source?.revision ?? workspace.browserRevision), query: query)
    }
    // Never display the previous folder's children while a different navigation request loads.
    private var current: Bool {
        guard let applied = model.applied else { return false }
        return applied.dataset == request.dataset && applied.query == request.query
    }
    private var linkedIDs: Set<UUID> {
        guard let linkingSubjectID else { return [] }
        return workspace.data.subjects.first { $0.id == linkingSubjectID }?.fileIDs ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            breadcrumbs
            if let error = model.error { Text(error).font(.caption).foregroundStyle(VaultStyle.amber) }
            if !current {
                VStack(spacing: 10) { ProgressView(); Text("Preparing this level…").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.page.itemCount == 0 {
                ContentUnavailableView("No items at this level", systemImage: "folder", description: Text("Choose another folder or change your filters. Only indexed files are shown."))
            } else { contents }
            footer
        }
        .task(id: request) { await load() }
        .onChange(of: query) { _, _ in pageNumber = 0 }
        .onChange(of: favorites) { _, _ in pageNumber = 0 }
        .onChange(of: type) { _, _ in pageNumber = 0 }
        .onChange(of: minimumBytes) { _, _ in pageNumber = 0 }
        .onChange(of: recent) { _, _ in pageNumber = 0 }
        .onChange(of: old) { _, _ in pageNumber = 0 }
        .onChange(of: sort) { _, _ in pageNumber = 0 }
        .onChange(of: initialLocation) { _, _ in path = []; pageNumber = 0 }
    }
    private var breadcrumbs: some View {
        HStack(spacing: 10) {
            Button { if !path.isEmpty { path.removeLast(); pageNumber = 0 } } label: { Image(systemName: "chevron.left") }
                .disabled(path.isEmpty).help("Back one level").accessibilityLabel("Back one level")
            Button("Parents") { path = []; pageNumber = 0 }.disabled(path.isEmpty)
            Text(path.last?.title ?? "Parent folders / groups").font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.loading { ProgressView().controlSize(.mini) }
        }.controlSize(.small)
    }
    private var contents: some View {
        ScrollView {
            let links = linkedIDs
            LazyVGrid(columns: listMode ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 195), spacing: 12)], spacing: 12) {
                ForEach(model.page.groups) { group in groupButton(group) }
                ForEach(model.page.files) { file in fileItem(file, linkedIDs: links) }
                ForEach(model.page.sessions) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(row.subject, systemImage: "books.vertical").font(.headline)
                        Text("\(row.session.minutes) minutes · " + row.session.date.formatted()).font(.caption).foregroundStyle(.secondary)
                        Text(row.session.note).font(.callout)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).quietPanel()
                }
            }.padding(2)
        }
    }
    @ViewBuilder private func groupButton(_ group: CatalogGroup) -> some View {
        if let fileID = linkingFileID {
            Toggle(group.title, isOn: Binding(get: { group.linked }, set: { included in
                if let subjectID = group.location.subjectID {
                    workspace.change { data in
                        guard let index = data.subjects.firstIndex(where: { $0.id == subjectID }) else { return }
                        if included { data.subjects[index].fileIDs.insert(fileID) } else { data.subjects[index].fileIDs.remove(fileID) }
                    }
                } else if let collectionID = group.location.collectionID, var file = store.library.files.first(where: { $0.id == fileID }) {
                    if included { file.collectionIDs.insert(collectionID) } else { file.collectionIDs.remove(collectionID) }
                    store.update(file)
                }
            })).toggleStyle(.checkbox).padding(14).frame(maxWidth: .infinity, alignment: .leading).quietPanel()
        } else {
        Button {
            if section == .subjects, location.subjectID == nil, let id = group.location.subjectID, let openSubject { openSubject(id) }
            else if section == .collections, location.collectionID == nil, let id = group.location.collectionID, let openCollection { openCollection(id) }
            else { path.append(group); pageNumber = 0 }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: group.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(VaultStyle.teal).frame(width: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(group.count.formatted()) items").font(.caption).foregroundStyle(.secondary)
                    Text(group.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassSurface(tint: VaultStyle.teal)
        }.buttonStyle(.plain).help(group.subtitle).accessibilityHint("Open to load immediate children")
        }
    }
    @ViewBuilder private func fileItem(_ file: FileItem, linkedIDs: Set<UUID>) -> some View {
        if let subjectID = linkingSubjectID {
            Toggle(isOn: Binding(get: { linkedIDs.contains(file.id) }, set: { included in
                workspace.change { data in
                    guard let index = data.subjects.firstIndex(where: { $0.id == subjectID }) else { return }
                    if included { data.subjects[index].fileIDs.insert(file.id) } else { data.subjects[index].fileIDs.remove(file.id) }
                }
            })) {
                Label(file.filename, systemImage: VaultStyle.fileSymbol(file.type)).lineLimit(2)
            }.toggleStyle(.checkbox).padding(14).frame(maxWidth: .infinity, alignment: .leading).quietPanel()
        } else {
            Button { select(file.id) } label: { card(file) }.buttonStyle(.plain).contextMenu { fileMenu(file) }
        }
    }
    private func card(_ file: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !listMode { FileThumbnail(file: file).frame(height: 110).frame(maxWidth: .infinity).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)) }
            HStack {
                Image(systemName: VaultStyle.fileSymbol(file.type)).foregroundStyle(VaultStyle.lavender)
                Text(file.noteSource?.title ?? file.filename).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
                if file.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(VaultStyle.amber) }
            }
            Text(file.type.uppercased() + " · " + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
            if section == .timeline {
                Text(location.event == .modified ? (file.modifiedAt?.formatted() ?? "Unavailable") : file.indexedAt.formatted()).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).quietPanel()
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selectedIDs.contains(file.id) ? VaultStyle.lavender : .clear, lineWidth: 2))
    }
    @ViewBuilder private func fileMenu(_ file: FileItem) -> some View {
        Button("Open in Default App") { store.open(file) }
        Button("Reveal in Finder") { store.reveal(file) }
        if source == nil {
            Button(file.favorite ? "Remove Favorite" : "Favorite") {
                if var changed = store.library.files.first(where: { $0.id == file.id }) { changed.favorite.toggle(); store.update(changed) }
            }
        }
        if let remove { Divider(); Button("Remove from Index…", role: .destructive) { remove(file) } }
        if let cleanup {
            Divider()
            Button(file.ownership == .managedCopy ? "Review Managed Copy Removal…" : "Review Original Trash…") { cleanup(file) }.disabled(workspace.working)
        }
    }
    private var footer: some View {
        HStack {
            Text(current ? "\(model.page.itemCount.formatted()) immediate items · children load when opened" : "Loading selected level…")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button { pageNumber = max(0, model.page.page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(!current || model.page.page == 0).accessibilityLabel("Previous page")
            Text("\(model.page.page + 1) / \(model.page.pageCount)").font(.caption2.monospacedDigit())
            Button { pageNumber = model.page.page + 1 } label: { Image(systemName: "chevron.right") }
                .disabled(!current || model.page.page + 1 >= model.page.pageCount).accessibilityLabel("Next page")
        }.controlSize(.mini)
    }
    private func load() async {
        let snapshot: CatalogSnapshot
        if let source {
            var library = Library(); library.files = source.files
            snapshot = CatalogSnapshot(library: library, subjects: [], sessions: [], sourcePaths: [], text: [:])
        } else {
            let paths = workspace.data.locations.compactMap(\.sourcePath) + (workspace.data.lastScan?.sources.compactMap(\.sourcePath) ?? [])
            snapshot = CatalogSnapshot(library: store.library, subjects: workspace.data.subjects, sessions: workspace.data.sessions, sourcePaths: paths, text: workspace.data.extractedText)
        }
        await model.load(request, snapshot: snapshot, engine: store.catalogBrowser)
    }
}
