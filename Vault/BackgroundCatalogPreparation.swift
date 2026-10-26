import Foundation
import VaultCore

struct PreparedOrganization: Sendable {
    let library: Library
    let workspace: Workspace
    let counts: OrganizationCounts
    let libraryBytes: Data
    let workspaceBytes: Data
}

/// Pure transformation/encoding. Actual publication remains one uninterrupted main-actor transaction.
enum BackgroundCatalogPreparation {
    static func organization(_ facts: [OrganizationFacts], texts: [UUID: String], library: Library, workspace: Workspace) async throws -> PreparedOrganization {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var library = library, workspace = workspace
            let counts = OrganizationRules.apply(facts, library: &library, workspace: &workspace)
            workspace.reconcile(validIDs: Set(library.files.map(\.id)), additionalGraphIDs: Set(library.collections.map(\.id)))
            for (id, text) in texts { workspace.extractedText[id] = text }
            try Task.checkCancellation()
            let libraryBytes = try JSONEncoder().encode(library), workspaceBytes = try JSONEncoder().encode(workspace)
            try Task.checkCancellation()
            return PreparedOrganization(library: library, workspace: workspace, counts: counts, libraryBytes: libraryBytes, workspaceBytes: workspaceBytes)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
