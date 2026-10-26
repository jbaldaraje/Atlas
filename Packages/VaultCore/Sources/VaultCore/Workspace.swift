import Foundation

public struct Subject: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var description = ""
    public var fileIDs: Set<UUID> = []
    public var deadline: Date?
    public init(name: String) { self.name = name }
}
public struct Relationship: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var source: UUID
    public var target: UUID
    public var label: String
    public init(source: UUID, target: UUID, label: String) { self.source = source; self.target = target; self.label = label }
}
public struct StudySession: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var subjectID: UUID
    public var date: Date
    public var minutes: Int
    public var note: String
    public init(subjectID: UUID, date: Date = .now, minutes: Int, note: String) { self.subjectID = subjectID; self.date = date; self.minutes = minutes; self.note = note }
}
public struct ScanLocation: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var bookmark: Data
    public var paused = false
    public var excludes: [String] = []
    public var extractContent = false
    public init(name: String, bookmark: Data) { self.name = name; self.bookmark = bookmark }
}
public struct DeletionRecord: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var file: FileItem
    public var deletedAt = Date()
    public var trashBookmark: Data
    public var originalBookmark: Data
    public init(file: FileItem, trashBookmark: Data, originalBookmark: Data) { self.file = file; self.trashBookmark = trashBookmark; self.originalBookmark = originalBookmark }
}
public struct Workspace: Codable, Equatable, Sendable {
    public var subjects: [Subject] = []
    public var relationships: [Relationship] = []
    public var sessions: [StudySession] = []
    public var locations: [ScanLocation] = []
    public var deletions: [DeletionRecord] = []
    public var graphPositions: [UUID: SpatialPoint]? = nil
    public var openedFiles: [UUID: Date]? = nil
    public var extractedText: [UUID: String] = [:]
    public init() {}
    public mutating func link(_ a: UUID, _ b: UUID, label: String) {
        guard a != b, !relationships.contains(where: { ($0.source == a && $0.target == b) || ($0.source == b && $0.target == a) }) else { return }
        relationships.append(Relationship(source: a, target: b, label: label))
    }
    public mutating func reconcile(validIDs: Set<UUID>, additionalGraphIDs: Set<UUID> = []) {
        relationships.removeAll { !validIDs.contains($0.source) || !validIDs.contains($0.target) }
        for i in subjects.indices { subjects[i].fileIDs.formIntersection(validIDs) }
        let graphIDs = validIDs.union(subjects.map(\.id)).union(additionalGraphIDs)
        graphPositions = graphPositions?.filter { graphIDs.contains($0.key) }
        openedFiles = openedFiles?.filter { validIDs.contains($0.key) }
        extractedText = extractedText.filter { validIDs.contains($0.key) }
    }
}
