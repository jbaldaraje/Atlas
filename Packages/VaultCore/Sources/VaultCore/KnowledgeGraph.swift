import Foundation

public enum GraphNodeKind: Equatable, Sendable { case document, subject, collection }
public struct GraphNode: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let subtitle: String
    public let type: String
    public let isNote: Bool
    public let kind: GraphNodeKind
    public let favorite: Bool
}
public struct GraphEdge: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: UUID
    public let target: UUID
    public let membership: Bool
}
public struct GraphQuery: Equatable, Sendable {
    public var text = ""
    public var selectedID: UUID?
    public var subjects = true
    public var collections = true
    public var membership = true
    public var focus = false
    public var page = 0
    public var kind = FileKindFilter.all
    public var originID: UUID?
    public init() {}
}
public struct GraphProjection: Sendable {
    public static let nodeBudget = 150
    public static let edgeBudget = 900
    public var nodes: [GraphNode] = []
    public var edges: [GraphEdge] = []
    public var total = 0
    public var matching = 0
    public var page = 0
    public var edgesTruncated = false
    public var selectedExists = false
    public var contextOutsideFilter = false
    public var activePathEdgeIDs: Set<String> = []
    public init() {}
    public var pageCount: Int { max(1, (matching + Self.nodeBudget - 1) / Self.nodeBudget) }
}

/// Build once per graph revision, never in a render callback. No previews or file access.
/// Source order is stable; interleaving kinds makes the first page useful without sorting the catalog.
public struct KnowledgeGraphIndex: Sendable {
    private var nodes: [GraphNode] = []
    private var byID: [UUID: Int] = [:]
    private var edges: [GraphEdge] = []
    private var adjacency: [UUID: [Int]] = [:]
    private var files: [UUID: FileItem] = [:]
    private var subjectNames: [UUID: String] = [:]
    private var collectionInfo: [UUID: FileCollection] = [:]
    private var tags: [String: [UUID]] = [:]
    private var relationshipLabels: [String: String] = [:]

    public init(library: Library, subjects: [Subject], relationships: [Relationship]) throws {
        relationshipLabels = Dictionary(relationships.map { ($0.id.uuidString, $0.label) }, uniquingKeysWith: { a, _ in a })
        files = Dictionary(library.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        subjectNames = Dictionary(subjects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        collectionInfo = Dictionary(library.collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for file in library.files {
            try Task.checkCancellation()
            for tag in Set(file.tags.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }) where !tag.isEmpty { tags[tag, default: []].append(file.id) }
        }
        var subjectIndex = 0, collectionIndex = 0, fileIndex = 0
        func append(_ node: GraphNode) {
            guard byID[node.id] == nil else { return }
            byID[node.id] = nodes.count; nodes.append(node)
        }
        nodes.reserveCapacity(library.files.count + library.collections.count + subjects.count)
        while subjectIndex < subjects.count || collectionIndex < library.collections.count || fileIndex < library.files.count {
            try Task.checkCancellation()
            if subjectIndex < subjects.count {
                let subject = subjects[subjectIndex]; subjectIndex += 1
                append(GraphNode(id: subject.id, title: subject.name, subtitle: "SUBJECT · \(subject.fileIDs.count) FILES", type: "", isNote: false, kind: .subject, favorite: false))
            }
            if collectionIndex < library.collections.count {
                let collection = library.collections[collectionIndex]; collectionIndex += 1
                append(GraphNode(id: collection.id, title: collection.name, subtitle: "COLLECTION", type: "", isNote: false, kind: .collection, favorite: false))
            }
            for _ in 0..<3 where fileIndex < library.files.count {
                let file = library.files[fileIndex]; fileIndex += 1
                append(GraphNode(id: file.id, title: file.filename, subtitle: file.noteSource == nil ? file.type.uppercased() : "APPLE NOTE", type: file.type, isNote: file.noteSource != nil, kind: .document, favorite: file.favorite))
            }
        }
        func connect(id: String, source: UUID, target: UUID, membership: Bool) throws {
            try Task.checkCancellation()
            guard source != target, byID[source] != nil, byID[target] != nil else { return }
            let index = edges.count
            edges.append(GraphEdge(id: id, source: source, target: target, membership: membership))
            adjacency[source, default: []].append(index); adjacency[target, default: []].append(index)
        }
        for link in relationships { try connect(id: link.id.uuidString, source: link.source, target: link.target, membership: false) }
        for subject in subjects {
            for id in subject.fileIDs { try connect(id: "s:\(subject.id):\(id)", source: subject.id, target: id, membership: true) }
        }
        for file in library.files {
            try Task.checkCancellation()
            for id in file.collectionIDs { try connect(id: "c:\(file.id):\(id)", source: file.id, target: id, membership: true) }
        }
    }

    public func project(_ query: GraphQuery) throws -> GraphProjection {
        try Task.checkCancellation()
        var allowed: Set<UUID>?
        var matchingSubjectCounts: [UUID: Int] = [:]
        if query.kind != .all {
            var documents = Set<UUID>()
            for node in nodes {
                try Task.checkCancellation()
                if node.kind == .document && query.kind.includes(fileExtension: node.type) { documents.insert(node.id) }
            }
            var relevant = documents
            for edge in edges {
                try Task.checkCancellation()
                if documents.contains(edge.source), let index = byID[edge.target], nodes[index].kind != .document {
                    relevant.insert(edge.target)
                    if edge.membership && nodes[index].kind == .subject { matchingSubjectCounts[edge.target, default: 0] += 1 }
                }
                if documents.contains(edge.target), let index = byID[edge.source], nodes[index].kind != .document {
                    relevant.insert(edge.source)
                    if edge.membership && nodes[index].kind == .subject { matchingSubjectCounts[edge.source, default: 0] += 1 }
                }
            }
            allowed = relevant
        }
        var related = Set<UUID>()
        if let selected = query.selectedID, byID[selected] != nil {
            related.insert(selected)
            for index in adjacency[selected] ?? [] {
                try Task.checkCancellation()
                let edge = edges[index]
                if query.membership || !edge.membership { related.insert(edge.source); related.insert(edge.target) }
            }
        }
        if query.membership, let selected = query.selectedID {
            var secondary = Set<UUID>()
            for index in adjacency[selected] ?? [] {
                let edge = edges[index], parent = edge.source == selected ? edge.target : edge.source
                guard edge.membership, isMeaningfulParent(parent) else { continue }
                for next in adjacency[parent] ?? [] {
                    try Task.checkCancellation()
                    let other = edges[next].source == parent ? edges[next].target : edges[next].source
                    if files[other] != nil { secondary.insert(other) }
                }
            }
            related.formUnion(secondary.sorted { $0.uuidString < $1.uuidString }.prefix(80))
        }
        if let origin = query.originID, byID[origin] != nil { related.insert(origin) }
        if allowed != nil {
            if let selected = query.selectedID, byID[selected] != nil { allowed?.insert(selected) }
            if let origin = query.originID, byID[origin] != nil { allowed?.insert(origin) }
        }
        var selected: [Int] = [], origin: [Int] = [], neighbors: [Int] = [], others: [Int] = []
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (index, node) in nodes.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            if let allowed, !allowed.contains(node.id) { continue }
            guard (node.kind != .subject || query.subjects), (node.kind != .collection || query.collections),
                  (text.isEmpty || node.title.localizedCaseInsensitiveContains(text)), (!query.focus || related.contains(node.id)) else { continue }
            if node.id == query.selectedID { selected.append(index) }
            else if node.id == query.originID { origin.append(index) }
            else if related.contains(node.id) { neighbors.append(index) }
            else { others.append(index) }
        }
        let matches = selected + origin + neighbors + others
        var result = GraphProjection(); result.total = nodes.count; result.matching = matches.count
        result.selectedExists = query.selectedID.map { byID[$0] != nil } ?? false
        result.contextOutsideFilter = [query.selectedID, query.originID].compactMap { $0 }.contains { id in files[id].map { !query.kind.includes(fileExtension: $0.type) } ?? false }
        result.activePathEdgeIDs = navigationPath(from: query.originID, to: query.selectedID)
        result.page = min(max(0, query.page), result.pageCount - 1)
        let start = result.page * GraphProjection.nodeBudget
        result.nodes = matches.dropFirst(start).prefix(GraphProjection.nodeBudget).map {
            let node = nodes[$0]
            guard query.kind != .all, node.kind == .subject else { return node }
            return GraphNode(id: node.id, title: node.title, subtitle: "SUBJECT · \(matchingSubjectCounts[node.id] ?? 0) MATCHING FILES", type: node.type, isNote: node.isNote, kind: node.kind, favorite: node.favorite)
        }
        let visible = Set(result.nodes.map(\.id))
        var visited = Set<Int>()
        for node in result.nodes {
            for index in adjacency[node.id] ?? [] {
                try Task.checkCancellation()
                let edge = edges[index]
                guard (query.membership || !edge.membership), visible.contains(edge.source), visible.contains(edge.target) else { continue }
                guard visited.insert(index).inserted else { continue }
                if result.edges.count == GraphProjection.edgeBudget { result.edgesTruncated = true; return result }
                result.edges.append(edge)
            }
        }
        return result
    }
    private func isMeaningfulParent(_ id: UUID) -> Bool {
        if subjectNames[id] != nil { return true }
        guard let collection = collectionInfo[id] else { return false }
        guard let key = collection.organizationKey else { return true }
        return key.hasPrefix("photo-") || key.hasPrefix("tag:")
    }
    private func navigationPath(from origin: UUID?, to selected: UUID?) -> Set<String> {
        guard let origin, let selected, origin != selected else { return [] }
        var result = Set<String>()
        let originEdges = adjacency[origin] ?? [], targetEdges = adjacency[selected] ?? []
        var parents: [UUID: String] = [:]
        for index in originEdges {
            let edge = edges[index], other = edge.source == origin ? edge.target : edge.source
            if other == selected { result.insert(edge.id) }
            if edge.membership && isMeaningfulParent(other) { parents[other] = edge.id }
        }
        for index in targetEdges {
            let edge = edges[index], other = edge.source == selected ? edge.target : edge.source
            if edge.membership, let first = parents[other] { result.insert(first); result.insert(edge.id) }
        }
        return result
    }
    public var fileIDs: Set<UUID> { Set(files.keys) }
    public func file(id: UUID) -> FileItem? { files[id] }
    public func titles(for ids: [UUID]) -> [UUID: String] {
        Dictionary(ids.compactMap { id in
            if let index = byID[id] { return (id, nodes[index].title) }
            return relationshipLabels[id.uuidString].map { (id, "Relationship · " + $0) }
        }, uniquingKeysWith: { a, _ in a })
    }
    public func connections(for id: UUID, kind: FileKindFilter, page: Int, facts: [UUID: OrganizationFacts], textMatches: [UUID: [String]] = [:], dismissed: Set<DiscoveryPair> = []) throws -> ConnectedDocumentsPage {
        guard let source = files[id] else { return ConnectedDocumentsPage(documents: [], total: 0, page: 0) }
        var reasons: [UUID: [String: ConnectionEvidence]] = [:]
        func add(_ target: UUID, _ reason: ConnectionEvidence) {
            guard target != id, let file = files[target], kind.includes(fileExtension: file.type) else { return }
            reasons[target, default: [:]][reason.id] = reason
        }
        for index in adjacency[id] ?? [] {
            try Task.checkCancellation()
            let edge = edges[index], other = edge.source == id ? edge.target : edge.source
            if !edge.membership, files[other] != nil {
                let label = edge.id
                add(other, ConnectionEvidence(id: label, kind: .explicitLink, label: "User connection", detail: edgeLabel(id: edge.id), contextID: UUID(uuidString: edge.id)))
            }
            guard edge.membership, isMeaningfulParent(other) else { continue }
            for next in adjacency[other] ?? [] {
                try Task.checkCancellation()
                let linked = edges[next], target = linked.source == other ? linked.target : linked.source
                guard linked.membership, files[target] != nil else { continue }
                if let name = subjectNames[other] {
                    let inferred = facts[id]?.generatedSubjectIDs?.contains(other) == true && facts[target]?.generatedSubjectIDs?.contains(other) == true
                    let evidence = facts[id]?.topics[name]
                    add(target, ConnectionEvidence(id: "subject:\(other)", kind: .sharedSubject, label: "Shared subject · " + name,
                        detail: inferred ? "Editable organization suggestion. " + (evidence ?? "Stored subject membership.") : "Both files are linked to this subject.", contextID: other, suggested: inferred))
                } else if let collection = collectionInfo[other] {
                    let key = collection.organizationKey ?? ""
                    if key.hasPrefix("tag:") { continue }
                    let sourceFact = facts[id], targetFact = facts[target]
                    let photo: Bool
                    if key.hasPrefix("photo-month:"), let month = sourceFact?.captureMonth {
                        photo = month == targetFact?.captureMonth && key == "photo-month:" + month
                    } else if key.hasPrefix("photo-year:"), let a = sourceFact?.captureMonth, let b = targetFact?.captureMonth {
                        photo = a.prefix(4) == b.prefix(4) && key == "photo-year:" + String(a.prefix(4))
                    } else if key.hasPrefix("photo-gps:"), let area = sourceFact?.gpsArea {
                        photo = area == targetFact?.gpsArea && key == "photo-gps:" + area
                    } else { photo = false }
                    add(target, ConnectionEvidence(id: "collection:\(other)", kind: photo ? .photoMetadata : .sharedCollection,
                        label: (photo ? "Recorded photo group · " : "Same collection · ") + collection.name,
                        detail: photo ? "Shared stored capture-date or approximate GPS group; no place was inferred." : "Both files belong to this virtual collection.", contextID: other))
                }
            }
        }
        for tag in Set(source.tags) {
            let key = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            for target in tags[key] ?? [] {
                try Task.checkCancellation()
                add(target, ConnectionEvidence(id: "tag:" + key, kind: .sharedTag, label: "Shared tag · " + tag, detail: "This tag is stored on both files."))
            }
        }
        for (target, terms) in textMatches where Set(terms).count >= 3 && !dismissed.contains(DiscoveryPair(id, target)) {
            try Task.checkCancellation()
            add(target, ConnectionEvidence(id: "text", kind: .indexedTerms, label: "\(terms.count) shared indexed terms", detail: "Suggested from the first 12,000 indexed characters: " + terms.prefix(6).joined(separator: ", "), suggested: true, sharedTermCount: terms.count))
        }
        func rank(_ kind: ExplorationReason) -> Int {
            switch kind { case .explicitLink: 0; case .sharedSubject: 1; case .sharedTag: 2; case .sharedCollection: 3; case .photoMetadata: 4; default: 5 }
        }
        let candidates = reasons.compactMap { target, values -> ConnectedDocument? in
            guard let file = files[target] else { return nil }
            let evidence = values.values.sorted { rank($0.kind) == rank($1.kind) ? $0.id < $1.id : rank($0.kind) < rank($1.kind) }
            return ConnectedDocument(file: file, evidence: evidence)
        }.sorted { a, b in
            let left = rank(a.primaryReason), right = rank(b.primaryReason)
            if left != right { return left < right }
            if a.evidence.count != b.evidence.count { return a.evidence.count > b.evidence.count }
            let order = a.file.filename.localizedStandardCompare(b.file.filename)
            return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
        let maxPage = max(0, (candidates.count - 1) / ConnectedDocumentsPage.capacity), page = min(max(0, page), maxPage)
        return ConnectedDocumentsPage(documents: Array(candidates.dropFirst(page * ConnectedDocumentsPage.capacity).prefix(ConnectedDocumentsPage.capacity)), total: candidates.count, page: page)
    }
    private func edgeLabel(id: String) -> String { relationshipLabels[id] ?? "Explicit relationship stored by the user." }

}
