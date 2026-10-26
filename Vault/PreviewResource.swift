import Foundation
import VaultCore

/// Immutable, single security-scope lease. The scope closes when its final owner releases it.
final class PreviewResource: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    fileprivate init(url: URL, scoped: Bool) { self.url = url; self.scoped = scoped }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
    static func resolve(_ file: FileItem) async throws -> PreviewResource { try await resolve(bookmark: file.bookmark) }
    static func resolve(bookmark: Data, directory: Bool = false) async throws -> PreviewResource {
        try await PreviewResourceResolver.shared.resolve(bookmark: bookmark, directory: directory)
    }
}
/// Serialize blocking bookmark lookups away from the main actor rather than creating a worker per thumbnail.
private actor PreviewResourceResolver {
    static let shared = PreviewResourceResolver()
    func resolve(bookmark: Data, directory: Bool) throws -> PreviewResource {
        try Task.checkCancellation()
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw FileAccessService.AccessError.staleBookmark }
        let resource = PreviewResource(url: url, scoped: url.startAccessingSecurityScopedResource())
        guard FileManager.default.fileExists(atPath: url.path) else { throw FileAccessService.AccessError.missingFile }
        if directory { guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) } }
        try Task.checkCancellation(); return resource
    }
}
