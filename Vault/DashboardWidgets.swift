import SwiftUI
import VaultCore

struct DashboardWidgets: View {
    @EnvironmentObject private var runtime: RuntimeController
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var preferences: WorkspacePreferencesStore
    @StateObject private var model = DashboardModel()
    @State private var customizing = false
    @State private var activity = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    let openMap: () -> Void
    let select: (UUID) -> Void
    private var visible: [DashboardWidgetConfiguration] { preferences.data.dashboard.widgets.filter(\.visible) }
    private var request: DashboardRequest {
        DashboardRequest(revision: CatalogRevision(library: library.graphRevision, workspace: workspace.browserRevision), activity: workspace.activityRevision,
            layout: preferences.data.dashboard, pins: preferences.data.pinnedCollections, history: preferences.data.history, analysisID: workspace.report?.id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your quick access").font(.headline)
                    Text("Widgets use their own categories. View All opens the corresponding browser.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("Customize Dashboard") { customizing = true }
            }
            if visible.isEmpty { Text("Choose the widgets you want with Customize Dashboard.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12) }
            if runtime.windowVisible, let result = model.result {
                WidgetGridLayout {
                    ForEach(visible) { config in
                        DashboardWidgetCard(config: config, result: result, openMap: openMap, showActivity: { activity = true })
                            .layoutValue(key: WidgetSpanKey.self, value: config.size == .expanded ? 2 : 1)
                            .draggable("vault.widget:" + config.kind.rawValue)
                            .dropDestination(for: String.self) { values, _ in
                                guard preferences.canWrite, let value = values.first, value.hasPrefix("vault.widget:"), let kind = DashboardWidgetKind(rawValue: String(value.dropFirst("vault.widget:".count))) else { return false }
                                preferences.moveWidget(kind, before: config.kind); return true
                            }
                    }
                }.animation(reducedMotion || !cinematicMotion ? nil : .easeInOut(duration: 0.2), value: preferences.data.dashboard)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(VaultStyle.amber) }
            if let error = preferences.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(VaultStyle.amber)
                    Button("Retry Save") { Task { await preferences.flush() } }.disabled(!preferences.canWrite)
                }
            }
        }
        .task(id: runtime.windowVisible ? request : nil) {
            if runtime.windowVisible { await model.load(request, library: library, workspace: workspace, preferences: preferences) }
            else { model.releaseTransientContent() }
        }
        .sheet(isPresented: $customizing) { DashboardCustomization() }
        .sheet(isPresented: $activity) { OverviewActivity(select: select) }
    }
}
private struct DashboardWidgetCard: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var preferences: WorkspacePreferencesStore
    @Environment(\.workspaceRouting) private var routing
    let config: DashboardWidgetConfiguration
    let result: PreparedDashboard
    let openMap: () -> Void
    let showActivity: () -> Void
    @State private var hovered: UUID?
    private var files: [DashboardFile] { result.snapshot.files[config.kind] ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: config.kind.symbol).foregroundStyle(VaultStyle.lavender)
                Text(config.kind.title).font(.headline)
                Spacer(minLength: 4)
                if config.kind == .favorites {
                    Menu("View All") {
                        Button("Favorite Files") { routing.browseFiles?(.all, true) }
                        Button("Pinned Collections") { routing.browsePinnedCollections?() }
                    }.font(.caption).menuStyle(.borderlessButton).fixedSize()
                } else { Button("View All", action: viewAll).font(.caption).buttonStyle(.plain).foregroundStyle(VaultStyle.lavender) }
            }
            if config.kind == .storage { storage }
            else if config.kind == .exploring { exploration }
            else {
                if files.isEmpty && !(config.kind == .favorites && !result.snapshot.collections.isEmpty) { empty }
                if config.kind == .photos {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 10) { ForEach(files) { row in photo(row) } }
                } else { ForEach(files) { row in fileRow(row) } }
                if config.kind == .favorites {
                    ForEach(result.snapshot.collections) { collection in
                        HStack {
                            Button { routing.browseCollection?(collection.id) } label: { Label(collection.name, systemImage: "square.stack").font(.callout).lineLimit(1) }.buttonStyle(.plain)
                            Spacer()
                            Button { preferences.toggleCollectionPin(collection.id) } label: { Image(systemName: "pin.slash") }.help("Unpin collection").accessibilityLabel("Unpin " + collection.name).disabled(!preferences.canWrite)
                        }
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .glassSurface(radius: 14, tint: config.kind == .photos || config.kind == .media ? VaultStyle.teal : VaultStyle.lavender)
    }
    private func fileRow(_ row: DashboardFile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if config.kind == .media { FileThumbnail(file: row.file, size: CGSize(width: 80, height: 64)).frame(width: 66, height: 52).quietPanel() }
            else { Image(systemName: config.kind == .notes ? "note.text" : VaultStyle.fileSymbol(row.file.type)).foregroundStyle(VaultStyle.lavender).frame(width: 20).padding(.top, 3) }
            VStack(alignment: .leading, spacing: 5) {
                Button { open(row) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.file.noteSource?.title ?? row.file.filename).font(.callout.weight(.medium)).lineLimit(2)
                        Text(row.file.type.uppercased() + " · " + row.dateLabel + " " + row.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                        if config.kind == .notes { Text(row.excerpt.isEmpty ? "Open to read this local snapshot." : row.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(config.size == .expanded ? 4 : 2) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if hovered == row.id {
                    HStack {
                        Button("Preview") { routing.preview?(row.id, nil) }
                        Button("Open") { library.open(row.file) }
                        Button { library.toggleFavorite(row.id) } label: { Image(systemName: row.file.favorite ? "star.fill" : "star") }.help("Toggle favorite")
                    }.controlSize(.mini)
                }
            }
            if row.file.favorite { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(VaultStyle.amber) }
        }.padding(.vertical, 5).onHover { hovered = $0 ? row.id : nil }.contextMenu { actions(row) }
    }
    private func photo(_ row: DashboardFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open(row) } label: { FileThumbnail(file: row.file, size: CGSize(width: 180, height: 120)).frame(height: config.size == .expanded ? 112 : 82).frame(maxWidth: .infinity).quietPanel() }.buttonStyle(.plain)
            Text(row.file.filename).font(.caption2).lineLimit(1)
            if let metadata = row.photoMetadata { Text(metadata).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2) }
            else { Text("Indexed " + row.file.indexedAt.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 9)).foregroundStyle(.secondary) }
        }.contextMenu { actions(row) }
    }
    private var exploration: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.snapshot.trail.isEmpty { Text("Explore a document, subject, or collection to begin a trail.").font(.caption).foregroundStyle(.secondary) }
            ForEach(result.snapshot.trail) { item in
                Button { routing.showMap?(item.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(item.title, systemImage: "arrow.turn.down.right").font(.callout).lineLimit(2)
                        Text(item.step.reason.title + " · " + item.step.visitedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            if result.snapshot.trail.isEmpty { Button("Open Knowledge Map", action: openMap).controlSize(.small) }
        }
    }
    private var storage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let storage = result.snapshot.storage {
                Text("Indexed logical · " + bytes(storage.indexedLogicalBytes)).font(.callout)
                Text("Managed logical · " + bytes(storage.managedLogicalBytes)).font(.caption).foregroundStyle(.secondary)
            }
            if let analysis = result.analysis {
                Text("Last analysis allocated · " + bytes(analysis.allocated) + " across \(analysis.files) measured files").font(.caption).foregroundStyle(.secondary)
                Text("\(analysis.duplicateGroups) verified duplicate groups to review").font(.caption).foregroundStyle(VaultStyle.teal)
            } else { Text("Run Storage & Cleanup to measure allocated usage and verify duplicate candidates.").font(.caption).foregroundStyle(.secondary) }
            Text("Indexed scope only. These values are not the Mac’s capacity or guaranteed recoverable space.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(config.kind == .recent ? "Files appear after a successful default-app open or a note read through Vault." : "No matching items yet.").font(.caption).foregroundStyle(.secondary)
            Button(config.kind == .notes ? "Add Notes…" : config.kind == .favorites ? "Browse Files to Favorite" : "Browse Files") {
                if config.kind == .favorites { routing.browseFiles?(.all, false) } else { viewAll() }
            }.controlSize(.small)
        }.padding(.vertical, 10)
    }
    @ViewBuilder private func actions(_ row: DashboardFile) -> some View {
        Button("Preview") { routing.preview?(row.id, nil) }
        Button("Open in Default App") { library.open(row.file) }
        Button("Reveal in Finder") { library.reveal(row.file) }
        Button(row.file.favorite ? "Unpin / Remove Favorite" : "Pin / Favorite") { library.toggleFavorite(row.id) }
        Button("Explore Connections") { routing.showMap?(row.id) }
    }
    private func open(_ row: DashboardFile) { if config.kind == .notes { routing.browseNotes?(row.id) } else { routing.preview?(row.id, nil) } }
    private func viewAll() {
        switch config.kind {
        case .notes: if files.isEmpty { routing.addNotes?() } else { routing.browseNotes?(nil) }
        case .documents: routing.browseFiles?(.documents, false)
        case .photos: routing.browseFiles?(.photos, false)
        case .media: routing.browseFiles?(.media, false)
        case .recent: showActivity()
        case .favorites: routing.browseFiles?(.all, true)
        case .exploring: openMap()
        case .storage: routing.browseStorage?()
        }
    }
    private func bytes(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}
private struct WidgetSpanKey: LayoutValueKey { static let defaultValue = 1 }
private struct WidgetGridLayout: Layout {
    private let gap: CGFloat = 16
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { arrangement(width: proposal.width ?? 620, subviews: subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, cell) in layout.cells.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + cell.minX, y: bounds.minY + cell.minY), anchor: .topLeading, proposal: ProposedViewSize(width: cell.width, height: cell.height))
        }
    }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, cells: [CGRect]) {
        let width = max(1, width), columns = max(1, min(3, Int((width + gap) / (280 + gap))))
        let unit = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        var x = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, cells: [CGRect] = []
        for view in subviews {
            let span = min(columns, max(1, view[WidgetSpanKey.self]))
            if x + span > columns { y += rowHeight + gap; x = 0; rowHeight = 0 }
            let cellWidth = unit * CGFloat(span) + gap * CGFloat(span - 1)
            let height = view.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
            cells.append(CGRect(x: CGFloat(x) * (unit + gap), y: y, width: cellWidth, height: height))
            rowHeight = max(rowHeight, height); x += span
        }
        return (CGSize(width: width, height: cells.isEmpty ? 0 : y + rowHeight), cells)
    }
}
struct DashboardCustomization: View {
    @EnvironmentObject private var preferences: WorkspacePreferencesStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Customize Dashboard").font(.title2); Spacer(); Button("Done") { Task { await preferences.flush(); dismiss() } } }
            Text("Show only what you use. Drag to reorder, or use the arrow controls. Expanded widgets display more items and span two columns when space permits.").font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(Array(preferences.data.dashboard.widgets.enumerated()), id: \.element.id) { index, config in
                    HStack(spacing: 12) {
                        Toggle(config.kind.title, isOn: Binding(get: { config.visible }, set: { value in preferences.setWidget(config.kind) { $0.visible = value } })).frame(minWidth: 170, alignment: .leading)
                        Picker("Size", selection: Binding(get: { config.size }, set: { value in preferences.setWidget(config.kind) { $0.size = value } })) { Text("Compact").tag(DashboardWidgetSize.compact); Text("Expanded").tag(DashboardWidgetSize.expanded) }.frame(width: 140)
                        if ![.storage, .exploring, .recent].contains(config.kind) {
                            Picker("Priority", selection: Binding(get: { config.priority }, set: { value in preferences.setWidget(config.kind) { $0.priority = value } })) { Text("Recent").tag(DashboardPriority.recent); Text("Favorites first").tag(DashboardPriority.favorites) }.frame(width: 160)
                        }
                        Spacer(minLength: 0)
                        Button { preferences.moveWidgets(from: IndexSet(integer: index), to: index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).accessibilityLabel("Move " + config.kind.title + " up")
                        Button { preferences.moveWidgets(from: IndexSet(integer: index), to: index + 2) } label: { Image(systemName: "chevron.down") }.disabled(index + 1 == preferences.data.dashboard.widgets.count).accessibilityLabel("Move " + config.kind.title + " down")
                    }.padding(.vertical, 6)
                }.onMove { preferences.moveWidgets(from: $0, to: $1) }
            }.disabled(!preferences.canWrite)
            HStack { Button("Reset Default Layout") { preferences.change { $0.dashboard = DashboardLayout() } }.disabled(!preferences.canWrite); Spacer(); Text("Saved locally · no file copies").font(.caption).foregroundStyle(.secondary) }
            if let error = preferences.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(VaultStyle.amber)
                    Button("Retry Save") { Task { await preferences.flush() } }.disabled(!preferences.canWrite)
                }
            }
        }.padding(24).frame(width: 800, height: 550)
    }
}
