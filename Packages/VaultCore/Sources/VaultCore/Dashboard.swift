import Foundation

public enum DashboardWidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case notes, documents, photos, media, recent, favorites, exploring, storage
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .notes: "My Notes"
        case .documents: "My Documents"
        case .photos: "My Photos"
        case .media: "My Media"
        case .recent: "Recently Accessed"
        case .favorites: "Favorites & Pinned"
        case .exploring: "Continue Exploring"
        case .storage: "Storage Snapshot"
        }
    }
    public var symbol: String {
        switch self {
        case .notes: "note.text"
        case .documents: "doc.text"
        case .photos: "photo"
        case .media: "play.rectangle"
        case .recent: "clock"
        case .favorites: "pin"
        case .exploring: "point.3.connected.trianglepath.dotted"
        case .storage: "internaldrive"
        }
    }
}
public enum DashboardWidgetSize: String, Codable, CaseIterable, Sendable { case compact, expanded }
public enum DashboardPriority: String, Codable, CaseIterable, Sendable { case recent, favorites }
public struct DashboardWidgetConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: DashboardWidgetKind { kind }
    public let kind: DashboardWidgetKind
    public var visible: Bool
    public var size: DashboardWidgetSize
    public var priority: DashboardPriority
    public init(kind: DashboardWidgetKind, visible: Bool, size: DashboardWidgetSize = .compact, priority: DashboardPriority = .recent) {
        self.kind = kind; self.visible = visible; self.size = size; self.priority = priority
    }
    public var itemLimit: Int { size == .compact ? 3 : 6 }
}
public struct DashboardLayout: Codable, Equatable, Sendable {
    public var widgets: [DashboardWidgetConfiguration]
    public init(widgets: [DashboardWidgetConfiguration] = DashboardLayout.defaults) { self.widgets = widgets }
    public static var defaults: [DashboardWidgetConfiguration] {
        [.init(kind: .notes, visible: true, priority: .favorites), .init(kind: .documents, visible: true),
         .init(kind: .favorites, visible: true), .init(kind: .photos, visible: false, size: .expanded),
         .init(kind: .media, visible: false), .init(kind: .recent, visible: false),
         .init(kind: .exploring, visible: false), .init(kind: .storage, visible: false)]
    }
    public mutating func normalize() {
        var seen = Set<DashboardWidgetKind>()
        widgets = widgets.filter { seen.insert($0.kind).inserted }
        for kind in DashboardWidgetKind.allCases where !seen.contains(kind) { widgets.append(.init(kind: kind, visible: false)) }
    }
    public mutating func move(_ kind: DashboardWidgetKind, before target: DashboardWidgetKind) {
        guard kind != target, let source = widgets.firstIndex(where: { $0.kind == kind }) else { return }
        let item = widgets.remove(at: source)
        let destination = widgets.firstIndex { $0.kind == target } ?? widgets.endIndex
        widgets.insert(item, at: destination)
    }
}
public struct WorkspacePreferences: Codable, Equatable, Sendable {
    public var dashboard = DashboardLayout()
    public var history = ExplorationHistory()
    public var dismissedTextConnections: Set<DiscoveryPair> = []
    public var pinnedCollections: Set<UUID> = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case dashboard, history, dismissedTextConnections, pinnedCollections }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dashboard = try c.decodeIfPresent(DashboardLayout.self, forKey: .dashboard) ?? DashboardLayout(); dashboard.normalize()
        history = try c.decodeIfPresent(ExplorationHistory.self, forKey: .history) ?? ExplorationHistory()
        dismissedTextConnections = try c.decodeIfPresent(Set<DiscoveryPair>.self, forKey: .dismissedTextConnections) ?? []
        pinnedCollections = try c.decodeIfPresent(Set<UUID>.self, forKey: .pinnedCollections) ?? []
    }
}
public struct DashboardFile: Identifiable, Sendable {
    public var id: UUID { file.id }
    public let file: FileItem
    public let date: Date
    public let dateLabel: String
    public var excerpt: String
    public let photoMetadata: String?
}
public struct DashboardTrailItem: Identifiable, Sendable {
    public var id: UUID { step.itemID }
    public let step: ExplorationStep
    public let title: String
}
public struct DashboardStorage: Sendable {
    public let indexedLogicalBytes: Int64
    public let managedLogicalBytes: Int64
}
public struct DashboardSnapshot: Sendable {
    public var files: [DashboardWidgetKind: [DashboardFile]] = [:]
    public var collections: [FileCollection] = []
    public var trail: [DashboardTrailItem] = []
    public var storage: DashboardStorage?
    public init() {}
    public static func build(library: Library, subjects: [Subject], opened: [UUID: Date], facts: [UUID: OrganizationFacts], text: [UUID: String], preferences: WorkspacePreferences) throws -> DashboardSnapshot {
        var result = DashboardSnapshot()
        let visible = preferences.dashboard.widgets.filter(\.visible)
        let kinds = Set(visible.map(\.kind))
        var storageSeen = Set<String>(), managedSeen = Set<String>(), indexed: Int64 = 0, managed: Int64 = 0
        // Small top-k buffers: never sort or publish the entire catalog for a widget.
        for file in library.files {
            try Task.checkCancellation()
            if kinds.contains(.storage) {
                let identity = file.fileIdentity ?? file.originalLocation
                if storageSeen.insert(identity).inserted { indexed += max(0, file.size) }
                if file.ownership == .managedCopy, managedSeen.insert(identity).inserted { managed += max(0, file.size) }
            }
            let category = ScanFileCategory.classify(fileExtension: file.type)
            for config in visible {
                let kind = config.kind
                let eligible: Bool
                switch kind {
                case .notes: eligible = file.noteSource != nil
                case .documents: eligible = file.noteSource == nil && FileKindFilter.documents.includes(category: category)
                case .photos: eligible = category == .images
                case .media: eligible = category == .media
                case .recent: eligible = opened[file.id] != nil
                case .favorites: eligible = file.favorite
                default: eligible = false
                }
                guard eligible else { continue }
                let date: Date, label: String
                if kind == .recent { date = opened[file.id] ?? file.indexedAt; label = "Opened through Vault" }
                else if kind == .notes, let modified = file.noteSource?.sourceModifiedAt ?? file.modifiedAt { date = modified; label = "Modified" }
                else if kind == .documents, let opened = opened[file.id], opened > file.indexedAt { date = opened; label = "Opened" }
                else { date = file.indexedAt; label = "Added to Vault" }
                let sourceText = text[file.id].map { String($0.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                let excerpt = file.description.isEmpty ? sourceText : String(file.description.prefix(180))
                let metadata = [facts[file.id]?.captureDate.map { "EXIF · " + $0 }, facts[file.id]?.gpsArea].compactMap { $0 }.joined(separator: " · ")
                let row = DashboardFile(file: file, date: date, dateLabel: label, excerpt: excerpt, photoMetadata: metadata.isEmpty ? nil : metadata)
                var rows = result.files[kind] ?? []
                rows.append(row)
                rows.sort { a, b in
                    if config.priority == .favorites, a.file.favorite != b.file.favorite { return a.file.favorite }
                    return a.date == b.date ? a.id.uuidString < b.id.uuidString : a.date > b.date
                }
                result.files[kind] = Array(rows.prefix(config.itemLimit))
            }
        }
        if kinds.contains(.storage) { result.storage = DashboardStorage(indexedLogicalBytes: indexed, managedLogicalBytes: managed) }
        if let config = visible.first(where: { $0.kind == .favorites }) {
            result.collections = Array(library.collections.filter { preferences.pinnedCollections.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(config.itemLimit))
        }
        if let config = visible.first(where: { $0.kind == .exploring }) {
            var titles = Dictionary(library.files.map { ($0.id, $0.filename) }, uniquingKeysWith: { a, _ in a })
            for subject in subjects { titles[subject.id] = subject.name }
            for collection in library.collections { titles[collection.id] = collection.name }
            var seen = Set<UUID>()
            result.trail = preferences.history.steps.prefix(max(0, min(preferences.history.cursor + 1, preferences.history.steps.count))).reversed().compactMap { step in
                guard let title = titles[step.itemID], seen.insert(step.itemID).inserted else { return nil }
                return DashboardTrailItem(step: step, title: title)
            }.prefix(config.itemLimit).map { $0 }
        }
        return result
    }
}
