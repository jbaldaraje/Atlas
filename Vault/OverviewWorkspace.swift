import SwiftUI
import VaultCore

struct OverviewWorkspace: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    let select: (UUID) -> Void
    let openMap: () -> Void
    let openCollection: (UUID) -> Void
    @State private var showLocations = false
    private var recentlyOpened: [FileItem] {
        store.library.files.filter { workspace.data.openedFiles?[$0.id] != nil }.sorted {
            (workspace.data.openedFiles?[$0.id] ?? .distantPast) > (workspace.data.openedFiles?[$1.id] ?? .distantPast)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("A little space for a clearer mind.").font(.system(size: 23, weight: .medium, design: .rounded))
                    Text("Pick up a thread, or discover a new connection.").font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 10)
                HStack {
                    Button(action: workspace.approveFolder) { Label("Scan Folders", systemImage: "folder.badge.plus") }
                        .buttonStyle(CinematicButtonStyle(prominent: true)).disabled(workspace.working || store.busy)
                    if let scan = workspace.data.lastScan {
                        Button("Last Scan · \(scan.addedIDs.count) added") { workspace.showScanResults() }.font(.caption)
                    }
                    Spacer()
                }
                networkEntry
                if let file = recentlyOpened.first {
                    HStack(spacing: 16) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(VaultStyle.teal)
                        VStack(alignment: .leading, spacing: 4) { Text("CONTINUE WHERE YOU LEFT OFF").font(.system(size: 9, weight: .medium)).tracking(1.3).foregroundStyle(.secondary); Text(file.filename).font(.headline).lineLimit(1) }
                        Spacer(); Button("Open") { store.open(file) }; Button("Inspect") { select(file.id) }
                    }.padding(18).quietPanel()
                }
                if !recentlyOpened.isEmpty {
                    fileShelf("Recently opened", files: Array(recentlyOpened.prefix(4)))
                }
                if !store.library.files.isEmpty {
                    fileShelf("Recently added", files: Array(store.library.files.sorted { $0.indexedAt > $1.indexedAt }.prefix(4)))
                }
                if !workspace.data.subjects.isEmpty || !store.library.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your spaces").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 10) {
                            ForEach(workspace.data.subjects.prefix(6)) { subject in
                                Button { select(subject.id) } label: { space(subject.name, subtitle: "\(subject.fileIDs.count) linked files", symbol: "sparkle", color: VaultStyle.teal) }.buttonStyle(.plain)
                            }
                            ForEach(store.library.collections.prefix(6)) { collection in
                                Button { openCollection(collection.id) } label: { space(collection.name, subtitle: "Collection", symbol: "square.stack", color: VaultStyle.amber) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                DisclosureGroup("Approved locations", isExpanded: $showLocations) { MonitoringWorkspace().padding(.top, 14) }.font(.callout)
                Label("Only the files and folders you approve. Everything stays on your Mac.", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }.background { ObservatoryBackground(grid: false) }
    }
    private var networkEntry: some View {
        Button(action: openMap) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("KNOWLEDGE MAP", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(VaultStyle.lavender)
                    Text("Follow the connections.").font(.system(size: 20, weight: .medium, design: .rounded))
                    Text(store.library.files.isEmpty ? "Your map begins with your first file." : "\(store.library.files.count) files. Your own constellation.").font(.caption).foregroundStyle(.secondary)
                    Label("Explore your map", systemImage: "arrow.up.right").font(.caption.weight(.medium)).foregroundStyle(VaultStyle.lavender)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                miniNetwork.frame(width: 200, height: 190).allowsHitTesting(false)
            }.frame(maxWidth: .infinity, alignment: .leading).quietPanel().contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Explore Knowledge Map, \(store.library.files.count) indexed files")
    }
    private var miniNetwork: some View {
        Canvas { context, size in
            let ids = Array(store.library.files.prefix(18).map(\.id))
            let layout = SpatialLayout.extending([:], ids: ids)
            var camera = GraphCamera(); camera.fit(Array(layout.values), width: size.width, height: size.height)
            func point(_ id: UUID) -> CGPoint? {
                guard let p = layout[id] else { return nil }; let s = camera.screen(p, width: size.width, height: size.height); return CGPoint(x: s.x, y: s.y)
            }
            for edge in workspace.data.relationships {
                guard let a = point(edge.source), let b = point(edge.target) else { continue }
                context.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(VaultStyle.teal.opacity(0.4)), lineWidth: 0.7)
            }
            for id in ids {
                if let p = point(id) {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(VaultStyle.lavender.opacity(0.6)))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(VaultStyle.lavender))
                }
            }
        }.accessibilityHidden(true)
    }
    private func fileShelf(_ title: String, files: [FileItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                ForEach(files) { file in
                    Button { select(file.id) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            FileThumbnail(file: file).frame(height: 80).frame(maxWidth: .infinity)
                            Text(file.filename).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(file.type.uppercased()).font(.system(size: 9)).tracking(1).foregroundStyle(.secondary)
                        }.padding(14).quietPanel()
                    }.buttonStyle(.plain).contextMenu { Button("Open") { store.open(file) }; Button("Reveal in Finder") { store.reveal(file) } }
                }
            }
        }
    }
    private func space(_ name: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) { Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(15).quietPanel()
    }
}
