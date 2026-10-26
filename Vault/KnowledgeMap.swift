import SwiftUI
import VaultCore

private enum NodeKind: String { case document, subject, collection }
private struct KnowledgeNode: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let symbol: String
    let kind: NodeKind
    let favorite: Bool
    var color: Color { kind == .subject ? VaultStyle.teal : kind == .collection ? VaultStyle.amber : VaultStyle.lavender }
}
private struct KnowledgeEdge: Identifiable {
    let id: String
    let source: UUID
    let target: UUID
    let membership: Bool
}

struct KnowledgeMap: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @Binding var selectedID: UUID?
    let select: (UUID) -> Void
    @State private var loaded = false
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

    private var allNodes: [KnowledgeNode] {
        let subjects = workspace.data.subjects.map { KnowledgeNode(id: $0.id, title: $0.name, subtitle: "SUBJECT · \($0.fileIDs.count) FILES", symbol: "sparkle", kind: .subject, favorite: false) }
        let collections = store.library.collections.map { collection in KnowledgeNode(id: collection.id, title: collection.name, subtitle: "COLLECTION", symbol: "square.stack", kind: .collection, favorite: false) }
        let files = store.library.files.map { file in KnowledgeNode(id: file.id, title: file.filename, subtitle: file.type.uppercased(), symbol: VaultStyle.fileSymbol(file.type), kind: .document, favorite: file.favorite) }
        return subjects + collections + files
    }
    private var selectedNodeID: UUID? {
        allNodes.contains(where: { $0.id == selectedID }) ? selectedID : nil
    }
    private var edges: [KnowledgeEdge] {
        var result = workspace.data.relationships.map { KnowledgeEdge(id: $0.id.uuidString, source: $0.source, target: $0.target, membership: false) }
        if showMembership {
            for subject in workspace.data.subjects {
                result += subject.fileIDs.map { KnowledgeEdge(id: "\(subject.id)-\($0)", source: subject.id, target: $0, membership: true) }
            }
            for file in store.library.files {
                result += file.collectionIDs.map { KnowledgeEdge(id: "\(file.id)-\($0)", source: file.id, target: $0, membership: true) }
            }
        }
        return result
    }
    private func neighbors(_ id: UUID?) -> Set<UUID> {
        guard let id else { return [] }
        return Set(edges.filter { $0.source == id || $0.target == id }.flatMap { [$0.source, $0.target] })
    }
    private var nodes: [KnowledgeNode] {
        let related = neighbors(selectedNodeID).union(selectedNodeID.map { [$0] } ?? [])
        let filtered = allNodes.filter { node in
            (node.kind != .subject || showSubjects) && (node.kind != .collection || showCollections) &&
            (query.isEmpty || node.title.localizedCaseInsensitiveContains(query)) && (!focusMode || related.contains(node.id))
        }
        // Selected node and its connections get priority before applying the rendering budget.
        return Array(filtered.sorted { a, b in
            let aPriority = a.id == selectedID ? 0 : related.contains(a.id) ? 1 : 2
            let bPriority = b.id == selectedID ? 0 : related.contains(b.id) ? 1 : 2
            return aPriority == bPriority ? a.id.uuidString < b.id.uuidString : aPriority < bPriority
        }.prefix(150))
    }
    var body: some View {
        VStack(spacing: 0) {
            controls.padding(.horizontal, 18).padding(.vertical, 12)
            Divider().opacity(0.5)
            if store.library.files.isEmpty && workspace.data.subjects.isEmpty && store.library.collections.isEmpty {
                ContentUnavailableView {
                    Label("A space for your connections", systemImage: "point.3.connected.trianglepath.dotted")
                } description: { Text("Add files, link them to subjects, and build your own constellation of ideas.") } actions: {
                    Button("Add Files…", action: store.chooseFiles)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background { ObservatoryBackground() }
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
        .onAppear { positions = workspace.data.graphPositions ?? [:]; loaded = true; fit() }
        .onChange(of: nodes.map(\.id)) { _, _ in seed() }
        .onChange(of: selectedID) { _, _ in
            pulseTask?.cancel()
            guard selectedNodeID != nil else { pulse = false; focusMode = false; return }
            pulseStarted = .now; pulse = !reducedMotion
            pulseTask = Task { try? await Task.sleep(for: .seconds(1.8)); if !Task.isCancelled { pulse = false } }
            if focusMode { fit() }
        }
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
            Button { focusMode = false; query = ""; fit() } label: { Label("Overview", systemImage: "arrow.up.left.and.arrow.down.right") }.help("Fit the visible network")
            Toggle(isOn: $focusMode) { Label("Focus", systemImage: "scope") }.toggleStyle(.button).disabled(selectedNodeID == nil)
                .onChange(of: focusMode) { _, _ in fit() }
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
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !pulse || reducedMotion || scenePhase != .active)) { timeline in
                    Canvas { context, _ in
                        let visibleIDs = Set(visible.map(\.id))
                        for edge in edges where visibleIDs.contains(edge.source) && visibleIDs.contains(edge.target) {
                            guard let a = positions[edge.source], let b = positions[edge.target] else { continue }
                            let start = screen(a), end = screen(b)
                            let active = edge.source == (hoveredID ?? selectedNodeID) || edge.target == (hoveredID ?? selectedNodeID)
                            let curve = edgePath(start, end)
                            let color = edge.membership ? VaultStyle.teal : VaultStyle.lavender
                            context.stroke(curve, with: .color(active ? color.opacity(0.8) : Color.primary.opacity(contrast == .increased ? 0.35 : 0.13)), style: StrokeStyle(lineWidth: active ? 1.4 : 0.8, dash: edge.membership && !active ? [3, 5] : []))
                            if active && pulse && !reducedMotion {
                                let t = min(1, timeline.date.timeIntervalSince(pulseStarted) / 1.8)
                                let point = bezierPoint(start, end, t: edge.target == (hoveredID ?? selectedNodeID) ? 1 - t : t)
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
                            .onTapGesture(count: 2) { activate(node.id); if let file = store.library.files.first(where: { $0.id == node.id }) { store.open(file) } }
                            .onTapGesture(count: 1) { activate(node.id) }
                            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("spatialScene")).onChanged { value in
                                positions[node.id] = camera.world(SpatialPoint(x: value.location.x, y: value.location.y), width: viewport.width, height: viewport.height)
                            }.onEnded { _ in savePositions() })
                            .contextMenu { nodeActions(node) }
                            .focusable()
                            .onKeyPress(.return) { activate(node.id); return .handled }
                            .onKeyPress(.space) { activate(node.id); focusMode = true; fit(); return .handled }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(node.title), \(node.kind.rawValue)")
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
            .onAppear { viewport = geometry.size; if loaded { fit() } }
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { legend; Spacer(); Text("\(nodes.count) visible · \(allNodes.count) total").font(.caption2).foregroundStyle(.secondary); Text(focusMode ? "FOCUS" : "FREE EXPLORE").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(VaultStyle.teal) }
            HStack { legend; Spacer(); Text("\(nodes.count) / \(allNodes.count)").font(.caption2) }
        }.help("Up to 150 matching nodes are rendered. Search or Focus narrows the network. Drag to pan; pinch to zoom.")
    }
    private var legend: some View {
        HStack(spacing: 12) {
            Label("Files", systemImage: "doc.text").foregroundStyle(VaultStyle.lavender)
            Label("Subjects", systemImage: "sparkle").foregroundStyle(VaultStyle.teal)
            Label("Collections", systemImage: "square.stack").foregroundStyle(VaultStyle.amber)
        }.font(.system(size: 10))
    }
    @ViewBuilder private func nodeActions(_ node: KnowledgeNode) -> some View {
        Button("Focus Connections") { activate(node.id); focusMode = true; fit() }
        Button("Expand to Overview") { focusMode = false; query = ""; fit() }
        if let file = store.library.files.first(where: { $0.id == node.id }) {
            Divider(); Button("Open in Default App") { store.open(file) }
            Button("Reveal in Finder") { store.reveal(file) }
            Button("Create Relationship…") { activate(node.id); linkTarget = nil; linking = true }
            Button(file.favorite ? "Remove Favorite" : "Favorite") { var next = file; next.favorite.toggle(); store.update(next) }
        }
    }
    private var relationshipEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect documents").font(.title3.bold())
            Text(allNodes.first { $0.id == selectedID }?.title ?? "Selected file").foregroundStyle(.secondary)
            Picker("Related file", selection: $linkTarget) {
                Text("Choose a document").tag(nil as UUID?)
                ForEach(store.library.files.filter { $0.id != selectedID }) { Text($0.filename).tag(Optional($0.id)) }
            }
            Text("This relationship stays in Vault. Neither file is moved or modified.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Cancel") { linking = false }; Spacer(); Button("Create Connection") {
                if let selectedID, let linkTarget { workspace.change { $0.link(selectedID, linkTarget, label: "Related") } }
                linking = false
            }.disabled(linkTarget == nil || selectedID == nil) }
        }.padding(24).frame(width: 440)
    }
    private func activate(_ id: UUID) { selectedID = id; select(id) }
    private func seed() {
        guard loaded else { return }
        let next = SpatialLayout.extending(positions, ids: nodes.map(\.id))
        if next != positions { positions = next; savePositions() }
    }
    private func savePositions() { workspace.change { $0.graphPositions = positions } }
    private func fit() {
        seed()
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
            .scaleEffect(hovered ? 1.035 : 1)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .help("\(title) · \(subtitle)")
    }
}
