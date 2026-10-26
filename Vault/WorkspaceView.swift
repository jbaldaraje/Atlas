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
    @StateObject private var graphModel = KnowledgeMapModel()
    @AppStorage("fileKindFilter") private var fileKind = FileKindFilter.all
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
    @State private var subjectID: UUID?
    @State private var subjectRoute = UUID()
    @State private var collectionRoute = UUID()
    @State private var collectionID: UUID?
    @State private var favoritesOnly = false
    @State private var listMode = false
    @State private var sort = "Added"
    @State private var collectionName = ""
    @State private var newCollection = false
    @State private var removing: FileItem?
    private let accent = VaultStyle.lavender
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
            OverviewWorkspace(select: inspect, openMap: openMap, openSubjects: openAllSubjects, openCollections: openAllCollections, addNotes: { showingNotesImport = true })
        case .notes:
            NotesWorkspace(query: query, select: inspect, addNotes: { showingNotesImport = true })
        case .graph:
            KnowledgeMap(model: graphModel, selectedID: $selectedID, select: inspect)
        case .files, .media, .collections:
            libraryContent
        case .subjects:
            SubjectWorkspace(initialSubjectID: subjectID, query: query, select: inspect).id(subjectRoute)
                .padding(24)
        case .timeline:
            FolderBrowser(section: .timeline, query: query, listMode: true, select: inspect).padding(24)
        default:
            FeatureWorkspace(section: currentSection.rawValue, select: inspect)
                .padding(.top, 18)
        }
    }

    private var inspectedWorkspace: some View {
        navigationLayout
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if workspace.scanMinimized { ScanStatusBar() }
            }
            .inspector(isPresented: $showInspector) { contextInspector }
            .tint(accent)
            .searchable(text: $query, prompt: "Search names, descriptions, and tags")
            .toolbar { workspaceToolbar }
    }

    private var contextInspector: some View {
        ContextInspector(id: selectedID, select: inspect, remove: requestRemoval, browseSubject: openSubject, browseCollection: openCollection)
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
            .onChange(of: fileKind) { _, _ in selectedIDs = []; selectedID = nil; showInspector = false }
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
    private func openAllSubjects() { subjectID = nil; subjectRoute = UUID(); section = .subjects }
    private func openAllCollections() { collectionID = nil; collectionRoute = UUID(); section = .collections }
    private func openSubject(_ id: UUID) { subjectID = id; subjectRoute = UUID(); section = .subjects }
    private func openCollection(_ id: UUID) { collectionID = id; collectionRoute = UUID(); section = .collections }
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
        if next != .subjects { subjectID = nil }
        selectedID = nil; selectedIDs = []; showInspector = false
    }
    private func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        switch currentSection {
        case .overview, .files, .media, .collections: break
        default: return false
        }
        guard !urls.isEmpty, !store.busy, !store.loadFailed, !workspace.working, !notes.working else { return false }
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
        VStack(alignment: .leading, spacing: 12) {
            headerLine
            if currentSection != .secure { FileKindPicker() }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private var headerLine: some View {
        HStack(spacing: 12) {
            Image(systemName: section?.symbol ?? "square.grid.2x2").foregroundStyle(accent)
            Text(section?.rawValue ?? "Overview").font(.system(size: 16, weight: .medium))
            Spacer()
            if workspace.scanIsActive {
                Button { workspace.showScanResults() } label: {
                    Label(scanStatusLabel, systemImage: "viewfinder")
                        .font(.caption.monospacedDigit())
                }.help("Open scan progress")
            } else if store.busy && !workspace.monitoringActive && !notes.working {
                ProgressView().controlSize(.small)
                Text("\(store.progress)/\(store.total)").font(.caption.monospacedDigit())
                Button("Cancel") { store.cancelImport() }
            } else if !workspace.data.locations.filter({ !$0.paused }).isEmpty {
                Label("\(workspace.data.locations.filter { !$0.paused }.count) monitored", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var scanStatusLabel: String {
        guard let percent = workspace.activeScan?.percentCompleted else { return "Scan · counting…" }
        return "Scan · \(percent)%"
    }
    private func inspect(_ id: UUID) { selectedID = id; showInspector = true }
    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack { organizationControls; Spacer(); presentationControls }
                VStack(alignment: .leading, spacing: 12) { organizationControls; HStack { presentationControls; Spacer() } }
            }
            FolderBrowser(section: browserSection, query: query, favorites: favoritesOnly, type: typeFilter,
                          minimumBytes: Int64(minimumSizeMB * 1_000_000), recent: recentOnly, sort: sort,
                          listMode: listMode, initialLocation: browserLocation, selectedIDs: selectedIDs,
                          select: selectFile, remove: requestRemoval)
                .id(currentSection.rawValue + (currentSection == .collections ? collectionRoute.uuidString : ""))
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
    private var browserSection: CatalogSection {
        currentSection == .media ? .media : currentSection == .collections ? .collections : .files
    }
    private var browserLocation: CatalogLocation {
        var location = CatalogLocation(); location.collectionID = currentSection == .collections ? collectionID : nil
        return location
    }
    private func selectFile(_ id: UUID) {
        inspect(id)
        if NSEvent.modifierFlags.contains(.command) {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else { selectedIDs = [id] }
    }
    private var organizationControls: some View {
        HStack {
                if collectionID != nil { Button("All Collections") { collectionID = nil } }
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

}

struct FileThumbnail: View {
    let file: FileItem
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().padding(8) }
            else { Image(systemName: VaultStyle.fileSymbol(file.type)).font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.secondary) }
        }.task(id: fingerprint) { await load() }
    }
    private var fingerprint: String { "\(file.id)-\(file.size)-\(file.modifiedAt?.timeIntervalSinceReferenceDate ?? 0)" }
    @MainActor private func load() async {
        thumbnail = nil
        guard !Task.isCancelled else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: file.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 180), scale: 2, representationTypes: .thumbnail)
        let image = await ThumbnailPipeline.shared.image(key: fingerprint, request: request)
        if !Task.isCancelled { thumbnail = image }
    }
}
