import Foundation
import Combine
import VaultCore

actor WorkspacePreferencesWriter {
    private let url: URL
    init(base: URL) { url = base.appendingPathComponent("workspace-preferences.json") }
    func save(_ preferences: WorkspacePreferences) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
    }
}
@MainActor
final class WorkspacePreferencesStore: ObservableObject {
    @Published private(set) var data = WorkspacePreferences()
    @Published var error: String?
    private let writer: WorkspacePreferencesWriter
    private var writable = true
    var canWrite: Bool { writable }
    private var pending: Task<Void, Never>?
    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Vault", isDirectory: true)) {
        writer = WorkspacePreferencesWriter(base: base)
        let url = base.appendingPathComponent("workspace-preferences.json")
        do { if FileManager.default.fileExists(atPath: url.path) { data = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(contentsOf: url)) } }
        catch { writable = false; self.error = "Dashboard and exploration preferences could not be read. The saved file was preserved; writes are disabled until it is repaired." }
    }
    func change(_ body: (inout WorkspacePreferences) -> Void) {
        guard writable else { return }
        var next = data; body(&next); next.dashboard.normalize()
        guard next != data else { return }
        data = next; pending?.cancel()
        // Small preferences only. No catalog, extracted text, paths, secrets, or thumbnails are saved here.
        let writer = writer
        pending = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                try await writer.save(next); self?.error = nil
            } catch is CancellationError {} catch { self?.error = "Dashboard or exploration preferences could not be saved. Retry your change before quitting." }
        }
    }
    func setWidget(_ kind: DashboardWidgetKind, update: (inout DashboardWidgetConfiguration) -> Void) {
        change { data in guard let index = data.dashboard.widgets.firstIndex(where: { $0.kind == kind }) else { return }; update(&data.dashboard.widgets[index]) }
    }
    func moveWidget(_ kind: DashboardWidgetKind, before target: DashboardWidgetKind) { change { $0.dashboard.move(kind, before: target) } }
    func moveWidgets(from indices: IndexSet, to destination: Int) {
        change { data in
            let original = data.dashboard.widgets
            let moving = indices.sorted().compactMap { original.indices.contains($0) ? original[$0] : nil }
            var rest = original.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
            let index = max(0, min(rest.count, destination - indices.filter { $0 < destination }.count))
            rest.insert(contentsOf: moving, at: index); data.dashboard.widgets = rest
        }
    }
    func toggleCollectionPin(_ id: UUID) { change { if !$0.pinnedCollections.insert(id).inserted { $0.pinnedCollections.remove(id) } } }
    func dismissTextConnection(_ source: UUID, _ target: UUID) { change { $0.dismissedTextConnections.insert(DiscoveryPair(source, target)) } }
    func flush() async {
        pending?.cancel(); guard writable else { return }
        do { try await writer.save(data); error = nil } catch { self.error = "Preferences could not be saved. The previous file remains available." }
    }
}
