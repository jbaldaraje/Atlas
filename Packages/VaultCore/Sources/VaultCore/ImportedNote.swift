import Foundation

/// Provenance for a user-approved local snapshot. These are regular library files, not Secure Vault records.
public struct ImportedNoteSource: Codable, Equatable, Sendable {
    public var accountID: String
    public var accountName: String
    public var folderID: String
    public var folderName: String
    public var noteID: String
    public var title: String
    public var sourceCreatedAt: Date?
    public var sourceModifiedAt: Date?
    public var exportedFile: Bool? = nil
    public var searchable: Bool? = nil
    public var importedAt: Date
    public var catalogKey: String { accountID + "::" + noteID }
    public init(accountID: String, accountName: String, folderID: String, folderName: String, noteID: String, title: String, sourceCreatedAt: Date? = nil, sourceModifiedAt: Date? = nil, importedAt: Date = .now) {
        self.accountID = accountID; self.accountName = accountName; self.folderID = folderID
        self.folderName = folderName; self.noteID = noteID; self.title = title
        self.sourceCreatedAt = sourceCreatedAt; self.sourceModifiedAt = sourceModifiedAt; self.importedAt = importedAt
    }
}
public struct ImportedNoteSnapshot: Sendable {
    public var source: ImportedNoteSource
    public var text: String
    public init(source: ImportedNoteSource, text: String) { self.source = source; self.text = text }
}
public enum ImportedNoteRules {
    public static func filename(title: String) -> String {
        let title = title.components(separatedBy: .newlines).joined(separator: " ")
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Untitled note" : cleaned).prefix(100)) + ".txt"
    }
    public static func existingID(for source: ImportedNoteSource, in library: Library) -> UUID? {
        library.files.first { $0.noteSource?.catalogKey == source.catalogKey }?.id
    }
    public static func register(_ file: FileItem, in library: inout Library) {
        guard let source = file.noteSource else { return }
        var collection: FileCollection
        if let existing = library.collections.first(where: { $0.organizationKey == "apple-notes:" + source.accountID }) { collection = existing }
        else {
            collection = FileCollection(name: "Apple Notes · " + source.accountName); collection.organizationKey = "apple-notes:" + source.accountID
            library.collections.append(collection)
        }
        var entry = file; entry.collectionIDs.insert(collection.id)
        if let index = library.files.firstIndex(where: { $0.id == entry.id }) { library.files[index] = entry }
        else { library.files.append(entry) }
    }
}
