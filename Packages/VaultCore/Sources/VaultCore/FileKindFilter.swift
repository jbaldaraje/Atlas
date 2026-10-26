import Foundation

/// A presentation filter over existing metadata; never changes approved scan categories.
public enum FileKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all, documents, media, photos
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "All Types"
        case .documents: "Docs"
        case .media: "Media"
        case .photos: "Photos"
        }
    }
    public var detail: String {
        switch self {
        case .all: "Show all file types, including archives and other indexed files."
        case .documents: "PDFs, text and Word documents, presentations, spreadsheets, and data files."
        case .media: "Audio and video files."
        case .photos: "Photos, images, diagrams, and graphics."
        }
    }
    public func includes(fileExtension: String) -> Bool {
        if self == .all { return true }
        return includes(category: ScanFileCategory.classify(fileExtension: fileExtension))
    }
    public func includes(category: ScanFileCategory) -> Bool {
        switch self {
        case .all: return true
        case .documents: return category == .documents || category == .pdf || category == .presentations || category == .data
        case .media: return category == .media
        case .photos: return category == .images
        }
    }
}
