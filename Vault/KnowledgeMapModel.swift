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
    private var index: KnowledgeGraphIndex?
    private var positions: [UUID: SpatialPoint] = [:]
    private var previousVisible: [UUID: SpatialPoint] = [:]
    private var positionsLoaded = false
    private let layoutURL: URL
    private(set) var buildCount = 0
    init(base: URL) { layoutURL = base.appendingPathComponent("graph-layout.json") }

    func prepare(request: GraphRequest, library: Library, subjects: [VaultCore.Subject], relationships: [Relationship], legacyPositions: [UUID: SpatialPoint]) throws -> PreparedGraph {
        try Task.checkCancellation()
        if revision != request.revision || index == nil {
            let next = try KnowledgeGraphIndex(library: library, subjects: subjects, relationships: relationships)
            try Task.checkCancellation()
            index = next; revision = request.revision; buildCount += 1
        }
        if !positionsLoaded {
            if FileManager.default.fileExists(atPath: layoutURL.path) {
                // A corrupt layout must not be silently replaced. The catalog remains usable.
                positions = try JSONDecoder().decode([UUID: SpatialPoint].self, from: Data(contentsOf: layoutURL))
            } else { positions = legacyPositions }
            positionsLoaded = true
        }
        guard let index else { throw CocoaError(.coderInvalidValue) }
        let projection = try index.project(request.query)
        var visiblePositions: [UUID: SpatialPoint] = [:]
        for node in projection.nodes {
            if let point = previousVisible[node.id] ?? positions[node.id], point.x.isFinite, point.y.isFinite { visiblePositions[node.id] = point }
        }
        // Only visible nodes participate in layout/collision checks, even with a huge saved layout.
        visiblePositions = SpatialLayout.extending(visiblePositions, ids: projection.nodes.map(\.id))
        try Task.checkCancellation()
        previousVisible = visiblePositions
        return PreparedGraph(projection: projection, positions: visiblePositions)
    }
    func move(_ id: UUID, to point: SpatialPoint) throws {
        guard point.x.isFinite, point.y.isFinite else { return }
        positions[id] = point
        previousVisible[id] = point
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
    private let engine: KnowledgeGraphEngine
    private var token = UUID()
    private var completedRequest: GraphRequest?
    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Vault", isDirectory: true)) {
        engine = KnowledgeGraphEngine(base: base)
    }
    func load(_ request: GraphRequest, library: Library, subjects: [VaultCore.Subject], relationships: [Relationship], legacyPositions: [UUID: SpatialPoint]) async {
        guard completedRequest != request else { return }
        let current = UUID(); token = current; loading = true; error = nil
        defer { if token == current { loading = false } }
        do {
            // Coalesce typing, selection, and rapid catalog changes during a large scan.
            try await Task.sleep(for: .milliseconds(120))
            let prepared = try await engine.prepare(request: request, library: library, subjects: subjects, relationships: relationships, legacyPositions: legacyPositions)
            try Task.checkCancellation()
            guard token == current else { return }
            projection = prepared.projection; positions = prepared.positions
            completedRequest = request; ready = true; generation = UUID()
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
