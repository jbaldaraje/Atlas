import SwiftUI
import AppKit
import QuickLookThumbnailing
import VaultCore

private enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview", graph = "Knowledge Map", files = "All Files", notes = "Notes", subjects = "Subjects", collections = "Collections", media = "Images & Media", timeline = "Timeline", storage = "Storage & Cleanup", secure = "Secure Vault", deleted = "Recently Deleted"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .files: "doc.on.doc"
        case .notes: "note.text"
        case .subjects: "books.vertical"
        case .collections: "folder"
        case .media: "photo.on.rectangle"
        case .timeline: "clock"
        case .storage: "internaldrive"
        case .secure: "lock.shield"
        case .deleted: "trash"
        }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var trash: NativeTrashService
    @EnvironmentObject private var notes: AppleNotesStore
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    @State private var showingNotesImport = false
    @State private var section: Section? = .overview
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showInspector = false
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var selectedIDs = Set<UUID>()
    @State private var bulkEditor = false
    @State private var filters = false
    @State private var typeFilter = ""
    @State private var minimumSizeMB = 0.0
    @State private var recentOnly = false
    @State private var collectionID: UUID?
    @State private var favoritesOnly = false
    @State private var listMode = false
    @State private var sort = "Added"
    @State private var collectionName = ""
    @State private var newCollection = false
    @State private var removing: FileItem?
    private let accent = VaultStyle.lavender
    private var results: [FileItem] {
        var files = store.library.search("", collectionID: collectionID, favoritesOnly: favoritesOnly)
        if !query.isEmpty {
            let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            files = files.filter { file in words.allSatisfy { word in
                ([file.filename, file.description, workspace.data.extractedText[file.id] ?? ""] + file.tags).contains { $0.localizedCaseInsensitiveContains(word) }
            } }
        }
        if section == .media { files = files.filter { ["jpg", "jpeg", "png", "heic", "gif", "mov", "mp4", "webp", "tiff"].contains($0.type.lowercased()) } }
        files = files.filter { file in
            (typeFilter.isEmpty || file.type.localizedCaseInsensitiveContains(typeFilter)) && file.size >= Int64(minimumSizeMB * 1_000_000) && (!recentOnly || file.indexedAt >= Date().addingTimeInterval(-30 * 86400))
        }
        return files.sorted {
            switch sort {
            case "Name": return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            case "Type": return $0.type == $1.type ? $0.filename.localizedStandardCompare($1.filename) == .orderedAscending : $0.type < $1.type
            case "Size": return $0.size > $1.size
            case "Modified": return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            default: return $0.indexedAt > $1.indexedAt
            }
        }
    }
    // Keep independently type-checked boundaries between layout, events, and presentation.
    var body: some View { removalPresentation }

    private var navigationLayout: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            workspaceDetail
        }
    }

    private var workspaceDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.45)
            selectedWorkspace
        }
        .background { ObservatoryBackground(grid: false) }
        .navigationTitle("Vault — \(currentSection.rawValue)")
        .animation(reducedMotion || !cinematicMotion ? nil : .easeOut(duration: 0.22), value: section)
    }

    private var currentSection: Section { section ?? .overview }

    @ViewBuilder
    private var selectedWorkspace: some View {
        switch currentSection {
        case .overview:
            OverviewWorkspace(select: inspect, openMap: openMap, openCollection: openCollection, addNotes: { showingNotesImport = true })
        case .notes:
            NotesWorkspace(query: query, select: inspect, addNotes: { showingNotesImport = true })
        case .graph:
            KnowledgeMap(selectedID: $selectedID, select: inspect)
        case .files, .media, .collections:
            libraryContent
        default:
            FeatureWorkspace(section: currentSection.rawValue, select: inspect)
                .padding(.top, 18)
        }
    }

    private var inspectedWorkspace: some View {
        navigationLayout
            .inspector(isPresented: $showInspector) { contextInspector }
            .tint(accent)
            .searchable(text: $query, prompt: "Search names, descriptions, and tags")
            .toolbar { workspaceToolbar }
    }

    private var contextInspector: some View {
        ContextInspector(id: selectedID, select: inspect, remove: requestRemoval)
            .inspectorColumnWidth(min: 270, ideal: 310, max: 380)
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { navigationMenu }
        ToolbarItem {
            Button(action: store.chooseFiles) { Label("Add Files", systemImage: "plus") }
                .disabled(store.busy || store.loadFailed || workspace.working || notes.working)
        }
        ToolbarItem {
            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Toggle inspector")
        }
    }

    private var navigationMenu: some View {
        Menu {
            ForEach(Section.allCases) { item in
                Button { section = item } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                }
            }
        } label: { Image(systemName: "square.stack.3d.up") }
        .help("Navigate workspace")
        .accessibilityLabel("Navigate workspace")
    }

    private var observedWorkspace: some View {
        inspectedWorkspace
            .task { workspace.startMonitoring(library: store) }
            .onChange(of: store.openedEvent) { _, event in recordOpenedFile(event) }
            .onChange(of: store.library.files) { old, files in reconcileFiles(old: old, files: files) }
            .onChange(of: section) { _, next in changeSection(next) }
            .dropDestination(for: URL.self) { urls, _ in acceptDroppedFiles(urls) }
    }

    private var errorPresentations: some View {
        observedWorkspace
            .alert("Workspace", isPresented: hasWorkspaceError) {
                Button("OK") { workspace.error = nil }
            } message: { Text(workspace.error ?? "") }
            .alert("Filesystem Operation", isPresented: hasFilesystemError) {
                Button("OK") { trash.error = nil }
            } message: { Text(trash.error ?? "") }
            .alert("Vault", isPresented: hasLibraryMessage) {
                Button("OK") { store.message = nil }
            } message: { Text(store.message ?? "") }
    }

    private var sheetPresentations: some View {
        errorPresentations
            .sheet(isPresented: $bulkEditor) { BulkEditor(ids: selectedIDs) }
            .sheet(isPresented: $store.presentingImport) { ImportReview() }
    }

    private var notesPresentation: some View {
        sheetPresentations.sheet(isPresented: $showingNotesImport) {
            AppleNotesImportSheet(exportedFiles: importExportedNotes)
        }
    }
    private func importExportedNotes() {
        // Wait for the connector sheet to close before presenting the existing file importer.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            store.chooseExportedNotes()
        }
    }
    private var scanPresentation: some View {
        notesPresentation.sheet(isPresented: $workspace.reviewFolder, onDismiss: workspace.cancelFolderReview) {
            FolderScanReview(select: inspect, openMap: openMap)
        }
    }

    private var collectionPresentation: some View {
        scanPresentation.alert("New collection", isPresented: $newCollection) {
            TextField("Collection name", text: $collectionName)
            Button("Create", action: createCollection)
            Button("Cancel", role: .cancel) { collectionName = "" }
        }
    }

    private var removalPresentation: some View {
        collectionPresentation.confirmationDialog(
            "Remove from Vault’s index?",
            isPresented: isRemoving,
            titleVisibility: .visible
        ) {
            Button("Remove index entry", role: .destructive, action: removeIndexEntry)
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text(removalMessage) }
    }

    private var hasWorkspaceError: Binding<Bool> {
        Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })
    }
    private var hasFilesystemError: Binding<Bool> {
        Binding(get: { trash.error != nil }, set: { if !$0 { trash.error = nil } })
    }
    private var hasLibraryMessage: Binding<Bool> {
        Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })
    }
    private var isRemoving: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
    private var removalMessage: String {
        let filename: String = removing?.filename ?? ""
        let location: String = removing?.originalLocation ?? ""
        return "\(filename)\n\(location)\nThe file stays on disk. Vault descriptions, tags, and collection memberships are removed. Managed copies also remain on disk."
    }

    private func openMap() { section = .graph }
    private func openCollection(_ id: UUID) { collectionID = id; section = .collections }
    private func requestRemoval(_ file: FileItem) { removing = file }
    private func createCollection() { store.addCollection(collectionName); collectionName = "" }
    private func removeIndexEntry() {
        if let file = removing { store.removeFromIndex(file.id); selectedID = nil }
        removing = nil
    }
    private func recordOpenedFile(_ event: OpenedFileEvent?) {
        guard let event else { return }
        workspace.change { data in
            var opened: [UUID: Date] = data.openedFiles ?? [:]
            opened[event.id] = event.date
            data.openedFiles = opened
        }
    }
    private func reconcileFiles(old: [FileItem], files: [FileItem]) {
        let validIDs = Set<UUID>(files.map(\.id))
        let collectionIDs = Set<UUID>(store.library.collections.map(\.id))
        let oldByID: [UUID: FileItem] = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        workspace.change { data in
            data.reconcile(validIDs: validIDs, additionalGraphIDs: collectionIDs)
            for file in files where file.noteSource == nil && oldByID[file.id]?.modifiedAt != file.modifiedAt {
                data.extractedText.removeValue(forKey: file.id)
            }
        }
    }
    private func changeSection(_ next: Section?) {
        if next != .collections { collectionID = nil }
        selectedID = nil; selectedIDs = []; showInspector = false
    }
    private func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        switch currentSection {
        case .overview, .files, .media, .collections: break
        default: return false
        }
        guard !urls.isEmpty, !store.busy, !store.loadFailed else { return false }
        store.prepare(urls)
        return true
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 20, weight: .light)).foregroundStyle(accent)
                Text("Vault").font(.system(size: 18, weight: .medium, design: .rounded))
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            VaultMascotPanel(secureSection: currentSection == .secure).padding(.horizontal, 14).padding(.bottom, 12)
            List(selection: $section) {
                SwiftUI.Section("WORKSPACE") {
                    ForEach(Section.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 12, weight: section == item ? .medium : .regular))
                            .padding(.vertical, 6).tag(item)
                            .listRowBackground(section == item ? accent.opacity(0.09) : Color.clear)
                            .overlay(alignment: .leading) {
                                if section == item { Capsule().fill(accent).frame(width: 2, height: 18).offset(x: -12).accessibilityHidden(true) }
                            }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            VStack(alignment: .leading, spacing: 12) {
                Button(action: workspace.approveFolder) { Label("Scan Folders", systemImage: "folder.badge.plus").font(.system(size: 12)) }
                    .buttonStyle(.plain).disabled(workspace.working || store.busy)
                SettingsLink { Label("Settings", systemImage: "gearshape").font(.system(size: 12)) }.buttonStyle(.plain)
                Divider().opacity(0.5)
                Label("Local by design", systemImage: "checkmark.shield").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(20)
        }.background { ObservatoryBackground(grid: false) }.navigationSplitViewColumnWidth(min: 195, ideal: 210, max: 260)
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: section?.symbol ?? "square.grid.2x2").foregroundStyle(accent)
            Text(section?.rawValue ?? "Overview").font(.system(size: 16, weight: .medium))
            Spacer()
            if store.busy {
                ProgressView().controlSize(.small)
                Text("\(store.progress)/\(store.total)").font(.caption.monospacedDigit())
                Button("Cancel") { store.cancelImport() }
            } else if !workspace.data.locations.filter({ !$0.paused }).isEmpty {
                Label("\(workspace.data.locations.filter { !$0.paused }.count) monitored", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private func inspect(_ id: UUID) { selectedID = id; showInspector = true }
    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack { organizationControls; Spacer(); presentationControls }
                VStack(alignment: .leading, spacing: 12) { organizationControls; HStack { presentationControls; Spacer() } }
            }
            if results.isEmpty {
                libraryEmptyState
            } else {
                fileGrid
                Text("\(results.count) files · ⌘-click to select multiple · Stored locally")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var libraryEmptyState: some View {
        ContentUnavailableView {
            Label(store.library.files.isEmpty ? "Make room for clarity" : "No matching files", systemImage: "doc.badge.plus")
        } description: {
            Text(store.library.files.isEmpty ? "Add a few files to begin. Index them where they are, or keep verified copies in Vault." : "Try another search or change your filters.")
        } actions: {
            Button("Add Files…", action: store.chooseFiles).disabled(store.busy || store.loadFailed || workspace.working || notes.working)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridColumns: [GridItem] {
        listMode ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 170), spacing: 16)]
    }
    private var fileGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(results) { file in fileButton(file) }
            }.padding(2)
        }
    }
    private func fileButton(_ file: FileItem) -> some View {
        Button { selectFile(file.id) } label: { fileCard(file) }
            .buttonStyle(.plain)
            .contextMenu { fileMenu(file) }
    }
    @ViewBuilder
    private func fileMenu(_ file: FileItem) -> some View {
        Button("Open in Default App") { store.open(file) }
        Button("Reveal in Finder") { store.reveal(file) }
        Button(file.favorite ? "Remove Favorite" : "Favorite") {
            var updated = file; updated.favorite.toggle(); store.update(updated)
        }
        Divider()
        Button("Remove from Index…", role: .destructive) { requestRemoval(file) }
    }
    private func selectFile(_ id: UUID) {
        inspect(id)
        if NSEvent.modifierFlags.contains(.command) {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else { selectedIDs = [id] }
    }
    private var organizationControls: some View {
        HStack {
                Picker("Collection", selection: $collectionID) {
                    Text("All collections").tag(nil as UUID?)
                    ForEach(store.library.collections) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 200)
                Button("Filters") { filters.toggle() }.popover(isPresented: $filters) {
                    VStack(alignment: .leading) {
                        TextField("File extension (pdf, png…)", text: $typeFilter)
                        HStack { Slider(value: $minimumSizeMB, in: 0...1000); Text("At least \(Int(minimumSizeMB)) MB") }
                        Toggle("Added in the last 30 days", isOn: $recentOnly)
                        Button("Clear Filters") { typeFilter = ""; minimumSizeMB = 0; recentOnly = false }
                    }.padding(20).frame(width: 360)
                }
                if !selectedIDs.isEmpty { Button("Organize \(selectedIDs.count)") { bulkEditor = true } }
                Button { newCollection = true } label: { Image(systemName: "folder.badge.plus") }.help("Create collection").accessibilityLabel("Create collection")
                Toggle(isOn: $favoritesOnly) { Image(systemName: "star") }.toggleStyle(.button).help("Favorites only")
        }
    }
    private var presentationControls: some View {
        HStack {
                Picker("Sort", selection: $sort) { ForEach(["Added", "Name", "Type", "Size", "Modified"], id: \.self) { Text($0) } }.frame(width: 145)
                Button { listMode.toggle() } label: { Image(systemName: listMode ? "square.grid.2x2" : "list.bullet") }.help("Switch grid or list").accessibilityLabel(listMode ? "Show grid" : "Show list")
        }
    }
    private func fileCard(_ file: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !listMode { FileThumbnail(file: file).frame(height: 126).frame(maxWidth: .infinity).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)) }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(file.type.uppercased()) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if file.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(12).quietPanel()
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selectedIDs.contains(file.id) ? accent : Color.primary.opacity(0.09), lineWidth: selectedIDs.contains(file.id) ? 2 : 1))
            .contentShape(Rectangle())
    }
}

struct FileThumbnail: View {
    let file: FileItem
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().padding(8) }
            else { Image(systemName: VaultStyle.fileSymbol(file.type)).font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.secondary) }
        }.task(id: file.id) { await load() }
    }
    @MainActor private func load() async {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: file.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 180), scale: 2, representationTypes: .thumbnail)
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in continuation.resume(returning: representation?.nsImage) }
        }
        if !Task.isCancelled { thumbnail = image }
    }
}
