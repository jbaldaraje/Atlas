import AppKit
import Combine
import VaultCore

struct TrashEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let file: FileItem
    let deletedAt: Date
    let bookmark: Data
}

/// Native Trash operations require a fresh, explicit writable grant for the exact file.
@MainActor
final class NativeTrashService: ObservableObject {
    private(set) var listingRevision = UUID()
    @Published private(set) var entries: [TrashEntry] = [] { didSet { listingRevision = UUID() } }
    @Published var error: String?
    private let root = URL.applicationSupportDirectory.appendingPathComponent("Vault/TrashRecords")
    init() { refresh() }
    func refresh() {
        do {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(TrashEntry.self, from: Data(contentsOf: $0)) }
        } catch { self.error = "Trash records could not be read. Nothing was removed." }
    }
    func trash(_ file: FileItem, library: LibraryStore) {
        guard file.ownership == .original else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "Authorize moving this exact original to macOS Trash: \(file.originalLocation). Other selected files will be rejected."
        panel.directoryURL = URL(fileURLWithPath: file.originalLocation).deletingLastPathComponent()
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let access = selected.startAccessingSecurityScopedResource()
        defer { if access { selected.stopAccessingSecurityScopedResource() } }
        do {
            let path = selected.resolvingSymlinksInPath().path
            let forbidden = ["/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin", "/dev", "/etc", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path]
            guard !selected.pathComponents.contains("Library"), !selected.pathComponents.contains("Applications"), !forbidden.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { throw TrashError.protected }
            let values = try selected.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey, .contentModificationDateKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TrashError.changed }
            try FileAccessService.withAccess(file) { original in
                let old = try original.resourceValues(forKeys: [.fileResourceIdentifierKey])
                guard original.standardizedFileURL == selected.standardizedFileURL,
                      let a = old.fileResourceIdentifier as? NSObject, let b = values.fileResourceIdentifier as? NSObject, a.isEqual(b),
                      Int64(values.fileSize ?? -1) == file.size, values.contentModificationDate == file.modifiedAt else { throw TrashError.changed }
            }
            // Persist readable intent before calling the filesystem. Completion records are separate.
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let id = UUID(), intent = root.appendingPathComponent(id.uuidString + ".intent")
            try JSONEncoder().encode(file).write(to: intent, options: .atomic)
            var result: NSURL?
            try FileManager.default.trashItem(at: selected, resultingItemURL: &result)
            guard let trashURL = result as URL? else { throw TrashError.recordFailed }
            let bookmark = try trashURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let entry = TrashEntry(id: id, file: file, deletedAt: .now, bookmark: bookmark)
            try JSONEncoder().encode(entry).write(to: root.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
            try? FileManager.default.removeItem(at: intent)
            library.removeFromIndex(file.id); refresh()
        } catch { self.error = "Trash operation could not be completed or recorded: \(error.localizedDescription). If the file moved, inspect macOS Trash. Existing index metadata and operation intents are preserved on failure." }
    }
    func restore(_ entry: TrashEntry, library: LibraryStore) {
        do {
            var stale = false
            let source = try URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, FileManager.default.fileExists(atPath: source.path) else { throw TrashError.unavailable }
            let panel = NSSavePanel(); panel.nameFieldStringValue = entry.file.filename
            panel.message = "Choose a new or original location. Vault never overwrites a file during restore."
            panel.directoryURL = URL(fileURLWithPath: entry.file.originalLocation).deletingLastPathComponent()
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw TrashError.changed }
            let sourceAccess = source.startAccessingSecurityScopedResource(), destinationAccess = destination.startAccessingSecurityScopedResource()
            defer { if sourceAccess { source.stopAccessingSecurityScopedResource() }; if destinationAccess { destination.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: destination)
            guard FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path) else { throw TrashError.changed }
            var file = entry.file; file.originalLocation = destination.path
            file.bookmark = try destination.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            guard library.addRestored(file) else { throw TrashError.recordFailed }
            try FileManager.default.removeItem(at: source)
            try FileManager.default.removeItem(at: root.appendingPathComponent(entry.id.uuidString + ".json")); refresh()
        } catch { self.error = "Restore failed: \(error.localizedDescription). Retained data was not overwritten; check the chosen destination before retrying." }
    }
    enum TrashError: LocalizedError {
        case protected, changed, unavailable, recordFailed
        var errorDescription: String? {
            switch self {
            case .protected: "System and application-managed locations are excluded."
            case .changed: "The selected file differs, changed since indexing, or the destination already exists. Refresh or choose again."
            case .unavailable: "The Trash item no longer exists or its access expired. Finder may have permanently removed it."
            case .recordFailed: "The operation result could not be recorded."
            }
        }
    }
}
