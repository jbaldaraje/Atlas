import Foundation
import Combine
import VaultCore

struct CatalogRevision: Equatable, Sendable {
    let library: UUID
    let workspace: UUID
}
struct CatalogRequest: Equatable, Sendable {
    let dataset: String
    let revision: CatalogRevision
    let query: CatalogQuery
}
struct CatalogSource: Sendable {
    let id: String
    let revision: UUID
    let files: [FileItem]
}
actor CatalogBrowserEngine {
    private struct Cached { let revision: CatalogRevision; let index: CatalogIndex }
    private var caches: [String: Cached] = [:]
    private(set) var buildCount = 0
    func page(_ request: CatalogRequest, snapshot: CatalogSnapshot) throws -> CatalogPage {
        try Task.checkCancellation()
        if caches[request.dataset]?.revision != request.revision {
            let index = try CatalogIndex(snapshot)
            try Task.checkCancellation()
            // Keep only a few independent datasets (library / storage / one duplicate group).
            if caches.count >= 4, caches[request.dataset] == nil { caches = caches.filter { $0.key == "library" } }
            caches[request.dataset] = Cached(revision: request.revision, index: index); buildCount += 1
        }
        guard let cached = caches[request.dataset] else { throw CocoaError(.coderInvalidValue) }
        let page = try cached.index.page(request.query)
        try Task.checkCancellation()
        return page
    }
}
@MainActor
final class FolderBrowserModel: ObservableObject {
    @Published private(set) var page = CatalogPage()
    @Published private(set) var ready = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var applied: CatalogRequest?
    private var token = UUID()
    func load(_ request: CatalogRequest, snapshot: CatalogSnapshot, engine: CatalogBrowserEngine) async {
        guard applied != request else { return }
        let current = UUID(); token = current; loading = true; error = nil
        defer { if token == current { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(120))
            let next = try await engine.page(request, snapshot: snapshot)
            try Task.checkCancellation()
            guard token == current else { return }
            page = next; ready = true; applied = request
        } catch is CancellationError {} catch {
            guard token == current else { return }
            self.error = "This folder view could not be prepared. Navigate back and try again. Your files and metadata are preserved."
        }
    }
}
