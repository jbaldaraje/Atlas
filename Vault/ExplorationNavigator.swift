import SwiftUI
import VaultCore

struct ExplorationHop {
    let target: UUID
    let source: UUID?
    let reason: ExplorationReason
    init(_ target: UUID, source: UUID? = nil, reason: ExplorationReason = .selected) { self.target = target; self.source = source; self.reason = reason }
}
@MainActor
final class ExplorationNavigator: ObservableObject {
    @Published private(set) var history = ExplorationHistory()
    func restore(_ history: ExplorationHistory) { self.history = history }
    func visit(_ step: ExplorationStep) { history.visit(step) }
    func jump(_ index: Int) -> ExplorationStep? { history.jump(to: index) }
    func reconcile(validIDs: Set<UUID>) {
        var next = history; next.reconcile(validIDs: validIDs)
        if next != history { history = next }
    }
}
struct WorkspaceRouting {
    var inspect: ((ExplorationHop) -> Void)?
    var restore: ((Int) -> Void)?
    var preview: ((UUID, String?) -> Void)?
    var showMap: ((UUID) -> Void)?
    var browseSubject: ((UUID) -> Void)?
    var browseCollection: ((UUID) -> Void)?
    var browseFiles: ((FileKindFilter, Bool) -> Void)?
    var browseNotes: ((UUID?) -> Void)?
    var browseStorage: (() -> Void)?
    var browsePinnedCollections: (() -> Void)?
    var searchFiles: ((String) -> Void)?
    var addNotes: (() -> Void)?
    var record: ((UUID, ExplorationReason) -> Void)?
}
private struct WorkspaceRoutingKey: EnvironmentKey { static let defaultValue = WorkspaceRouting() }
extension EnvironmentValues {
    var workspaceRouting: WorkspaceRouting {
        get { self[WorkspaceRoutingKey.self] }
        set { self[WorkspaceRoutingKey.self] = newValue }
    }
}
/// Per-window navigation state only; the catalog and original files remain in their existing stores.
@MainActor
final class BrowsingSessionStore: ObservableObject {
    struct Position { let path: [CatalogGroup]; let page: Int }
    private var positions: [String: Position] = [:]
    func load(_ key: String) -> Position? { positions[key] }
    func save(_ key: String, path: [CatalogGroup], page: Int) {
        if positions.count >= 32, positions[key] == nil, let old = positions.keys.first { positions.removeValue(forKey: old) }
        positions[key] = Position(path: path, page: page)
    }
    func reset(section: CatalogSection) { positions = positions.filter { !$0.key.hasPrefix(section.rawValue + ":") } }
}
