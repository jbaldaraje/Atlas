import Foundation

public enum CatalogSection: String, Sendable { case files, media, subjects, collections, timeline, notes }
public enum CatalogEvent: String, CaseIterable, Sendable {
    case added, modified, study
    public var title: String {
        switch self {
        case .added: "Added to Vault"
        case .modified: "Filesystem modification dates · last indexed"
        case .study: "Study sessions · explicitly recorded"
        }
    }
}
public struct CatalogLocation: Equatable, Sendable {
    public var folder: String?
    public var subjectID: UUID?
    public var collectionID: UUID?
    public var event: CatalogEvent?
    public var month: String?
    public var accountID: String?
    public var noteFolderID: String?
    public init() {}
}
public struct CatalogQuery: Equatable, Sendable {
    public var section: CatalogSection = .files
    public var location = CatalogLocation()
    public var text = ""
    public var favorites = false
    public var type = ""
    public var kind = FileKindFilter.all
    public var pinnedCollections: Set<UUID>?
    public var minimumBytes: Int64 = 0
    public var recent = false
    public var old = false
    public var sort = "Added"
    public var page = 0
    public var linkingFileID: UUID?
    public init() {}
}
public struct CatalogGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let count: Int
    public let symbol: String
    public let location: CatalogLocation
    public var linked = false
}
public struct CatalogStudyRow: Identifiable, Sendable {
    public let id: UUID
    public let subject: String
    public let session: StudySession
}
public struct CatalogPage: Sendable {
    public static let capacity = 60
    public var groups: [CatalogGroup] = []
    public var files: [FileItem] = []
    public var sessions: [CatalogStudyRow] = []
    public var matchingFiles = 0
    public var itemCount = 0
    public var page = 0
    public init() {}
    public var pageCount: Int { max(1, (itemCount + Self.capacity - 1) / Self.capacity) }
}
public struct CatalogSnapshot: Sendable {
    public let library: Library
    public let subjects: [Subject]
    public let sessions: [StudySession]
    public let sourcePaths: [String]
    public let text: [UUID: String]
    public init(library: Library, subjects: [Subject], sessions: [StudySession], sourcePaths: [String], text: [UUID: String]) {
        self.library = library; self.subjects = subjects; self.sessions = sessions; self.sourcePaths = sourcePaths; self.text = text
    }
}

/// A local metadata index. Opening a parent never enumerates disk or materializes child views.
public struct CatalogIndex: Sendable {
    private struct Entry: Sendable { let file: FileItem; let parent: String; let root: String; let category: ScanFileCategory }
    private let snapshot: CatalogSnapshot
    private var entries: [Entry] = []
    private var months: [UUID: (added: String, modified: String?)] = [:]
    private var subjectNames: [UUID: String] = [:]
    private let calendar: Calendar
    public init(_ snapshot: CatalogSnapshot) throws {
        self.snapshot = snapshot
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current; self.calendar = calendar
        subjectNames = Dictionary(snapshot.subjects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let parents = Set(snapshot.library.files.map { Self.parent($0.originalLocation) })
        let sources = Set(snapshot.sourcePaths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        // Collapse only ancestors represented by indexed data / approved source metadata.
        let candidates = parents.union(sources)
        var roots = Set<String>()
        for path in candidates {
            try Task.checkCancellation()
            var ancestor = Self.parent(path), covered = false
            while ancestor != path {
                if candidates.contains(ancestor) { covered = true; break }
                if ancestor == "/" { break }
                let next = Self.parent(ancestor); if next == ancestor { break }; ancestor = next
            }
            if !covered { roots.insert(path) }
        }
        for file in snapshot.library.files {
            try Task.checkCancellation()
            let parent = Self.parent(file.originalLocation)
            var root = parent
            while !roots.contains(root) && root != "/" { root = Self.parent(root) }
            entries.append(Entry(file: file, parent: parent, root: root, category: ScanFileCategory.classify(fileExtension: file.type)))
            months[file.id] = (Self.month(file.indexedAt, calendar), file.modifiedAt.map { Self.month($0, calendar) })
        }
    }
    private static func parent(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path }
    private static func within(_ path: String, _ parent: String) -> Bool { path == parent || path.hasPrefix(parent == "/" ? "/" : parent + "/") }
    private static func month(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    public func page(_ query: CatalogQuery, now: Date = .now) throws -> CatalogPage {
        try Task.checkCancellation()
        let subject = query.location.subjectID.flatMap { id in snapshot.subjects.first { $0.id == id } }
        let words = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [Entry] = []
        for (index, entry) in entries.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            let file = entry.file
            if !query.kind.includes(category: entry.category) { continue }
            if let id = query.location.subjectID, subject?.id != id || subject?.fileIDs.contains(file.id) != true { continue }
            if let id = query.location.collectionID, !file.collectionIDs.contains(id) { continue }
            if query.section == .media {
                let category = entry.category
                if category != .images && category != .media { continue }
            }
            if query.section == .notes {
                guard let source = file.noteSource else { continue }
                if let id = query.location.accountID, source.accountID != id { continue }
                if let id = query.location.noteFolderID, source.folderID != id { continue }
            }
            if query.section == .timeline, query.location.event == .modified, file.modifiedAt == nil { continue }
            if let month = query.location.month, query.section == .timeline {
                let value = query.location.event == .modified ? months[file.id]?.modified : months[file.id]?.added
                if value != month { continue }
            }
            if query.favorites && !file.favorite { continue }
            if !query.type.isEmpty && !file.type.localizedCaseInsensitiveContains(query.type) { continue }
            if file.size < query.minimumBytes { continue }
            if query.recent && file.indexedAt < now.addingTimeInterval(-30 * 86400) { continue }
            if query.old && (file.modifiedAt ?? now) >= now.addingTimeInterval(-365 * 86400) { continue }
            if !words.allSatisfy({ word in
                [file.filename, file.description, entry.parent, snapshot.text[file.id] ?? "", file.noteSource?.title ?? ""].contains { $0.localizedCaseInsensitiveContains(word) } || file.tags.contains { $0.localizedCaseInsensitiveContains(word) }
            }) { continue }
            matches.append(entry)
        }
        var result = CatalogPage(); result.matchingFiles = matches.count
        if query.section == .subjects && query.location.subjectID == nil {
            var counts: [UUID: Int] = [:]
            let ids = Set(matches.map { $0.file.id })
            for subject in snapshot.subjects {
                try Task.checkCancellation()
                counts[subject.id] = subject.fileIDs.intersection(ids).count
            }
            let groups = snapshot.subjects.filter {
                (query.kind == .all || query.linkingFileID != nil || (counts[$0.id] ?? 0) > 0) &&
                (words.isEmpty || $0.name.localizedCaseInsensitiveContains(query.text) || (counts[$0.id] ?? 0) > 0)
            }.map { subject -> CatalogGroup in
                var location = query.location; location.subjectID = subject.id
                var group = CatalogGroup(id: "subject:" + subject.id.uuidString, title: subject.name, subtitle: subject.description, count: counts[subject.id] ?? 0, symbol: "books.vertical", location: location)
                group.linked = query.linkingFileID.map { subject.fileIDs.contains($0) } ?? false
                return group
            }
            return grouped(groups, result: result, query: query)
        }
        if query.section == .collections && query.location.collectionID == nil {
            var counts: [UUID: Int] = [:]
            for entry in matches { for id in entry.file.collectionIDs { counts[id, default: 0] += 1 } }
            let membership = query.linkingFileID.flatMap { id in snapshot.library.files.first { $0.id == id } }?.collectionIDs ?? []
            let groups = snapshot.library.collections.filter {
                (query.pinnedCollections == nil || query.pinnedCollections?.contains($0.id) == true) &&
                (query.kind == .all || query.linkingFileID != nil || (counts[$0.id] ?? 0) > 0) &&
                (words.isEmpty || $0.name.localizedCaseInsensitiveContains(query.text) || (counts[$0.id] ?? 0) > 0)
            }.map { collection -> CatalogGroup in
                var location = query.location; location.collectionID = collection.id
                var group = CatalogGroup(id: "collection:" + collection.id.uuidString, title: collection.name, subtitle: "Virtual collection", count: counts[collection.id] ?? 0, symbol: "square.stack", location: location)
                group.linked = membership.contains(collection.id)
                return group
            }
            return grouped(groups, result: result, query: query)
        }
        if query.section == .notes {
            if query.location.accountID == nil {
                let groupedNotes = Dictionary(grouping: matches, by: { $0.file.noteSource!.accountID })
                let groups = groupedNotes.map { id, entries -> CatalogGroup in
                    var location = query.location; location.accountID = id
                    return CatalogGroup(id: "account:" + id, title: entries[0].file.noteSource!.accountName, subtitle: "Imported note account", count: entries.count, symbol: "icloud", location: location)
                }
                return grouped(groups, result: result, query: query)
            }
            if query.location.noteFolderID == nil {
                let groupedNotes = Dictionary(grouping: matches, by: { $0.file.noteSource!.folderID })
                let groups = groupedNotes.map { id, entries -> CatalogGroup in
                    var location = query.location; location.noteFolderID = id
                    return CatalogGroup(id: "note-folder:" + id, title: entries[0].file.noteSource!.folderName, subtitle: "Imported note folder", count: entries.count, symbol: "folder", location: location)
                }
                return grouped(groups, result: result, query: query)
            }
            return filePage(matches.map(\.file), groups: [], result: result, query: query)
        }
        if query.section == .timeline {
            let sessions = snapshot.sessions.filter { session in
                query.kind == .all && (
                words.isEmpty || [session.note, subjectNames[session.subjectID] ?? ""].contains { $0.localizedCaseInsensitiveContains(query.text) }
                )
            }
            if query.location.event == nil {
                let counts = [matches.count, matches.filter { $0.file.modifiedAt != nil }.count, sessions.count]
                let groups = zip(CatalogEvent.allCases, counts).filter { query.kind == .all || $0.1 > 0 }.map { event, count -> CatalogGroup in
                    var location = query.location; location.event = event
                    return CatalogGroup(id: event.rawValue, title: event.title, subtitle: "Open to browse months", count: count, symbol: "calendar", location: location)
                }
                return grouped(groups, result: result, query: query)
            }
            if query.location.month == nil {
                var counts: [String: Int] = [:]
                if query.location.event == .study {
                    for session in sessions { counts[Self.month(session.date, calendar), default: 0] += 1 }
                } else {
                    for entry in matches {
                        if let key = query.location.event == .modified ? months[entry.file.id]?.modified : months[entry.file.id]?.added { counts[key, default: 0] += 1 }
                    }
                }
                let groups = counts.map { month, count -> CatalogGroup in
                    var location = query.location; location.month = month
                    return CatalogGroup(id: month, title: month, subtitle: query.location.event?.title ?? "", count: count, symbol: "calendar", location: location)
                }.sorted { $0.id > $1.id }
                return sliced(groups: groups, files: [], sessions: [], result: result, query: query)
            }
            if query.location.event == .study {
                let rows = sessions.filter { Self.month($0.date, calendar) == query.location.month }.sorted { $0.date > $1.date }.map {
                    CatalogStudyRow(id: $0.id, subject: subjectNames[$0.subjectID] ?? "Removed subject", session: $0)
                }
                return sliced(groups: [], files: [], sessions: rows, result: result, query: query)
            }
        }
        var counts: [String: Int] = [:], direct: [FileItem] = []
        for entry in matches {
            try Task.checkCancellation()
            guard let folder = query.location.folder else { counts[entry.root, default: 0] += 1; continue }
            guard Self.within(entry.parent, folder) else { continue }
            if entry.parent == folder { direct.append(entry.file); continue }
            let prefix = folder == "/" ? "/" : folder + "/"
            let remainder = entry.parent.dropFirst(prefix.count)
            if let first = remainder.split(separator: "/").first { counts[prefix + String(first), default: 0] += 1 }
        }
        let groups = counts.map { path, count -> CatalogGroup in
            var location = query.location; location.folder = path
            return CatalogGroup(id: path, title: path == "/" ? "Root folder" : URL(fileURLWithPath: path).lastPathComponent, subtitle: path, count: count, symbol: "folder.fill", location: location)
        }.sorted(by: groupBefore)
        result.matchingFiles = counts.values.reduce(0, +) + direct.count
        return filePage(direct, groups: groups, result: result, query: query)
    }
    private func filePage(_ files: [FileItem], groups: [CatalogGroup], result: CatalogPage, query: CatalogQuery) -> CatalogPage {
        let sorted = files.sorted { a, b in
            switch query.sort {
            case "Name": break
            case "Type": if a.type != b.type { return a.type < b.type }
            case "Size": if a.size != b.size { return a.size > b.size }
            case "Modified": if a.modifiedAt != b.modifiedAt { return (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast) }
            default: if a.indexedAt != b.indexedAt { return a.indexedAt > b.indexedAt }
            }
            let order = a.filename.localizedStandardCompare(b.filename)
            return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
        return sliced(groups: groups, files: sorted, sessions: [], result: result, query: query)
    }
    private func grouped(_ groups: [CatalogGroup], result: CatalogPage, query: CatalogQuery) -> CatalogPage {
        sliced(groups: groups.sorted(by: groupBefore), files: [], sessions: [], result: result, query: query)
    }
    private func groupBefore(_ a: CatalogGroup, _ b: CatalogGroup) -> Bool {
        let order = a.title.localizedStandardCompare(b.title)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
    private func sliced(groups: [CatalogGroup], files: [FileItem], sessions: [CatalogStudyRow], result: CatalogPage, query: CatalogQuery) -> CatalogPage {
        var result = result; result.itemCount = groups.count + files.count + sessions.count
        result.page = min(max(0, query.page), result.pageCount - 1)
        let start = result.page * CatalogPage.capacity, end = start + CatalogPage.capacity
        result.groups = Array(groups.dropFirst(start).prefix(CatalogPage.capacity))
        let fileStart = max(0, start - groups.count), fileEnd = max(0, end - groups.count)
        result.files = Array(files.dropFirst(fileStart).prefix(max(0, fileEnd - fileStart)))
        let sessionStart = max(0, start - groups.count - files.count), sessionEnd = max(0, end - groups.count - files.count)
        result.sessions = Array(sessions.dropFirst(sessionStart).prefix(max(0, sessionEnd - sessionStart)))
        return result
    }
}
