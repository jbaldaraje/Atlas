import Foundation
import Combine
import VaultCore

struct DashboardRequest: Equatable, Sendable {
    let revision: CatalogRevision
    let activity: UUID
    let layout: DashboardLayout
    let pins: Set<UUID>
    let history: ExplorationHistory
    let analysisID: UUID?
}
struct DashboardAnalysisSummary: Sendable {
    let allocated: Int64
    let files: Int
    let duplicateGroups: Int
}
struct PreparedDashboard: Sendable {
    var snapshot: DashboardSnapshot
    let analysis: DashboardAnalysisSummary?
}
extension CatalogBrowserEngine {
    func dashboard(_ request: DashboardRequest, library: Library, workspace: Workspace, preferences: WorkspacePreferences, report: StorageReport?) throws -> PreparedDashboard {
        if dashboardRequest == request, let dashboardResult { return dashboardResult }
        let snapshot = try DashboardSnapshot.build(library: library, subjects: workspace.subjects, opened: workspace.openedFiles ?? [:], facts: workspace.organizationFacts ?? [:], text: workspace.extractedText, preferences: preferences)
        try Task.checkCancellation()
        let analysis: DashboardAnalysisSummary?
        if request.layout.widgets.contains(where: { $0.kind == .storage && $0.visible }), let report {
            analysis = DashboardAnalysisSummary(allocated: report.allocatedBytes, files: report.files.count, duplicateGroups: report.duplicates.count)
        } else { analysis = nil }
        let result = PreparedDashboard(snapshot: snapshot, analysis: analysis)
        dashboardRequest = request; dashboardResult = result
        return result
    }
}
@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var result: PreparedDashboard?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var applied: DashboardRequest?
    private var token = UUID()
    private var excerpts: [String: String] = [:]
    func load(_ request: DashboardRequest, library: LibraryStore, workspace: WorkspaceStore, preferences: WorkspacePreferencesStore) async {
        guard applied != request else { return }
        let current = UUID(); token = current; loading = true; error = nil
        defer { if token == current { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(120))
            var next = try await library.catalogBrowser.dashboard(request, library: library.library, workspace: workspace.data, preferences: preferences.data, report: workspace.report)
            if var notes = next.snapshot.files[.notes] {
                for index in notes.indices where notes[index].excerpt.isEmpty {
                    try Task.checkCancellation()
                    let file = notes[index].file
                    let key = "\(file.id)-\(file.size)-\(file.noteSource?.importedAt.timeIntervalSinceReferenceDate ?? 0)"
                    if let cached = excerpts[key] { notes[index].excerpt = cached }
                    else if let excerpt = await library.noteExcerpt(file) {
                        if excerpts.count >= 64 { excerpts.removeAll(keepingCapacity: true) }
                        excerpts[key] = excerpt; notes[index].excerpt = excerpt
                    }
                }
                next.snapshot.files[.notes] = notes
            }
            try Task.checkCancellation(); guard token == current else { return }
            result = next; applied = request
        } catch is CancellationError {} catch {
            guard token == current else { return }
            self.error = "Dashboard content could not be prepared. Your library and widget preferences are preserved."
        }
    }
}
