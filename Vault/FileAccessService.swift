import AppKit
import UniformTypeIdentifiers
import VaultCore

struct ImportCandidate: Identifiable, Sendable {
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
struct FolderDiscovery: Sendable {
    var candidates: [ImportCandidate] = []
    var discovered = 0
    var skipped = 0
    var errors: [String] = []
}
struct ImportReport: Sendable {
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
                return candidate(url: url, values: values)
            }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func scanFolder(_ bookmark: Data, excludes: [String], categories: Set<ScanFileCategory> = ScanFileCategory.all) async throws -> [ImportCandidate] {
        try await discoverFolder(bookmark, excludes: excludes, categories: categories).candidates
    }
    static func discoverFolder(_ bookmark: Data, excludes: [String], categories: Set<ScanFileCategory>, progress: (@Sendable (Int) -> Void)? = nil) async throws -> FolderDiscovery {
        let cursor = try FolderScanCursor(bookmark: bookmark, excludes: excludes, categories: categories)
        var report = FolderDiscovery()
        do {
            while true {
                let batch = try await cursor.nextBatch()
                report.candidates.append(contentsOf: batch.discovery.candidates)
                report.discovered += batch.discovery.discovered; report.skipped += batch.discovery.skipped
                report.errors.append(contentsOf: batch.discovery.errors)
                progress?(report.discovered)
                if batch.finished { break }
            }
            await cursor.close()
            return report
        } catch { await cursor.close(); throw error }
    }
    fileprivate static func candidate(url: URL, values: URLResourceValues) -> ImportCandidate {
        ImportCandidate(url: url, size: Int64(values.fileSize ?? 0), type: values.contentType?.preferredFilenameExtension ?? url.pathExtension, category: category(for: url, contentType: values.contentType))
    }
    static func identity(at url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return "\(device):\(inode)"
    }
    private static func category(for url: URL, contentType: UTType?) -> ScanFileCategory {
        let byExtension = ScanFileCategory.classify(fileExtension: url.pathExtension)
        guard byExtension == .other, let contentType else { return byExtension }
        if contentType.conforms(to: .pdf) { return .pdf }
        if contentType.conforms(to: .image) { return .images }
        if contentType.conforms(to: .movie) || contentType.conforms(to: .audio) { return .media }
        if contentType.conforms(to: .presentation) { return .presentations }
        if contentType.conforms(to: .spreadsheet) { return .data }
        if contentType.conforms(to: .archive) { return .archives }
        if contentType.conforms(to: .text) { return .documents }
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
                    var file = FileItem(filename: source.lastPathComponent, type: candidate.type, bookmark: bookmark, originalLocation: destination.standardizedFileURL.path, ownership: copy ? .managedCopy : .original, size: Int64(values.fileSize ?? 0), createdAt: values.creationDate, modifiedAt: values.contentModificationDate)
                    file.fileIdentity = identity(at: destination)
                    report.items.append(file)
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

struct FolderScanBatch: Sendable {
    let discovery: FolderDiscovery
    let finished: Bool
}

/// Used only by the filesystem enumerator's callback; errors are drained into each batch.
private final class FolderTraversalErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ message: String) { lock.lock(); defer { lock.unlock() }; messages.append(message) }
    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let result = messages; messages.removeAll(keepingCapacity: true); return result
    }
}

/// A bounded, backpressured cursor: the next chunk is read only when its consumer is ready.
/// Chunk size controls buffering, never the total number of files that may be scanned.
actor FolderScanCursor {
    static let batchCapacity = 512
    private let folder: URL
    private let excludes: [String]
    private let categories: Set<ScanFileCategory>
    private let traversalErrors: FolderTraversalErrors
    private var enumerator: FileManager.DirectoryEnumerator?
    private var scoped: Bool
    private var finished = false

    init(bookmark: Data, excludes: [String], categories: Set<ScanFileCategory>) throws {
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw FileAccessService.AccessError.staleBookmark }
        let scope = folder.startAccessingSecurityScopedResource()
        let errors = FolderTraversalErrors()
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in
            errors.record("Unavailable folder: " + url.lastPathComponent); return true
        }) else {
            if scope { folder.stopAccessingSecurityScopedResource() }
            throw CocoaError(.fileReadNoPermission)
        }
        self.folder = folder; self.excludes = excludes; self.categories = categories
        traversalErrors = errors; self.enumerator = enumerator; scoped = scope
    }
    deinit { if scoped { folder.stopAccessingSecurityScopedResource() } }

    func nextBatch() throws -> FolderScanBatch {
        try Task.checkCancellation()
        guard !finished, let enumerator else { return FolderScanBatch(discovery: FolderDiscovery(), finished: true) }
        var report = FolderDiscovery()
        var visited = 0
        while visited < Self.batchCapacity {
            try Task.checkCancellation()
            guard let url = enumerator.nextObject() as? URL else { close(); break }
            visited += 1
            let relative = String(url.path.dropFirst(folder.path.count + 1))
            if excludes.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { enumerator.skipDescendants(); continue }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                report.discovered += 1
                let item = FileAccessService.candidate(url: url, values: values)
                if categories.contains(item.category) { report.candidates.append(item) } else { report.skipped += 1 }
            } catch { report.errors.append("Unavailable file: " + url.lastPathComponent) }
        }
        report.errors.append(contentsOf: traversalErrors.drain())
        return FolderScanBatch(discovery: report, finished: finished)
    }
    func close() {
        enumerator = nil; finished = true
        if scoped { folder.stopAccessingSecurityScopedResource(); scoped = false }
    }
}
