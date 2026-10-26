import Foundation

public enum StorageOwnership: String, Codable, Sendable { case original, managedCopy }
public struct FileItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var filename: String
    public var type: String
    public var bookmark: Data
    public var originalLocation: String
    public var ownership: StorageOwnership
    public var size: Int64
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var indexedAt: Date
    public var description: String
    public var tags: [String]
    public var collectionIDs: Set<UUID>
    public var favorite: Bool
    public init(id: UUID = UUID(), filename: String, type: String, bookmark: Data, originalLocation: String, ownership: StorageOwnership, size: Int64, createdAt: Date? = nil, modifiedAt: Date? = nil, indexedAt: Date = .now, description: String = "", tags: [String] = [], collectionIDs: Set<UUID> = [], favorite: Bool = false) {
        self.id = id; self.filename = filename; self.type = type; self.bookmark = bookmark
        self.originalLocation = originalLocation; self.ownership = ownership; self.size = size
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.indexedAt = indexedAt
        self.description = description; self.tags = tags; self.collectionIDs = collectionIDs; self.favorite = favorite
    }
}
public struct FileCollection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}
public struct Library: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var files: [FileItem] = []
    public var collections: [FileCollection] = []
    public init() {}
    public func search(_ query: String, collectionID: UUID? = nil, favoritesOnly: Bool = false) -> [FileItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return files.filter { file in
            (!favoritesOnly || file.favorite) && (collectionID == nil || file.collectionIDs.contains(collectionID!)) && words.allSatisfy { word in
                ([file.filename, file.description] + file.tags).contains { $0.localizedCaseInsensitiveContains(word) }
            }
        }
    }
    public mutating func removeFromIndex(_ id: UUID) { files.removeAll { $0.id == id } }
    public mutating func removeCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        for index in files.indices { files[index].collectionIDs.remove(id) }
    }
}

/// Atomic local metadata storage. No secrets or extracted document content belong here.
public struct LibraryRepository: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
        guard library.schemaVersion == 1 else { throw RepositoryError.unsupportedSchema }
        return library
    }
    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: url, options: .atomic)
    }
    public enum RepositoryError: Error { case unsupportedSchema }
}
