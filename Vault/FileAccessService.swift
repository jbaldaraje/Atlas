import AppKit
import UniformTypeIdentifiers
import VaultCore

struct ImportCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let type: String
}
struct ImportReport {
    var items: [FileItem] = []
    var failures: [String] = []
    var skipped = 0
    var cancelled = false
}

/// All filesystem access is scoped to a user selection or a stored bookmark.
struct FileAccessService: Sendable {
    static func inspect(_ urls: [URL]) async throws -> [ImportCandidate] {
        let worker = Task.detached(priority: .userInitiated) {
            try urls.map { url in
                try Task.checkCancellation()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AccessError.regularFilesOnly }
                return ImportCandidate(url: url, size: Int64(values.fileSize ?? 0), type: values.contentType?.preferredFilenameExtension ?? url.pathExtension)
            }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func run(_ candidates: [ImportCandidate], copy: Bool, managedDirectory: URL, existingPaths: Set<String>, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ImportReport {
        let worker = Task.detached(priority: .userInitiated) {
            var report = ImportReport()
            for (index, candidate) in candidates.enumerated() {
                if Task.isCancelled { report.cancelled = true; break }
                defer { progress?(index + 1, candidates.count) }
                let source = candidate.url
                if !copy && existingPaths.contains(source.standardizedFileURL.path) { report.skipped += 1; continue }
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                var ownedURL: URL?
                do {
                    let selected = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard selected.isRegularFile == true, selected.isSymbolicLink != true else { throw AccessError.regularFilesOnly }
                    var destination = source
                    if copy {
                        try FileManager.default.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
                        // Unique per-import directory preserves filenames without overwriting any library file.
                        let directory = managedDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        ownedURL = directory
                        destination = directory.appendingPathComponent(source.lastPathComponent)
                        let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        try FileManager.default.copyItem(at: source, to: destination)
                        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
                              FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path) else { throw AccessError.copyVerificationFailed }
                    }
                    let values = try destination.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
                    let bookmark = try destination.bookmarkData(options: copy ? [.withSecurityScope] : [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                    report.items.append(FileItem(filename: source.lastPathComponent, type: candidate.type, bookmark: bookmark, originalLocation: destination.standardizedFileURL.path, ownership: copy ? .managedCopy : .original, size: Int64(values.fileSize ?? 0), createdAt: values.creationDate, modifiedAt: values.contentModificationDate))
                } catch {
                    if let ownedURL { try? FileManager.default.removeItem(at: ownedURL) }
                    report.failures.append(source.lastPathComponent)
                }
            }
            return report
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
    static func withAccess<T>(_ file: FileItem, operation: (URL) throws -> T) throws -> T {
        var stale = false
        let url = try URL(resolvingBookmarkData: file.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw AccessError.staleBookmark }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AccessError.missingFile }
        return try operation(url)
    }
    static func withAsyncAccess<T>(_ file: FileItem, operation: (URL) async throws -> T) async throws -> T {
        var stale = false
        let url = try URL(resolvingBookmarkData: file.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw AccessError.staleBookmark }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AccessError.missingFile }
        return try await operation(url)
    }
    enum AccessError: LocalizedError {
        case regularFilesOnly, copyVerificationFailed, staleBookmark, missingFile
        var errorDescription: String? {
            switch self {
            case .regularFilesOnly: "Select regular files. Use Approve Folder for folder indexing. Symbolic links are excluded."
            case .copyVerificationFailed: "The copy could not be verified. The source may have changed."
            case .staleBookmark: "File access needs renewal. Remove this index entry and select the file again. The original is preserved."
            case .missingFile: "The file is unavailable. Reconnect its volume or add it again from its new location."
            }
        }
    }
}
