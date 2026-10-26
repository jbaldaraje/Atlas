import Foundation
import Combine
import VaultCore

struct GraphRevision: Equatable, Sendable {
    let library: UUID
    let workspace: UUID
}
struct GraphRequest: Equatable, Sendable {
    let revision: GraphRevision
    let query: GraphQuery
}
struct PreparedGraph: Sendable {
    let projection: GraphProjection
    let positions: [UUID: SpatialPoint]
}

/// The index and layout work run on this actor, away from the UI executor.
/// The actor is retained across navigation; scan counters, hover, and camera changes do not rebuild it.
actor KnowledgeGraphEngine {
    private var revision: GraphRevision?
    var graphIndex: KnowledgeGraphIndex?
    var contentIndex: ContentEvidenceIndex?
    var contentRevision: UUID?
    private var positions: [UUID: SpatialPoint] = [:]
    private var positionsLoaded = false
    private let layoutURL: URL
    private(set) var buildCount = 0
    init(base: URL) { layoutURL = base.appendingPathComponent("graph-layout.json") }

    func prepare(request: GraphRequest, library: Library, subjects: [VaultCore.Subject], relationships: [Relationship], legacyPositions: [UUID: SpatialPoint], previousPositions: [UUID: SpatialPoint] = [:]) throws -> PreparedGraph {
        try Task.checkCancellation()
        try ensureIndex(revision: request.revision, library: library, subjects: subjects, relationships: relationships)
        if !positionsLoaded {
            if FileManager.default.fileExists(atPath: layoutURL.path) {
                // A corrupt layout must not be silently replaced. The catalog remains usable.
                positions = try JSONDecoder().decode([UUID: SpatialPoint].self, from: Data(contentsOf: layoutURL))
            } else { positions = legacyPositions }
            positionsLoaded = true
        }
        guard let index = graphIndex else { throw CocoaError(.coderInvalidValue) }
        let projection = try index.project(request.query)
        var visiblePositions: [UUID: SpatialPoint] = [:]
        for node in projection.nodes {
            if let point = previousPositions[node.id] ?? positions[node.id], point.x.isFinite, point.y.isFinite { visiblePositions[node.id] = point }
        }
        // Only visible nodes participate in layout/collision checks, even with a huge saved layout.
        visiblePositions = SpatialLayout.extending(visiblePositions, ids: projection.nodes.map(\.id))
        try Task.checkCancellation()
        return PreparedGraph(projection: projection, positions: visiblePositions)
    }
    func ensureIndex(revision requested: GraphRevision, library: Library, subjects: [VaultCore.Subject], relationships: [Relationship]) throws {
        try Task.checkCancellation()
        if revision != requested || graphIndex == nil {
            let next = try KnowledgeGraphIndex(library: library, subjects: subjects, relationships: relationships)
            try Task.checkCancellation()
            graphIndex = next; revision = requested; buildCount += 1
            contentIndex = nil; contentRevision = nil
        }
    }
    func move(_ id: UUID, to point: SpatialPoint) throws {
        guard point.x.isFinite, point.y.isFinite else { return }
        positions[id] = point
        try FileManager.default.createDirectory(at: layoutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(positions).write(to: layoutURL, options: .atomic)
    }
}

@MainActor
final class KnowledgeMapModel: ObservableObject {
    @Published private(set) var projection = GraphProjection()
    @Published private(set) var positions: [UUID: SpatialPoint] = [:]
    @Published private(set) var loading = false
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    @Published private(set) var generation = UUID()
    @Published private(set) var applied: GraphRequest?
    private var engine: KnowledgeGraphEngine
    private var token = UUID()
    private var completedRequest: GraphRequest?
    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Vault", isDirectory: true)) {
        engine = KnowledgeGraphEngine(base: base)
    }
    func load(_ request: GraphRequest, library: Library, subjects: [VaultCore.Subject], relationships: [Relationship], legacyPositions: [UUID: SpatialPoint], sharedEngine: KnowledgeGraphEngine? = nil) async {
        if let sharedEngine { engine = sharedEngine }
        guard completedRequest != request else { return }
        let current = UUID(); token = current; loading = true; error = nil
        defer { if token == current { loading = false } }
        do {
            // Coalesce typing, selection, and rapid catalog changes during a large scan.
            try await Task.sleep(for: .milliseconds(120))
            let prepared = try await engine.prepare(request: request, library: library, subjects: subjects, relationships: relationships, legacyPositions: legacyPositions, previousPositions: positions)
            try Task.checkCancellation()
            guard token == current else { return }
            projection = prepared.projection; positions = prepared.positions
            completedRequest = request; applied = request; ready = true; generation = UUID()
        } catch is CancellationError {} catch {
            guard token == current else { return }
            self.error = "The map could not be prepared. Retry; your files and relationships are preserved. If the saved layout is unreadable, preserve graph-layout.json for recovery."
        }
    }
    func move(_ id: UUID, to point: SpatialPoint) {
        positions[id] = point
        Task {
            do { try await engine.move(id, to: point) }
            catch { self.error = "The node position could not be saved. Your files and relationships are unchanged." }
        }
    }
    func retry() { completedRequest = nil }
}
