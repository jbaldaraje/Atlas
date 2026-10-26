import AppKit
import UniformTypeIdentifiers
import VaultCore

struct ImportCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let type: String
    let category: ScanFileCategory
    init(url: URL, size: Int64, type: String, category: ScanFileCategory? = nil) {
        self.url = url; self.size = size; self.type = type
        self.category = category ?? ScanFileCategory.classify(fileExtension: type.isEmpty ? url.pathExtension : type)
    }
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
                return ImportCandidate(url: url, size: Int64(values.fileSize ?? 0), type: values.contentType?.preferredFilenameExtension ?? url.pathExtension, category: category(for: url, contentType: values.contentType))
            }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func scanFolder(_ bookmark: Data, excludes: [String], categories: Set<ScanFileCategory> = ScanFileCategory.all) async throws -> [ImportCandidate] {
        let worker = Task.detached(priority: .utility) {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw FileAccessService.AccessError.staleBookmark }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            var traversalError: Error?
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in traversalError = error; return false }) else { throw CocoaError(.fileReadNoPermission) }
            var urls: [URL] = []
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let relative = String(url.path.dropFirst(folder.path.count + 1))
                if excludes.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { enumerator.skipDescendants(); continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values.isRegularFile == true { urls.append(url) }
                guard urls.count <= 10_000 else { throw ScanError.tooManyFiles }
            }
            if let traversalError { throw traversalError }
            let inspected = try await FileAccessService.inspect(urls)
            return inspected.filter { categories.contains($0.category) }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private static func category(for url: URL, contentType: UTType?) -> ScanFileCategory {
        let byExtension = ScanFileCategory.classify(fileExtension: url.pathExtension)
        guard byExtension == .other, let contentType else { return byExtension }
        if contentType.conforms(to: .pdf) { return .pdf }
        if contentType.conforms(to: .image) { return .images }
        if contentType.conforms(to: .movie) || contentType.conforms(to: .audio) { return .media }
        if contentType.conforms(to: .text) || contentType.conforms(to: .presentation) || contentType.conforms(to: .spreadsheet) { return .documents }
        return .other
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
    enum ScanError: LocalizedError {
        case tooManyFiles
        var errorDescription: String? { "Folder exceeds this build’s 10,000-file limit. Select a smaller folder; no partial scan was accepted." }
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
