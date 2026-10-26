import Foundation

public struct OrganizationFacts: Codable, Equatable, Sendable {
    public var fileID: UUID
    public var size: Int64
    public var modifiedAt: Date?
    public var filename: String
    public var category: ScanFileCategory
    public var folderContext: String
    public var captureDate: String?
    public var captureMonth: String?
    public var gpsArea: String?
    public var topics: [String: String] = [:]
    public var textStatus = "Not requested"
    public var reviewReasons: [String] = []
    public var textRequested = false
    public var locationsRequested = false
    public var inputTags: [String] = []
    public var changeSignature: String? = nil
    public var generatedGroupIDs: Set<UUID>? = nil
    public var generatedSubjectIDs: Set<UUID>? = nil
    public init(file: FileItem, folderContext: String) {
        changeSignature = file.changeSignature
        fileID = file.id; size = file.size; modifiedAt = file.modifiedAt; filename = file.filename
        category = ScanFileCategory.classify(fileExtension: file.type); self.folderContext = folderContext
    }
}
public enum ScanStage: String, Codable, Sendable {
    case counting, enumerating, indexing, organizing, duplicates, completed, cancelled, interrupted, failed
    public var isRunning: Bool { [.counting, .enumerating, .indexing, .organizing, .duplicates].contains(self) }
    public var title: String {
        switch self {
        case .counting: "Counting matching files"
        case .enumerating: "Discovering approved files"
        case .indexing: "Updating your catalog"
        case .organizing: "Connecting your ideas"
        case .duplicates: "Reviewing possible duplicates"
        case .completed: "Scan complete"
        case .cancelled: "Scan cancelled"
        case .interrupted: "Scan interrupted"
        case .failed: "Scan needs attention"
        }
    }
}

/// Measured work, not elapsed time. Counting has no percentage until its denominator is known.
/// The first 95% covers indexing + organization; the last 5% covers catalog duplicate review.
public struct ScanWorkProgress: Codable, Equatable, Sendable {
    public var countedEntries = 0
    public var totalFiles = 0
    public var countingComplete = false
    public var indexedFiles = 0
    public var organizedFiles = 0
    public var duplicateChecks = 0
    public var duplicateTotal = 0
    public init() {}

    public func fraction(stage: ScanStage) -> Double? {
        if stage == .completed { return 1 }
        guard countingComplete else { return nil }
        let fileWork = Double(max(0, indexedFiles)) + Double(max(0, organizedFiles))
        let fileTotal = Double(max(0, totalFiles)) * 2
        let files = fileTotal > 0 ? min(1, fileWork / fileTotal) : 0
        let review = duplicateTotal > 0 ? min(1, Double(max(0, duplicateChecks)) / Double(duplicateTotal)) : 0
        return min(0.99, max(0, files * 0.95 + review * 0.05))
    }
}
public struct ScanJob: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var startedAt = Date()
    public var stage: ScanStage = .enumerating
    public var sources: [ScanLocation]
    public var discovered = 0
    public var processed = 0
    public var skipped = 0
    public var errors: [String] = []
    public var addedIDs: Set<UUID> = []
    public var catalogIDs: Set<UUID> = []
    public var subjectIDs: Set<UUID> = []
    public var groupIDs: Set<UUID> = []
    public var relationshipCount = 0
    public var photoDateGroups = 0
    public var photoLocationGroups = 0
    public var possibleDuplicateGroups: Int?
    public var reviewIDs: Set<UUID> = []
    /// Optional so saved jobs from earlier releases still decode.
    public var progress: ScanWorkProgress?
    public var paused: Bool? = nil
    public init(sources: [ScanLocation]) { self.sources = sources }
    public var fractionCompleted: Double? {
        if stage == .completed { return 1 }
        return progress?.fraction(stage: stage)
    }
    public var percentCompleted: Int? { fractionCompleted.map { min(stage == .completed ? 100 : 99, Int(($0 * 100).rounded(.down))) } }
}
public struct OrganizationCounts: Sendable {
    public init() {}
    public var subjectIDs: Set<UUID> = []
    public var collectionIDs: Set<UUID> = []
    public var relationshipCount = 0
    public var dateGroups: Set<UUID> = []
    public var locationGroups: Set<UUID> = []
    public var reviewIDs: Set<UUID> = []
}

public enum OrganizationRules {
    private static let rules: [(String, Set<String>)] = [
        ("Biology", ["biology", "genetics", "cells", "ecology", "organism"]),
        ("Physics", ["physics", "quantum", "mechanics", "thermodynamics"]),
        ("Mathematics", ["mathematics", "calculus", "algebra", "geometry", "statistics"]),
        ("History", ["history", "historical", "archaeology", "civilization"]),
        ("Computer Science", ["programming", "algorithm", "software", "computing", "neural"]),
        ("Finance", ["finance", "budget", "invoice", "accounting", "investment"]),
        ("Design", ["design", "typography", "wireframe", "branding"])
    ]
    public static func gpsArea(latitude: Double, longitude: Double, latitudeRef: String, longitudeRef: String) -> String? {
        guard latitude.isFinite, longitude.isFinite, (0...90).contains(latitude), (0...180).contains(longitude),
              ["N", "S"].contains(latitudeRef.uppercased()), ["E", "W"].contains(longitudeRef.uppercased()) else { return nil }
        return String(format: "%.2f°%@, %.2f°%@ (approx.)", locale: Locale(identifier: "en_US_POSIX"), latitude, latitudeRef.uppercased(), longitude, longitudeRef.uppercased())
    }
    public static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    public static func topics(filename: String, context: String, tags: [String], text: String?, existing: [String]) -> [String: String] {
        let metadata = tokens(filename + " " + context + " " + tags.joined(separator: " "))
        let content = tokens(text ?? "")
        var result: [String: String] = [:]
        for (name, keywords) in rules {
            let direct = keywords.intersection(metadata).sorted()
            let extracted = keywords.intersection(content).sorted()
            if !direct.isEmpty { result[name] = "Filename, folder, or tag contains: " + direct.joined(separator: ", ") }
            else if extracted.count >= 2 { result[name] = "Extracted text contains: " + extracted.joined(separator: ", ") }
        }
        for name in existing where !name.isEmpty {
            let words = tokens(name)
            if !words.isEmpty && words.isSubset(of: metadata) { result[name] = "Existing subject name matches filename, folder, or tags." }
        }
        return result
    }
    /// Add virtual memberships only. Existing filenames, descriptions, tags, and manual links are preserved.
    public static func apply(_ facts: [OrganizationFacts], library: inout Library, workspace: inout Workspace) -> OrganizationCounts {
        var counts = OrganizationCounts()
        var collectionIndex = Dictionary(library.collections.enumerated().compactMap { i, c in c.organizationKey.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        var subjectIndex = Dictionary(workspace.subjects.enumerated().map { ($0.element.name.lowercased(), $0.offset) }, uniquingKeysWith: { a, _ in a })
        let fileIndex = Dictionary(library.files.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var createdCollections: Set<UUID> = []
        func collection(key: String, name: String) -> UUID {
            if let i = collectionIndex[key] { return library.collections[i].id }
            var group = FileCollection(name: name); group.organizationKey = key
            collectionIndex[key] = library.collections.count; library.collections.append(group); createdCollections.insert(group.id)
            return group.id
        }
        var storedFacts = workspace.organizationFacts ?? [:]
        for fact in facts {
            guard let index = fileIndex[fact.fileID] else { continue }
            let originalGroups = library.files[index].collectionIDs
            let previous = storedFacts[fact.fileID]
            library.files[index].collectionIDs.subtract(previous?.generatedGroupIDs ?? [])
            for i in workspace.subjects.indices where previous?.generatedSubjectIDs?.contains(workspace.subjects[i].id) == true {
                workspace.subjects[i].fileIDs.remove(fact.fileID)
            }
            var savedFact = fact
            var ownedSubjects: Set<UUID> = []
            var groups: Set<UUID> = [collection(key: "type:" + fact.category.rawValue, name: "Type · " + fact.category.title)]
            if !fact.folderContext.isEmpty { groups.insert(collection(key: "folder:" + fact.folderContext, name: "Folder · " + URL(fileURLWithPath: fact.folderContext).lastPathComponent)) }
            if let month = fact.captureMonth {
                let year = String(month.prefix(4))
                let yearID = collection(key: "photo-year:" + year, name: "Photos · " + year)
                groups.insert(yearID); counts.dateGroups.insert(yearID)
                let id = collection(key: "photo-month:" + month, name: "Photos · " + month)
                groups.insert(id); counts.dateGroups.insert(id)
            }
            if let area = fact.gpsArea {
                let id = collection(key: "photo-gps:" + area, name: "GPS area · " + area)
                groups.insert(id); counts.locationGroups.insert(id)
            }
            for tag in library.files[index].tags {
                groups.insert(collection(key: "tag:" + tag.lowercased(), name: "Tag · " + tag))
            }
            if !fact.reviewReasons.isEmpty {
                groups.insert(collection(key: "needs-review", name: "Needs Review")); counts.reviewIDs.insert(fact.fileID)
            }
            let oldGroups = library.files[index].collectionIDs
            library.files[index].collectionIDs.formUnion(groups)
            counts.relationshipCount += groups.subtracting(originalGroups).count
            savedFact.generatedGroupIDs = groups.subtracting(oldGroups)
            counts.collectionIDs.formUnion(groups)
            for name in fact.topics.keys.sorted() {
                let subject: Int
                if let existing = subjectIndex[name.lowercased()] { subject = existing }
                else {
                    var created = Subject(name: name); created.organizationKey = "topic:" + name.lowercased()
                    created.description = "Rule-based topic. Review the file's organization evidence; memberships remain editable."
                    subject = workspace.subjects.count; subjectIndex[name.lowercased()] = subject; workspace.subjects.append(created)
                }
                let id = workspace.subjects[subject].id
                if workspace.subjects[subject].fileIDs.insert(fact.fileID).inserted {
                    ownedSubjects.insert(id)
                    if previous?.generatedSubjectIDs?.contains(id) != true { counts.relationshipCount += 1 }
                }
                counts.subjectIDs.insert(id)

            }
            savedFact.generatedSubjectIDs = ownedSubjects
            storedFacts[fact.fileID] = savedFact
        }
        workspace.organizationFacts = storedFacts
        counts.dateGroups.formIntersection(createdCollections)
        counts.locationGroups.formIntersection(createdCollections)
        return counts
    }
}
