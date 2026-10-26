import SwiftUI
import VaultCore

private extension GraphNode {
    var color: Color { kind == .subject ? VaultStyle.teal : kind == .collection ? VaultStyle.amber : VaultStyle.lavender }
    var symbol: String {
        switch kind {
        case .subject: "sparkle"
        case .collection: "square.stack"
        case .document: isNote ? "note.text" : VaultStyle.fileSymbol(type)
        }
    }
}

struct KnowledgeMap: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var navigator: ExplorationNavigator
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: KnowledgeMapModel
    @AppStorage("fileKindFilter") private var fileKind = FileKindFilter.all
    @Binding var selectedID: UUID?
    let select: (UUID) -> Void
    var compact = false
    @State private var page = 0
    @State private var retryID = UUID()
    @State private var relatedSearch = ""
    @State private var query = ""
    @State private var camera = GraphCamera()
    @State private var panStart: SpatialPoint?
    @State private var zoomStart: Double?
    @State private var positions: [UUID: SpatialPoint] = [:]
    @State private var hoveredID: UUID?
    @State private var showSubjects = true
    @State private var showCollections = true
    @State private var showMembership = true
    @State private var focusMode = false
    @State private var organizedList = false
    @State private var grid = true
    @State private var viewport = CGSize(width: 800, height: 600)
    @State private var linking = false
    @State private var linkTarget: UUID?
    @State private var pulse = false
    @State private var pulseStarted = Date()
    @State private var pulseTask: Task<Void, Never>?
    @State private var projectedSelection: UUID?

    private var request: GraphRequest {
        var query = GraphQuery()
        query.text = self.query; query.selectedID = selectedID
        query.subjects = showSubjects; query.collections = showCollections; query.membership = showMembership
        query.focus = compact || focusMode; query.page = page
        query.originID = navigator.history.current?.itemID == selectedID ? navigator.history.current?.originID : nil
        query.kind = fileKind
        return GraphRequest(revision: GraphRevision(library: store.graphRevision, workspace: workspace.graphRevision), query: query)
    }
    private var selectedNodeID: UUID? { model.projection.selectedExists ? selectedID : nil }
    private var nodes: [GraphNode] { model.projection.nodes }
    private var edges: [GraphEdge] { model.projection.edges }
    private func neighbors(_ id: UUID?) -> Set<UUID> {
        guard let id else { return [] }
        return Set(edges.lazy.filter { $0.source == id || $0.target == id || model.projection.activePathEdgeIDs.contains($0.id) }.flatMap { [$0.source, $0.target] })
    }
    var body: some View {
        VStack(spacing: 0) {
            if compact { HStack { Label("Map context", systemImage: "point.3.connected.trianglepath.dotted"); Spacer(); Button("Fit", action: fit) }.font(.caption).padding(10) }
            else { controls.padding(.horizontal, 18).padding(.vertical, 12) }
            Divider().opacity(0.5)
            if store.library.files.isEmpty && workspace.data.subjects.isEmpty && store.library.collections.isEmpty {
                ContentUnavailableView {
                    Label("A space for your connections", systemImage: "point.3.connected.trianglepath.dotted")
                } description: { Text("Add files, link them to subjects, and build your own constellation of ideas.") } actions: {
                    Button("Add Files…", action: store.chooseFiles)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background { ObservatoryBackground() }
            } else if !model.ready {
                firstLoad
            } else if organizedList {
                List(nodes) { node in
                    Button { activate(node.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: node.symbol).foregroundStyle(node.color).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) { Text(node.title); Text(node.subtitle).font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            if selectedID == node.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(VaultStyle.lavender) }
                        }.padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain).contextMenu { nodeActions(node) }
                }.scrollContentBackground(.hidden).background { ObservatoryBackground(grid: false) }
            } else {
                scene
            }
            Divider().opacity(0.5)
            footer.padding(.horizontal, 20).padding(.vertical, 10)
        }
        .task(id: request) { await prepare() }
        .task(id: retryID) { if model.error != nil { await prepare() } }
        .onAppear { applyProjection() }
        .onChange(of: model.generation) { _, _ in applyProjection() }
        .onChange(of: query) { _, _ in page = 0 }
        .onChange(of: fileKind) { _, _ in page = 0 }
        .onChange(of: showSubjects) { _, _ in page = 0 }
        .onChange(of: showCollections) { _, _ in page = 0 }
        .onChange(of: showMembership) { _, _ in page = 0 }
        .onChange(of: focusMode) { _, _ in page = 0 }
        .onChange(of: selectedID) { _, _ in
            pulseTask?.cancel()
            guard selectedID != nil else { pulse = false; focusMode = false; return }
            pulseStarted = .now; pulse = !reducedMotion && cinematicMotion
            pulseTask = Task { try? await Task.sleep(for: .seconds(1.8)); if !Task.isCancelled { pulse = false } }
        }
        .onChange(of: cinematicMotion) { _, enabled in if !enabled { pulseTask?.cancel(); pulse = false } }
        .onDisappear { pulseTask?.cancel() }
        .sheet(isPresented: $linking) { relationshipEditor }
    }
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { mapSearch; modeControls; Spacer(minLength: 0); filters; layoutToggle }
            VStack(spacing: 10) { HStack { mapSearch; layoutToggle }; HStack { modeControls; Spacer(); filters } }
        }
    }
    private var mapSearch: some View {
        HStack(spacing: 7) { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Find a connection…", text: $query).textFieldStyle(.plain) }
            .padding(8).frame(minWidth: 140, maxWidth: 240).quietPanel()
    }
    private var modeControls: some View {
        HStack(spacing: 6) {
            Button { focusMode = false; query = ""; page = 0; fit() } label: { Label("Overview", systemImage: "arrow.up.left.and.arrow.down.right") }.help("Fit the visible network")
            Toggle(isOn: $focusMode) { Label("Focus", systemImage: "scope") }.toggleStyle(.button).disabled(selectedNodeID == nil)

        }.controlSize(.small)
    }
    private var filters: some View {
        Menu {
            Toggle("Subjects", isOn: $showSubjects)
            Toggle("Collections", isOn: $showCollections)
            Toggle("Membership edges", isOn: $showMembership)
            Divider(); Toggle("Spatial guide", isOn: $grid)
        } label: { Label("Layers", systemImage: "square.3.layers.3d") }.menuStyle(.borderlessButton).fixedSize()
    }
    private var layoutToggle: some View {
        Picker("Map presentation", selection: $organizedList) {
            Image(systemName: "point.3.connected.trianglepath.dotted").tag(false)
            Image(systemName: "list.bullet").tag(true)
        }.pickerStyle(.segmented).frame(width: 76).help("Spatial map or organized list")
    }
    private var scene: some View {
        GeometryReader { geometry in
            let visible = nodes
            let related = neighbors(hoveredID ?? selectedNodeID)
            ZStack(alignment: .bottomTrailing) {
                ObservatoryBackground(grid: grid)
                Color.clear.contentShape(Rectangle()).gesture(DragGesture().onChanged { value in
                    if panStart == nil { panStart = camera.pan }
                    camera.pan = SpatialPoint(x: (panStart?.x ?? 0) + value.translation.width, y: (panStart?.y ?? 0) + value.translation.height)
                }.onEnded { _ in panStart = nil })
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !pulse || reducedMotion || !cinematicMotion || scenePhase != .active)) { timeline in
                    Canvas { context, _ in
                        let visibleIDs = Set(visible.map(\.id))
                        for edge in edges where visibleIDs.contains(edge.source) && visibleIDs.contains(edge.target) {
                            guard let a = positions[edge.source], let b = positions[edge.target] else { continue }
                            let start = screen(a), end = screen(b)
                            let active = model.projection.activePathEdgeIDs.contains(edge.id) || edge.source == (hoveredID ?? selectedNodeID) || edge.target == (hoveredID ?? selectedNodeID)
                            let curve = edgePath(start, end)
                            let color = edge.membership ? VaultStyle.teal : VaultStyle.lavender
                            context.stroke(curve, with: .color(active ? color.opacity(0.8) : Color.primary.opacity(contrast == .increased ? 0.35 : 0.13)), style: StrokeStyle(lineWidth: active ? 1.4 : 0.8, dash: edge.membership && !active ? [3, 5] : []))
                            if active && pulse && !reducedMotion {
                                let t = min(1, timeline.date.timeIntervalSince(pulseStarted) / 1.8)
                                let point = bezierPoint(start, end, t: edge.target == (hoveredID ?? selectedNodeID) || edge.source == navigator.history.current?.originID ? t : 1 - t)
                                context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(color.opacity(1 - t)))
                            }
                        }
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(visible) { node in
                    if let point = positions[node.id] {
                        SpatialNodeView(title: node.title, subtitle: node.subtitle, symbol: node.symbol, color: node.color, selected: selectedID == node.id, hovered: hoveredID == node.id, quiet: (hoveredID ?? selectedNodeID) != nil && !related.contains(node.id) && node.id != (hoveredID ?? selectedNodeID), favorite: node.favorite, compact: camera.zoom < 0.7 && selectedID != node.id && hoveredID != node.id)
                            .scaleEffect(selectedID == node.id || hoveredID == node.id ? max(0.85, min(camera.zoom, 1.15)) : max(0.4, min(camera.zoom, 1.15)))
                            .position(screen(point))
                            .onHover { hoveredID = $0 ? node.id : nil }
                            .onTapGesture(count: 2) { activate(node.id); performFileAction(node.id, action: store.open) }
                            .onTapGesture(count: 1) { activate(node.id) }
                            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("spatialScene")).onChanged { value in
                                positions[node.id] = camera.world(SpatialPoint(x: value.location.x, y: value.location.y), width: viewport.width, height: viewport.height)
                            }.onEnded { _ in if let point = positions[node.id] { model.move(node.id, to: point) } })
                            .contextMenu { nodeActions(node) }
                            .focusable()
                            .onKeyPress(.return) { activate(node.id); return .handled }
                            .onKeyPress(.space) { activate(node.id); focusMode = true; fit(); return .handled }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(node.title), \(String(describing: node.kind))")
                            .accessibilityValue(selectedID == node.id ? "Selected" : "")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { activate(node.id) }
                            .accessibilityAction(named: Text("Focus")) { activate(node.id); focusMode = true; fit() }
                    }
                }
                zoomControls.padding(18)
                if visible.isEmpty { ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false) }
            }
            .coordinateSpace(name: "spatialScene").clipped()
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if zoomStart == nil { zoomStart = camera.zoom }
                camera.setZoom((zoomStart ?? 1) * value.magnification)
            }.onEnded { _ in zoomStart = nil })
            .onAppear { viewport = geometry.size; fit() }
            .onChange(of: geometry.size) { _, size in viewport = size }
        }
    }
    private var zoomControls: some View {
        HStack(spacing: 12) {
            Button { camera.setZoom(camera.zoom / 1.2) } label: { Image(systemName: "minus") }.help("Zoom out").accessibilityLabel("Zoom out")
            Text("\(Int(camera.zoom * 100))%").font(.system(size: 10, design: .monospaced)).frame(width: 36)
            Button { camera.setZoom(camera.zoom * 1.2) } label: { Image(systemName: "plus") }.help("Zoom in").accessibilityLabel("Zoom in")
            Divider().frame(height: 14)
            Button(action: fit) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit to view").accessibilityLabel("Fit to view")
        }.buttonStyle(.plain).padding(12).quietPanel()
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(VaultStyle.amber)
                    Button("Reload Map") { model.retry(); retryID = UUID() }
                }
            }
            if model.projection.contextOutsideFilter { Text("Selected context is outside the current type filter").font(.caption2).foregroundStyle(.secondary) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { if !compact { legend }; Spacer(); pageControls; summary }
                HStack { pageControls; Spacer(); summary }
            }
        }.help("Only the current page's nodes and up to 900 connections are rendered. Search covers the entire library; use Focus or page controls to explore more. This does not limit scanning or indexing.")
    }
    private var pageControls: some View {
        HStack(spacing: 9) {
            Button { page = max(0, model.projection.page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(model.loading || model.projection.page == 0).help("Previous map page").accessibilityLabel("Previous map page")
            Text("\(model.projection.page + 1) / \(model.projection.pageCount)").font(.caption2.monospacedDigit())
            Button { page = model.projection.page + 1 } label: { Image(systemName: "chevron.right") }
                .disabled(model.loading || model.projection.page + 1 >= model.projection.pageCount).help("Next map page").accessibilityLabel("Next map page")
        }.controlSize(.mini)
    }
    private var summary: some View {
        HStack(spacing: 7) {
            if model.loading { ProgressView().controlSize(.mini) }
            Text("\(nodes.count) visible · \(model.projection.matching) matching · \(model.projection.total) total").font(.caption2).foregroundStyle(.secondary)
            if model.projection.edgesTruncated { Text("Connection detail limited").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private var firstLoad: some View {
        VStack(spacing: 14) {
            if model.error == nil { ProgressView() }
            Text(model.error == nil ? "Preparing your map…" : "Map unavailable").font(.headline)
            Text("Building a local connection index in the background. Your full library stays available.").font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background { ObservatoryBackground(grid: false) }
    }
    private var legend: some View {
        HStack(spacing: 12) {
            Label("Files", systemImage: "doc.text").foregroundStyle(VaultStyle.lavender)
            Label("Subjects", systemImage: "sparkle").foregroundStyle(VaultStyle.teal)
            Label("Collections", systemImage: "square.stack").foregroundStyle(VaultStyle.amber)
        }.font(.system(size: 10))
    }
    @ViewBuilder private func nodeActions(_ node: GraphNode) -> some View {
        Button("Focus Connections") { activate(node.id); focusMode = true; page = 0 }
        Button("Expand to Overview") { focusMode = false; query = ""; page = 0 }
        if node.kind == .document {
            Divider()
            // Do not search/copy FileItem values while SwiftUI constructs every node's menu.
            Button("Open in Default App") { performFileAction(node.id, action: store.open) }
            Button("Reveal in Finder") { performFileAction(node.id, action: store.reveal) }
            Button("Create Relationship…") { activate(node.id); linkTarget = nil; relatedSearch = ""; linking = true }
            Button(node.favorite ? "Remove Favorite" : "Favorite") {
                performFileAction(node.id) { file in var next = file; next.favorite.toggle(); store.update(next) }
            }
        }
    }
    private var relationshipEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect documents").font(.title3.bold())
            Text(nodes.first { $0.id == selectedID }?.title ?? "Selected file").foregroundStyle(.secondary)
            TextField("Search all documents…", text: $relatedSearch).onChange(of: relatedSearch) { _, _ in linkTarget = nil }
            Picker("Related file", selection: $linkTarget) {
                Text("Choose a document").tag(nil as UUID?)
                ForEach(relationshipCandidates) { Text($0.filename).tag(Optional($0.id)) }
            }
            Text("Showing up to 50 matching documents. Search to narrow the choices. This relationship stays in Vault; neither file is moved or modified.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Cancel") { linking = false }; Spacer(); Button("Create Connection") {
                if let selectedID, let linkTarget { workspace.change { $0.link(selectedID, linkTarget, label: "Related") } }
                linking = false
            }.disabled(linkTarget == nil || selectedID == nil) }
        }.padding(24).frame(width: 440)
    }
    private var relationshipCandidates: [FileItem] {
        Array(store.library.files.lazy.filter { $0.id != selectedID && fileKind.includes(fileExtension: $0.type) && (relatedSearch.isEmpty || $0.filename.localizedCaseInsensitiveContains(relatedSearch)) }.prefix(50))
    }
    private func performFileAction(_ id: UUID, action: (FileItem) -> Void) {
        if let file = store.library.files.first(where: { $0.id == id }) { action(file) }
    }
    private func activate(_ id: UUID) { selectedID = id; select(id) }
    private func prepare() async {
        await model.load(request, library: store.library, subjects: workspace.data.subjects, relationships: workspace.data.relationships, legacyPositions: workspace.data.graphPositions ?? [:], sharedEngine: store.knowledgeGraph)
    }
    private func applyProjection() {
        let initial = positions.isEmpty
        let changedNodes = Set(positions.keys) != Set(model.positions.keys)
        let selectionIsReady = model.applied?.query.selectedID == selectedID
        let selectionChanged = selectionIsReady && projectedSelection != selectedID
        positions = model.positions
        if selectionIsReady { projectedSelection = selectedID }
        if !initial, selectionChanged, let id = selectedID, let point = positions[id] {
            withAnimation(reducedMotion || !cinematicMotion ? nil : .easeInOut(duration: 0.28)) { camera.focus(point) }
        } else if initial || changedNodes { fit() }
    }
    private func fit() {
        camera.fit(nodes.compactMap { positions[$0.id] }, width: viewport.width, height: viewport.height)
    }
    private func screen(_ point: SpatialPoint) -> CGPoint {
        let result = camera.screen(point, width: viewport.width, height: viewport.height)
        return CGPoint(x: result.x, y: result.y)
    }
    private func edgePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        let bend = min(70, abs(b.x - a.x) * 0.12)
        return Path { path in path.move(to: a); path.addCurve(to: b, control1: CGPoint(x: a.x + (b.x - a.x) / 3, y: a.y - bend), control2: CGPoint(x: a.x + (b.x - a.x) * 2 / 3, y: b.y - bend)) }
    }
    private func bezierPoint(_ a: CGPoint, _ b: CGPoint, t: Double) -> CGPoint {
        let bend = min(70, abs(b.x - a.x) * 0.12), u = 1 - t
        let c = CGPoint(x: a.x + (b.x - a.x) / 3, y: a.y - bend), d = CGPoint(x: a.x + (b.x - a.x) * 2 / 3, y: b.y - bend)
        return CGPoint(x: u*u*u*a.x + 3*u*u*t*c.x + 3*u*t*t*d.x + t*t*t*b.x, y: u*u*u*a.y + 3*u*u*t*c.y + 3*u*t*t*d.y + t*t*t*b.y)
    }

}

private struct SpatialNodeView: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let selected: Bool
    let hovered: Bool
    let quiet: Bool
    let favorite: Bool
    let compact: Bool
    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 15).fill(color.opacity(selected ? 0.19 : 0.07)).frame(width: 56, height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(color.opacity(selected ? 0.95 : hovered ? 0.65 : 0.3), lineWidth: selected ? 1.7 : 0.8))
                    .shadow(color: color.opacity(selected ? 0.26 : hovered ? 0.15 : 0.04), radius: selected ? 20 : 12)
                Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(color).frame(width: 56, height: 64)
                if favorite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(VaultStyle.amber).padding(6) }
            }
            if !compact {
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium)).lineLimit(hovered ? 3 : 1).multilineTextAlignment(.center).frame(width: 152)
                Text(subtitle).font(.system(size: 8, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
            }
        }.frame(width: 166, height: compact ? 76 : 116).opacity(quiet && contrast != .increased ? 0.63 : 1)
            .scaleEffect(hovered && !reducedMotion && cinematicMotion ? 1.035 : 1)
            .animation(reducedMotion || !cinematicMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .help("\(title) · \(subtitle)")
    }
}
