import Foundation
import VaultCore

struct SelectionContext: Sendable {
    let id: UUID
    var file: FileItem?
    var subject: VaultCore.Subject?
    var collection: FileCollection?
    var relationship: Relationship?
    var endpoints: [FileItem] = []
    var sessionCount = 0
    var studyMinutes = 0
}
struct SelectionRequest: Equatable, Sendable { let id: UUID?; let revision: GraphRevision; let metadata: UUID }
extension KnowledgeGraphEngine {
    func selection(_ request: SelectionRequest, library: Library, workspace: Workspace) throws -> SelectionContext? {
        guard let id = request.id else { return nil }
        try ensureIndex(revision: request.revision, library: library, subjects: workspace.subjects, relationships: workspace.relationships)
        var result = SelectionContext(id: id)
        result.file = graphIndex?.file(id: id)
        if result.file == nil {
            result.subject = workspace.subjects.first { $0.id == id }
            result.collection = library.collections.first { $0.id == id }
            result.relationship = workspace.relationships.first { $0.id == id }
            if let edge = result.relationship { result.endpoints = [edge.source, edge.target].compactMap { graphIndex?.file(id: $0) } }
            if result.subject != nil {
                let sessions = workspace.sessions.filter { $0.subjectID == id }
                result.sessionCount = sessions.count; result.studyMinutes = sessions.reduce(0) { $0 + $1.minutes }
            }
        }
        try Task.checkCancellation(); return result
    }
    func file(id: UUID, revision: GraphRevision, library: Library, workspace: Workspace) throws -> FileItem? {
        try ensureIndex(revision: revision, library: library, subjects: workspace.subjects, relationships: workspace.relationships)
        return graphIndex?.file(id: id)
    }
}
struct DocumentPreviewRequest {
    let file: FileItem
    let term: String?
}
