import Foundation
import VaultCore

actor NotesSnapshotService {
    private let root: URL
    init(root: URL) { self.root = root.appendingPathComponent("AppleNotes", isDirectory: true) }
    func write(_ snapshot: ImportedNoteSnapshot, id: UUID, existing: FileItem?) throws -> FileItem {
        let data = Data(snapshot.text.utf8)
        if let existing {
            let same = try FileAccessService.withAccess(existing) { url -> Bool in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard Int64(values.fileSize ?? -1) == existing.size, values.contentModificationDate == existing.modifiedAt else { throw SnapshotError.edited }
                return try Data(contentsOf: url) == data && existing.noteSource?.title == snapshot.source.title
            }
            if same { var refreshed = existing; refreshed.noteSource = snapshot.source; return refreshed }
        }
        let directory = root.appendingPathComponent(id.uuidString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ImportedNoteRules.filename(title: snapshot.source.title))
        do {
            try data.write(to: url, options: .atomic)
            guard try Data(contentsOf: url) == data else { throw CocoaError(.fileWriteUnknown) }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            var file = existing ?? FileItem(id: id, filename: url.lastPathComponent, type: "txt", bookmark: bookmark, originalLocation: url.path, ownership: .managedCopy, size: Int64(data.count))
            file.filename = url.lastPathComponent; file.type = "txt"; file.bookmark = bookmark
            file.originalLocation = url.path; file.ownership = .managedCopy; file.size = Int64(values.fileSize ?? data.count)
            file.createdAt = values.creationDate; file.modifiedAt = values.contentModificationDate
            file.fileIdentity = FileAccessService.identity(at: url); file.noteSource = snapshot.source
            return file
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    /// Only after catalog persistence, remove the superseded app-owned snapshot if no other catalog entry references it.
    func discardSuperseded(_ old: FileItem, replacedBy file: FileItem) throws {
        guard old.originalLocation != file.originalLocation else { return }
        let oldURL = URL(fileURLWithPath: old.originalLocation)
        guard oldURL.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { return }
        try FileManager.default.removeItem(at: oldURL)
    }
    enum SnapshotError: LocalizedError {
        case edited
        var errorDescription: String? { "This local note snapshot was edited outside Vault. Refresh was stopped to preserve those edits. Keep or export your local copy before replacing it." }
    }
}
