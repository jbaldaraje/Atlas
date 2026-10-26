import Foundation

public struct Subject: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var description = ""
    public var fileIDs: Set<UUID> = []
    public var deadline: Date?
    public var organizationKey: String? = nil
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
/// Mutually exclusive scan groups. PDFs are separate from other documents.
public enum ScanFileCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case documents, pdf, presentations, data, images, media, archives, other
    public var id: String { rawValue }
    public static var all: Set<ScanFileCategory> { Set(allCases) }
    public var title: String {
        switch self {
        case .documents: "Documents"
        case .pdf: "PDFs"
        case .presentations: "Presentations"
        case .data: "Spreadsheets & data"
        case .archives: "Archives"
        case .images: "Images"
        case .media: "Media"
        case .other: "Other"
        }
    }
    public var symbol: String {
        switch self {
        case .documents: "doc.text"
        case .pdf: "doc.richtext"
        case .presentations: "rectangle.on.rectangle"
        case .data: "tablecells"
        case .archives: "archivebox"
        case .images: "photo"
        case .media: "play.rectangle"
        case .other: "archivebox"
        }
    }
    public var detail: String {
        switch self {
        case .documents: "Word, Pages, text, and research documents. PDFs can also be selected independently."
        case .presentations: "PowerPoint, Keynote, and other presentations."
        case .data: "Spreadsheets, CSV, JSON, and similar data files."
        case .archives: "ZIP, TAR, compressed archives, and disk images."
        case .pdf: "PDF documents only."
        case .images: "Photos, graphics, and supported image file types."
        case .media: "Video and audio files."
        case .other: "Executables and file types outside the other categories; catalog metadata only when preview or extraction is unsupported."
        }
    }
    public static func classify(fileExtension: String) -> ScanFileCategory {
        let normalized = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch normalized {
        case "pdf": return .pdf
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "avif", "svg", "ico", "psd", "raw", "cr2", "dng": return .images
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpeg", "mpg", "wmv", "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "wma": return .media
        case "ppt", "pptx", "odp", "key": return .presentations
        case "xls", "xlsx", "ods", "numbers", "csv", "tsv", "json", "xml", "yaml", "yml", "parquet", "sqlite", "db": return .data
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "iso": return .archives
        case "doc", "docx", "odt", "pages", "txt", "md", "markdown", "rtf", "rtfd", "tex", "epub", "html", "htm": return .documents
        default: return .other
        }
    }
}

public struct ScanLocation: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var bookmark: Data
    public var paused = false
    public var excludes: [String] = []
    public var extractContent = false
    /// Missing in older libraries means all types; an explicit empty set means none.
    public var includedCategories: Set<ScanFileCategory>? = nil
    public var categoryVersion: Int? = nil
    public var sourcePath: String? = nil
    public var sourceIdentity: String? = nil
    public var includePhotoLocations: Bool? = nil
    public var fileCategories: Set<ScanFileCategory> {
        guard var categories = includedCategories else { return ScanFileCategory.all }
        if categoryVersion == nil {
            if categories.contains(.documents) { categories.formUnion([.presentations, .data]) }
            if categories.contains(.other) { categories.insert(.archives) }
        }
        return categories
    }
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
    public var organizationFacts: [UUID: OrganizationFacts]? = nil
    public var lastScan: ScanJob? = nil
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
        organizationFacts = organizationFacts?.filter { validIDs.contains($0.key) }
        openedFiles = openedFiles?.filter { validIDs.contains($0.key) }
        extractedText = extractedText.filter { validIDs.contains($0.key) }
    }
}
