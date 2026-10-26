import Foundation

public enum ExplorationItemKind: String, Codable, Sendable { case file, subject, collection, relationship }
public enum ExplorationReason: String, Codable, Sendable {
    case selected, explicitLink, sharedSubject, sharedCollection, sharedTag, indexedTerms, photoMetadata
    public var title: String {
        switch self {
        case .selected: "Selected"
        case .explicitLink: "User connection"
        case .sharedSubject: "Shared subject"
        case .sharedCollection: "Shared collection"
        case .sharedTag: "Shared tag"
        case .indexedTerms: "Indexed-text suggestion"
        case .photoMetadata: "Shared photo metadata"
        }
    }
}
public struct ExplorationStep: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public let itemID: UUID
    public let kind: ExplorationItemKind
    public let originID: UUID?
    public let reason: ExplorationReason
    public let visitedAt: Date
    public init(itemID: UUID, kind: ExplorationItemKind, originID: UUID? = nil, reason: ExplorationReason = .selected, visitedAt: Date = .now) {
        self.itemID = itemID; self.kind = kind; self.originID = originID; self.reason = reason; self.visitedAt = visitedAt
    }
}
public struct ExplorationHistory: Codable, Equatable, Sendable {
    public private(set) var steps: [ExplorationStep] = []
    public private(set) var cursor = -1
    public init() {}
    private enum CodingKeys: String, CodingKey { case steps, cursor }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let original = try c.decodeIfPresent([ExplorationStep].self, forKey: .steps) ?? []
        let stored = try c.decodeIfPresent(Int.self, forKey: .cursor) ?? (original.count - 1)
        steps = Array(original.suffix(80))
        let dropped = max(0, original.count - steps.count)
        cursor = steps.isEmpty ? -1 : max(0, min(steps.count - 1, max(0, min(stored, original.count - 1)) - dropped))
    }
    public var current: ExplorationStep? { steps.indices.contains(cursor) ? steps[cursor] : nil }
    public var canGoBack: Bool { cursor > 0 }
    public var canGoForward: Bool { cursor >= 0 && cursor + 1 < steps.count }
    public mutating func visit(_ step: ExplorationStep) {
        guard current?.itemID != step.itemID else { return }
        steps = Array(steps.prefix(max(0, min(cursor + 1, steps.count))))
        steps.append(step)
        if steps.count > 80 { steps.removeFirst(steps.count - 80) }
        cursor = steps.count - 1
    }
    @discardableResult public mutating func jump(to index: Int) -> ExplorationStep? {
        guard steps.indices.contains(index) else { return nil }; cursor = index; return steps[index]
    }
    public func previousIndex(kind: ExplorationItemKind? = nil) -> Int? {
        guard cursor > 0 else { return nil }
        return (0..<min(cursor, steps.count)).reversed().first { kind == nil || steps[$0].kind == kind }
    }
    public func nextIndex(kind: ExplorationItemKind? = nil) -> Int? {
        guard cursor >= 0, cursor + 1 < steps.count else { return nil }
        return ((cursor + 1)..<steps.count).first { kind == nil || steps[$0].kind == kind }
    }
    public mutating func reconcile(validIDs: Set<UUID>) {
        let currentID = current?.id
        steps = Array(steps.filter { validIDs.contains($0.itemID) }.suffix(80))
        cursor = currentID.flatMap { id in steps.firstIndex { $0.id == id } } ?? (steps.count - 1)
    }
}
public struct DiscoveryPair: Codable, Hashable, Sendable {
    public let first: UUID
    public let second: UUID
    public init(_ a: UUID, _ b: UUID) {
        if a.uuidString < b.uuidString { first = a; second = b } else { first = b; second = a }
    }
}
public struct ConnectionEvidence: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: ExplorationReason
    public let label: String
    public let detail: String
    public let contextID: UUID?
    public let suggested: Bool
    public let sharedTermCount: Int?
    public init(id: String, kind: ExplorationReason, label: String, detail: String, contextID: UUID? = nil, suggested: Bool = false, sharedTermCount: Int? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.detail = detail; self.contextID = contextID; self.suggested = suggested; self.sharedTermCount = sharedTermCount
    }
}
public struct ConnectedDocument: Identifiable, Sendable {
    public var id: UUID { file.id }
    public let file: FileItem
    public let evidence: [ConnectionEvidence]
    public let hasExplicitLink: Bool
    public var primaryReason: ExplorationReason { evidence.first?.kind ?? .selected }
    public init(file: FileItem, evidence: [ConnectionEvidence]) {
        self.file = file; self.evidence = evidence; hasExplicitLink = evidence.contains { $0.kind == .explicitLink }
    }
}
public struct AtAGlance: Sendable {
    public var description = ""
    public var headings: [String] = []
    public var terms: [String] = []
    public var excerpts: [String] = []
    public var dates: [String] = []
    public var hasText = false
    public init() {}
    public static func make(file: FileItem, text: String?) -> AtAGlance {
        var result = AtAGlance(); result.description = file.description
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        result.hasText = true
        let source = String(text.prefix(12_000))
        let lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        result.headings = Array(lines.filter { line in
            (line.hasPrefix("#") || line.hasSuffix(":")) && line.count >= 4 && line.count <= 100
        }.prefix(5))
        result.terms = Array(ContentEvidenceIndex.keyTerms(source).prefix(8))
        result.excerpts = Array(lines.filter { $0.count >= 40 }.prefix(3).map { String($0.prefix(240)) })
        if result.excerpts.isEmpty, let line = lines.first { result.excerpts = [String(line.prefix(240))] }
        if let regex = try? NSRegularExpression(pattern: #"\b(?:\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{4})\b"#) {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            var seen = Set<String>()
            result.dates = regex.matches(in: source, range: range).compactMap { match in
                guard let range = Range(match.range, in: source) else { return nil }
                let date = String(source[range]); return seen.insert(date).inserted ? date : nil
            }.prefix(5).map { $0 }
        }
        return result
    }
}

/// Optional suggestions from already-indexed text. No file access or automatic extraction.
public struct ContentEvidenceIndex: Sendable {
    private var terms: [UUID: Set<String>] = [:]
    private var postings: [String: [UUID]] = [:]
    public init(texts: [UUID: String], validIDs: Set<UUID>) throws {
        for (id, text) in texts where validIDs.contains(id) {
            try Task.checkCancellation()
            let keys = Set(Self.keyTerms(String(text.prefix(12_000))).prefix(60))
            terms[id] = keys
            for key in keys { postings[key, default: []].append(id) }
        }
    }
    public func matches(for id: UUID) throws -> [UUID: [String]] {
        var matches: [UUID: [String]] = [:]
        for term in (terms[id] ?? []).sorted() {
            try Task.checkCancellation()
            for other in postings[term] ?? [] where other != id {
                try Task.checkCancellation(); matches[other, default: []].append(term)
            }
        }
        return matches.filter { $0.value.count >= 3 }
    }
    public static func keyTerms(_ text: String) -> [String] {
        let stop: Set<String> = ["about", "after", "again", "also", "been", "before", "being", "between", "both", "could", "document", "each", "file", "from", "have", "into", "more", "most", "notes", "only", "other", "over", "page", "research", "same", "should", "some", "such", "than", "that", "their", "them", "then", "there", "these", "they", "this", "through", "under", "used", "using", "very", "were", "what", "when", "where", "which", "while", "will", "with", "would", "your"]
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 && !stop.contains($0) }
        let counts = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.keys.sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0, default: 0] > counts[$1, default: 0] }
    }
}

public struct ConnectedDocumentsPage: Sendable {
    public static let capacity = 12
    public let documents: [ConnectedDocument]
    public let total: Int
    public let page: Int
    public var pageCount: Int { max(1, (total + Self.capacity - 1) / Self.capacity) }
    public init(documents: [ConnectedDocument], total: Int, page: Int) { self.documents = documents; self.total = total; self.page = page }
}
