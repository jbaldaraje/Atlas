import Foundation
import VaultCore

struct RecoveryEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let file: FileItem
    let date: Date
}
actor RecoveryService {
    private let root: URL
    private let managed: URL
    init(base: URL = URL.applicationSupportDirectory.appendingPathComponent("Vault", isDirectory: true)) {
        root = base.appendingPathComponent("Recovery", isDirectory: true)
        managed = base.appendingPathComponent("Files", isDirectory: true)
    }
    func list() throws -> [RecoveryEntry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { folder in
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("payload").path) else { return nil }
            return try JSONDecoder().decode(RecoveryEntry.self, from: Data(contentsOf: folder.appendingPathComponent("record.json")))
        }.sorted { $0.date > $1.date }
    }
    func retain(_ file: FileItem) throws {
        guard file.ownership == .managedCopy else { throw RecoveryError.notManaged }
        try FileAccessService.withAccess(file) { source in
            guard source.resolvingSymlinksInPath().path.hasPrefix(managed.resolvingSymlinksInPath().path + "/") else { throw RecoveryError.notManaged }
            let attributes = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard attributes.isSymbolicLink != true, attributes.isRegularFile == true else { throw RecoveryError.notManaged }
            let id = UUID(), folder = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let entry = RecoveryEntry(id: id, file: file, date: .now)
            // Durable intent before moving: a restart can discover every retained payload.
            try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent("record.json"), options: .atomic)
            try FileManager.default.moveItem(at: source, to: folder.appendingPathComponent("payload"))
        }
    }
    private func folder(_ id: UUID) throws -> URL {
        guard FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileNoSuchFile) }
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let entry = try JSONDecoder().decode(RecoveryEntry.self, from: Data(contentsOf: folder.appendingPathComponent("record.json")))
            if entry.id == id { return folder }
        }
        throw CocoaError(.fileNoSuchFile)
    }
    func restore(_ entry: RecoveryEntry) throws -> FileItem {
        let folder = try folder(entry.id)
        let destination = URL(fileURLWithPath: entry.file.originalLocation)
        guard destination.resolvingSymlinksInPath().path.hasPrefix(managed.resolvingSymlinksInPath().path + "/") else { throw RecoveryError.notManaged }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RecoveryError.conflict }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("payload"), to: destination)
        guard FileManager.default.contentsEqual(atPath: folder.appendingPathComponent("payload").path, andPath: destination.path) else { throw CocoaError(.fileReadUnknown) }
        var restored = entry.file
        restored.bookmark = try destination.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return restored
    }
    func finish(_ entry: RecoveryEntry) throws { try FileManager.default.removeItem(at: folder(entry.id)) }
    enum RecoveryError: LocalizedError {
        case notManaged, conflict
        var errorDescription: String? { self == .notManaged ? "Only a verified Vault-managed copy can be retained here. Original files are never deleted by this build." : "A file already occupies the restore location. It has not been overwritten." }
    }
}
