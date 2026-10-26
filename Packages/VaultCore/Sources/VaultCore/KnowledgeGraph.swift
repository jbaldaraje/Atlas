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

    public init(library: Library, subjects: [Subject], relationships: [Relationship]) throws {
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
        var related = Set<UUID>()
        if let selected = query.selectedID, byID[selected] != nil {
            related.insert(selected)
            for index in adjacency[selected] ?? [] {
                try Task.checkCancellation()
                let edge = edges[index]
                if query.membership || !edge.membership { related.insert(edge.source); related.insert(edge.target) }
            }
        }
        var selected: [Int] = [], neighbors: [Int] = [], others: [Int] = []
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (index, node) in nodes.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard (node.kind != .subject || query.subjects), (node.kind != .collection || query.collections),
                  (text.isEmpty || node.title.localizedCaseInsensitiveContains(text)), (!query.focus || related.contains(node.id)) else { continue }
            if node.id == query.selectedID { selected.append(index) }
            else if related.contains(node.id) { neighbors.append(index) }
            else { others.append(index) }
        }
        let matches = selected + neighbors + others
        var result = GraphProjection(); result.total = nodes.count; result.matching = matches.count
        result.selectedExists = query.selectedID.map { byID[$0] != nil } ?? false
        result.page = min(max(0, query.page), result.pageCount - 1)
        let start = result.page * GraphProjection.nodeBudget
        result.nodes = matches.dropFirst(start).prefix(GraphProjection.nodeBudget).map { nodes[$0] }
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
}
