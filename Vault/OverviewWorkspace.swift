import SwiftUI
import VaultCore

struct OverviewWorkspace: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var notes: AppleNotesStore
    let select: (UUID) -> Void
    let openMap: () -> Void
    let openSubjects: () -> Void
    let openCollections: () -> Void
    let addNotes: () -> Void
    @State private var showLocations = false
    @State private var showActivity = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("A little space for a clearer mind.").font(.system(size: 23, weight: .medium, design: .rounded))
                    Text("Pick up a thread, or discover a new connection.").font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 10)
                HStack {
                    Button(action: workspace.approveFolder) { Label("Scan Folders", systemImage: "folder.badge.plus") }
                        .buttonStyle(CinematicButtonStyle(prominent: true)).disabled(workspace.working || store.busy || notes.working)
                    Button(action: addNotes) { Label("Add Notes", systemImage: "note.text") }.disabled(workspace.working || store.busy || notes.working)
                    if let scan = workspace.data.lastScan {
                        Button("Last Scan · \(scan.addedIDs.count) added") { workspace.showScanResults() }.font(.caption)
                    }
                    Spacer()
                }
                networkEntry
                Button { showActivity = true } label: { Label("Recent activity", systemImage: "folder.badge.clock") }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your parent folders").font(.headline)
                    FolderBrowser(section: .files, listMode: true, select: select, sessionID: "overview.parents").frame(height: 330)
                }
                HStack(spacing: 12) {
                    Button(action: openSubjects) { space("Subjects", subtitle: "Browse matching subject groups", symbol: "books.vertical", color: VaultStyle.teal) }.buttonStyle(.plain)
                    Button(action: openCollections) { space("Collections", subtitle: "Browse matching collections", symbol: "square.stack", color: VaultStyle.amber) }.buttonStyle(.plain)
                }
                DashboardWidgets(openMap: openMap, select: select)
                DisclosureGroup("Approved locations", isExpanded: $showLocations) { MonitoringWorkspace().padding(.top, 14) }.font(.callout)
                Label("Only the files and folders you approve. Everything stays on your Mac.", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }.background { ObservatoryBackground(grid: false) }
            .sheet(isPresented: $showActivity) { OverviewActivity(select: select) }
    }
    private var networkEntry: some View {
        Button(action: openMap) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("KNOWLEDGE MAP", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(VaultStyle.lavender)
                    Text("Follow the connections.").font(.system(size: 20, weight: .medium, design: .rounded))
                    Text(store.library.files.isEmpty ? "Your map begins with your first file." : "\(store.library.files.count) indexed files in your library.").font(.caption).foregroundStyle(.secondary)
                    Label("Explore your map", systemImage: "arrow.up.right").font(.caption.weight(.medium)).foregroundStyle(VaultStyle.lavender)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                miniNetwork.frame(width: 200, height: 190).allowsHitTesting(false)
            }.frame(maxWidth: .infinity, alignment: .leading).quietPanel().contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Explore Knowledge Map, \(store.library.files.count) indexed files")
    }
    private var miniNetwork: some View {
        Canvas { context, size in
            let ids = Array(workspace.data.subjects.prefix(6).map(\.id)) + Array(store.library.collections.prefix(6).map(\.id))
            let layout = SpatialLayout.extending([:], ids: ids)
            var camera = GraphCamera(); camera.fit(Array(layout.values), width: size.width, height: size.height)
            func point(_ id: UUID) -> CGPoint? {
                guard let p = layout[id] else { return nil }; let s = camera.screen(p, width: size.width, height: size.height); return CGPoint(x: s.x, y: s.y)
            }
            for id in ids {
                if let p = point(id) {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(VaultStyle.lavender.opacity(0.6)))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(VaultStyle.lavender))
                }
            }
        }.accessibilityHidden(true)
    }
    private func space(_ name: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) { Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(15).quietPanel()
    }
}
