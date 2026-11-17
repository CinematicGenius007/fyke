// Wire types. These mirror the Result structs in src/ops.zig and src/store.zig.
import Foundation
import ReaderLogic

struct Items<T: Decodable & Sendable>: Decodable, Sendable { let items: [T] }

struct Feed: Decodable, Identifiable, Sendable, Equatable {
    let id: Int64
    let url: String
    let siteUrl: String?
    let title: String?
    let status: String
    let errorCount: Int64
    let lastError: String?
    let unread: Int64
    let entries: Int64
    let folderId: Int64?
    let starred: Int64

    var name: String { title ?? URL(string: url)?.host() ?? url }
}

struct Folder: Decodable, Identifiable, Sendable, Equatable {
    let id: Int64
    let parentId: Int64?
    let name: String
}

struct EntrySummary: Decodable, Identifiable, Sendable, Equatable {
    let id: Int64
    let feedId: Int64
    let feedTitle: String?
    let title: String?
    let url: String?
    let sortAt: Int64
    var read: Bool
    var starred: Bool
    var later: Bool?
    let snippet: String?
    let summary: String?

    var date: Date { Date(timeIntervalSince1970: Double(sortAt) / 1000) }

    /// One line of preview. Stored text keeps the article's line breaks.
    var preview: String? {
        let text = (snippet ?? summary)?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text?.isEmpty == false ? text : nil
    }
}

struct EntryPage: Decodable, Sendable {
    let items: [EntrySummary]
    let nextCursor: String?
}

struct Entry: Decodable, Sendable {
    let id: Int64
    let feedId: Int64
    let feedTitle: String?
    let title: String?
    let url: String?
    let author: String?
    let publishedAt: Int64?
    let firstSeenAt: Int64
    var read: Bool
    var starred: Bool
    let body: String
}

struct Stats: Decodable, Sendable {
    /// Missing from daemons older than the field.
    let apiVersion: Int64?
    let feeds: Int64
    let unread: Int64
    let lastEventSeq: Int64
}

struct Candidate: Decodable, Identifiable, Sendable, Equatable {
    let url: String
    let title: String?
    let siteUrl: String?
    let format: String
    let latest: [String]
    var id: String { url }
}

struct AddResult: Decodable, Sendable {
    let id: Int64
    let status: String
    let message: String?
}

struct Ok: Decodable, Sendable {}
struct IdResult: Decodable, Sendable { let id: Int64 }

struct ArticleUse: Decodable, Sendable {
    let entries: Int64
    let feeds: Int64
    let textBytes: Int64
    let searchBytes: Int64
    let otherBytes: Int64
    let removable: Int64
    let removableBytes: Int64
}

struct StorageUse: Decodable, Sendable {
    let articles: ArticleUse
    let databaseBytes: Int64
    let rawBytes: Int64
    let rawFiles: Int64
    let logBytes: Int64
    let settingsBytes: Int64
}

struct FreeResult: Decodable, Sendable {
    let trimmed: Int64
    let copiesRemoved: Int64
}
struct StatusResult: Decodable, Sendable { let status: String }

/// One node of the content model. See src/blocks.zig. Feed HTML never reaches the
/// app: an unknown kind simply renders as nothing.
struct Block: Decodable, Sendable {
    let t: String
    let v: String?
    let lang: String?
    let src: String?
    let alt: String?
    let href: String?
    let level: Int?
    let ordered: Bool?
    let items: [[Block]]?
    let rows: [[[Block]]]?
    let c: [Block]?
}

// MARK: Reader features

// The operations for views, recipes, briefs, routines and jobs return objects whose
// optional fields vary with what a record holds. They decode through `JSON` first and
// are read field by field, so a missing or extra field never fails a whole screen.

/// Any JSON value.
enum JSON: Decodable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    /// Keys arrive in snake case when decoded as JSON, since the decoder leaves
    /// dictionary keys alone. Lookups accept either spelling.
    subscript(_ keys: String...) -> JSON? {
        guard case .object(let map) = self else { return nil }
        for key in keys {
            if let value = map[key] ?? map[JSON.snake(key)], value != .null { return value }
        }
        return nil
    }

    static func snake(_ key: String) -> String {
        key.reduce(into: "") { out, c in
            if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) }
        }
    }

    var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int64(n)) : String(n)
        default: nil
        }
    }
    var int: Int64? {
        switch self {
        case .number(let n): Int64(n)
        case .string(let s): Int64(s)
        default: nil
        }
    }
    var double: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        default: nil
        }
    }
    var array: [JSON] { if case .array(let a) = self { a } else { [] } }

    /// Decodes this value as a typed model through the same rules as the daemon's replies.
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(EncodableJSON(self)) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }

    /// Some fields hold JSON written as text, such as a rule stored as `rule_json`.
    var parsed: JSON? {
        if case .string(let text) = self { return try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) }
        return self
    }
}

private struct EncodableJSON: Encodable {
    let value: JSON
    init(_ value: JSON) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v.map(EncodableJSON.init))
        case .object(let v): try c.encode(v.mapValues(EncodableJSON.init))
        }
    }
}

extension Date {
    /// The daemon stores times as Unix milliseconds. Seconds are accepted too.
    init?(daemon value: JSON?) {
        // Zero marks a record that came with the database, such as a built-in recipe.
        guard let number = value?.double, number > 0 else { return nil }
        self.init(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
    }
}

struct SavedView: Identifiable, Equatable, Sendable {
    let id: Int64
    var name: String
    var rule: SelectionRule
    var sentence: String?
    var unread: Int64
    var total: Int64
    var revision: Int64
    var position: Int64

    init?(_ j: JSON) {
        guard let id = j["id"]?.int else { return nil }
        self.id = id
        name = j["name"]?.string ?? "View"
        rule = (j["rule"]?.parsed ?? j["ruleJson"]?.parsed)?.decode(SelectionRule.self)?.normalized ?? SelectionRule()
        sentence = j["sentence"]?.string
        unread = j["unread"]?.int ?? j["unreadCount"]?.int ?? 0
        total = j["total"]?.int ?? j["count"]?.int ?? 0
        revision = j["revision"]?.int ?? 1
        position = j["position"]?.int ?? 0
    }

    init(id: Int64, name: String, rule: SelectionRule) {
        self.id = id
        self.name = name
        self.rule = rule
        unread = 0
        total = 0
        revision = 1
        position = 0
    }
}

struct Recipe: Identifiable, Equatable, Sendable {
    let id: Int64
    var name: String
    var text: String
    var revision: Int64
    var builtIn: Bool
    var updatedAt: Date?
    var usedBy: Int64?

    init?(_ j: JSON) {
        guard let id = j["id"]?.int else { return nil }
        self.id = id
        name = j["name"]?.string ?? "Recipe"
        text = j["text"]?.string ?? ""
        revision = j["revision"]?.int ?? 1
        builtIn = j["builtin", "builtIn", "hasBuiltin"]?.bool ?? (j["builtinText"] != nil)
        updatedAt = Date(daemon: j["updatedAt", "createdAt"])
        usedBy = j["usedBy", "routines"]?.int
    }
}

struct RecipeRevision: Identifiable, Equatable, Sendable {
    let revision: Int64
    let text: String?
    let note: String
    let createdAt: Date?
    var id: Int64 { revision }

    init?(_ j: JSON) {
        guard let revision = j["revision"]?.int else { return nil }
        self.revision = revision
        text = j["text"]?.string
        note = j["note"]?.string ?? ""
        createdAt = Date(daemon: j["createdAt"])
    }
}

struct Writer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Installed and signed in: a brief can be written.
    let found: Bool
    /// On this Mac, whether or not it is signed in.
    let installed: Bool
    let path: String?
    let version: String?
    let selected: Bool
    let problem: String?
    /// The Claude Code profile folder in use; nil means Claude Code's default.
    let profile: String?

    init?(_ j: JSON) {
        guard let id = j["id", "writer", "name"]?.string else { return nil }
        self.id = id
        name = j["label", "displayName", "title"]?.string ?? (id == "claude" ? "Claude Code" : id == "codex" ? "Codex" : id)
        found = j["found", "available"]?.bool ?? false
        installed = j["installed"]?.bool ?? found
        profile = j["profile"]?.string
        path = j["path"]?.string
        version = j["version"]?.string
        selected = j["selected", "default"]?.bool ?? false
        problem = j["error", "problem", "lastError"]?.string
    }
}

/// One numbered source of a brief or answer.
struct Citation: Identifiable, Equatable, Sendable {
    let number: Int
    let entryId: Int64
    let title: String
    let feedTitle: String?
    let snippet: String?
    let url: String?
    let date: Date?
    var read: Bool
    var id: Int { number }

    init?(_ j: JSON, fallback: Int) {
        guard let entry = j["entryId", "id"]?.int else { return nil }
        number = Int(j["n", "number", "index"]?.int ?? Int64(fallback))
        entryId = entry
        title = j["title"]?.string ?? "Untitled"
        feedTitle = j["feedTitle", "feed"]?.string
        snippet = j["snippet", "quote", "summary"]?.string
        url = j["url"]?.string
        date = Date(daemon: j["sortAt", "publishedAt", "date"])
        read = j["read"]?.bool ?? false
    }
}

/// One claim of a written section and the sources it cites.
struct Claim: Equatable, Sendable {
    let text: String
    let sources: [Int]
}

struct Section: Equatable, Sendable {
    let heading: String?
    let claims: [Claim]
}

/// A brief or an answer: generated text, labeled with who wrote it and from what.
struct Artifact: Identifiable, Equatable, Sendable {
    let id: Int64
    let kind: String
    let title: String
    let question: String?
    let createdAt: Date?
    let viewId: Int64?
    let viewName: String?
    let rule: SelectionRule?
    let writer: String?
    let recipeId: Int64?
    let recipeName: String?
    let recipeRevision: Int64?
    let inputCount: Int64
    let omittedCount: Int64
    let durationSeconds: Int64?
    let sections: [Section]
    let citations: [Citation]

    init?(_ j: JSON) {
        guard let id = j["id"]?.int else { return nil }
        self.id = id
        kind = j["kind"]?.string ?? "digest"
        title = j["title"]?.string ?? "Brief"
        question = j["question"]?.string
        createdAt = Date(daemon: j["createdAt"])
        viewId = j["viewId"]?.int
        viewName = j["viewName"]?.string
        rule = j["rule", "ruleJson"]?.parsed?.decode(SelectionRule.self)
        writer = j["writer", "producer"]?.string
        recipeId = j["recipeId"]?.int
        recipeName = j["recipeName"]?.string
        recipeRevision = j["recipeRevision"]?.int
        inputCount = j["inputCount"]?.int ?? 0
        omittedCount = j["omittedCount"]?.int ?? 0
        durationSeconds = j["durationMs"]?.int.map { $0 / 1000 } ?? j["durationSeconds"]?.int
        let sources = (j["citations", "sources", "citationsJson"]?.parsed?.array ?? [])
        citations = sources.enumerated().compactMap { Citation($1, fallback: $0 + 1) }
        sections = Artifact.sections(j, citations: citations)
    }

    /// Writers return sections of claims. A record may carry them as they came, or
    /// as blocks where each claim is a paragraph with citation nodes.
    private static func sections(_ j: JSON, citations: [Citation]) -> [Section] {
        if let raw = j["sections"]?.parsed?.array, !raw.isEmpty {
            return raw.map { section in
                Section(heading: section["heading"]?.string, claims: (section["claims"]?.array ?? []).map {
                    Claim(text: $0["text"]?.string ?? "", sources: $0["sources"]?.array.compactMap { $0.int.map(Int.init) } ?? [])
                })
            }
        }
        let blocks = j["blocks", "body", "bodyBlocksJson"]?.parsed?.array ?? []
        var out: [Section] = []
        var heading: String?
        var claims: [Claim] = []
        func flush() {
            if heading != nil || !claims.isEmpty { out.append(Section(heading: heading, claims: claims)) }
            heading = nil
            claims = []
        }
        // A source given by entry id becomes its number in the list.
        let numberOf = Dictionary(citations.map { ($0.entryId, $0.number) }, uniquingKeysWith: { a, _ in a })
        func claim(_ nodes: [JSON]) -> Claim {
            var text = ""
            var sources: [Int] = []
            for node in nodes {
                let kind = node["t"]?.string ?? ""
                if kind == "link", let href = node["href"]?.string, href.hasPrefix("fyke://entry/"), let entry = Int64(href.dropFirst(13)) {
                    sources.append(numberOf[entry] ?? Int(entry))
                } else if kind == "cite" || kind == "citation" {
                    if let n = node["n"]?.int { sources.append(Int(n)) }
                    else if let entry = node["entryId", "entry"]?.int, let n = numberOf[entry] { sources.append(n) }
                    else if let v = node["v"]?.string.flatMap({ Int($0) }) { sources.append(v) }
                    for id in node["sources"]?.array ?? [] { if let n = id.int { sources.append(numberOf[n] ?? Int(n)) } }
                } else if let v = node["v"]?.string {
                    text += v
                } else if let children = node["c"]?.array {
                    let inner = claim(children)
                    text += inner.text
                    sources += inner.sources
                }
            }
            return Claim(text: text.trimmingCharacters(in: .whitespaces), sources: sources)
        }
        for block in blocks {
            switch block["t"]?.string {
            case "h", "h2", "h3", "heading":
                flush()
                heading = block["v"]?.string ?? claim(block["c"]?.array ?? []).text
            case "claim":
                claims.append(Claim(text: block["v", "text"]?.string ?? "", sources: (block["sources"]?.array ?? []).compactMap { $0.int.map { numberOf[$0] ?? Int($0) } }))
            default:
                claims.append(claim(block["c"]?.array ?? [block]))
            }
        }
        flush()
        return out
    }
}

/// Background work, as the Activity popover lists it.
struct Job: Identifiable, Equatable, Sendable {
    enum State: String, Sendable { case queued, running, done, failed, cancelled }

    let id: Int64
    let kind: String
    let state: State
    let title: String
    let error: String?
    let progress: Int64?
    let total: Int64?
    let createdAt: Date?
    let finishedAt: Date?
    let artifactId: Int64?
    let writer: String?
    let routineId: Int64?

    init?(_ j: JSON) {
        guard let id = j["id"]?.int else { return nil }
        self.id = id
        let input = j["input"]?.parsed
        // A trial of a recipe is a brief that is not kept.
        let stage = j["kind", "stage"]?.string ?? "job"
        kind = input?["preview"]?.bool == true ? "try" : stage
        routineId = input?["routineId"]?.int
        state = State(rawValue: j["status", "state"]?.string ?? "") ?? .queued
        error = j["error"]?.string
        progress = j["progress", "done"]?.int
        total = j["total"]?.int
        createdAt = Date(daemon: j["createdAt", "startedAt"])
        finishedAt = Date(daemon: j["finishedAt"])
        artifactId = j["artifactId", "resultId"]?.int
        writer = j["writer"]?.string ?? input?["writer"]?.string
        title = j["title", "label", "description"]?.string ?? Job.defaultTitle(kind)
    }

    static func defaultTitle(_ kind: String) -> String {
        switch kind {
        case "brief", "digest", "synthesize": "Writing a brief"
        case "try", "brief_try": "Trying a recipe"
        case "answer", "ask": "Answering a question"
        case "routine": "Running a routine"
        case "refresh": "Refreshing feeds"
        default: kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    var isActive: Bool { state == .queued || state == .running }
    var isWriting: Bool { ["brief", "digest", "synthesize", "try", "brief_try", "answer", "ask"].contains(kind) }
}

/// What a routine does after it finds its matches.
struct RoutineAction: Equatable, Hashable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Sendable { case brief, notify, markRead = "mark_read", star, tag }

    var kind: Kind
    var recipeId: Int64?
    var tag: String?
    let id = UUID()

    init(kind: Kind, recipeId: Int64? = nil, tag: String? = nil) {
        self.kind = kind
        self.recipeId = recipeId
        self.tag = tag
    }

    init?(_ j: JSON) {
        guard let raw = j["kind", "type", "action"]?.string, let kind = Kind(rawValue: raw) else { return nil }
        self.kind = kind
        recipeId = j["recipeId"]?.int
        tag = j["tag"]?.string
    }

    static func == (a: Self, b: Self) -> Bool { a.kind == b.kind && a.recipeId == b.recipeId && a.tag == b.tag }
    func hash(into h: inout Hasher) { h.combine(kind); h.combine(recipeId); h.combine(tag) }

    var wire: [String: AnyEncodable] {
        var out: [String: AnyEncodable] = ["kind": AnyEncodable(kind.rawValue)]
        if let recipeId { out["recipe_id"] = AnyEncodable(recipeId) }
        if let tag { out["tag"] = AnyEncodable(tag) }
        return out
    }
}

struct Routine: Identifiable, Equatable, Sendable {
    var id: Int64?
    var name: String
    var viewId: Int64?
    var schedule: Schedule
    var actions: [RoutineAction]
    var enabled: Bool
    var revision: Int64?
    var nextRunAt: Date?
    var lastRunAt: Date?
    var lastMatches: Int64?

    init(name: String, viewId: Int64?) {
        self.name = name
        self.viewId = viewId
        schedule = Schedule(kind: .weekdays, time: "07:30")
        actions = [RoutineAction(kind: .brief, recipeId: 1), RoutineAction(kind: .notify)]
        enabled = true
    }

    init?(_ j: JSON) {
        guard let id = j["id"]?.int else { return nil }
        self.id = id
        name = j["name"]?.string ?? "Routine"
        viewId = j["viewId"]?.int
        schedule = (j["schedule", "scheduleJson", "when"]?.parsed)?.decode(Schedule.self) ?? Schedule(kind: .manual)
        actions = (j["actions", "actionsJson"]?.parsed?.array ?? []).compactMap(RoutineAction.init)
        enabled = j["enabled"]?.bool ?? true
        revision = j["revision"]?.int
        nextRunAt = Date(daemon: j["nextRunAt"])
        lastRunAt = Date(daemon: j["lastRunAt"])
        lastMatches = j["lastMatches"]?.int
    }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.name == b.name && a.viewId == b.viewId && a.schedule == b.schedule && a.actions == b.actions && a.enabled == b.enabled
    }
}

struct DryRun: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        let label: String
        let count: Int
    }

    let days: [Day]
    let actions: [String]

    init(_ j: JSON) {
        let list = j["days", "perDay"]?.array ?? []
        days = list.map { day in
            let date = day["date", "day"]?.string ?? ""
            let parsed = ISO8601DateFormatter.day.date(from: date) ?? Date(daemon: day["start", "at"])
            let label = parsed.map { $0.formatted(.dateTime.weekday(.narrow)) } ?? String(date.suffix(2))
            return Day(label: label, count: Int(day["matches", "count"]?.int ?? 0))
        }
        actions = (j["actions"]?.array ?? []).compactMap { $0["summary", "text", "result"]?.string ?? $0.string }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let day: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = .current
        return f
    }()
}

/// Encodes any value, for parameters assembled at run time.
struct AnyEncodable: Encodable, @unchecked Sendable {
    private let run: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { run = value.encode }
    func encode(to encoder: Encoder) throws { try run(encoder) }
}

/// The reading state before a mark, so that the mark can be taken back.
struct Previous: Decodable, Sendable, Equatable {
    let id: Int64?
    let read: Bool?
    let starred: Bool?
    let later: Bool?

    init(from decoder: Decoder) throws {
        let j = try JSON(from: decoder)
        id = j["id", "entryId"]?.int
        // A state is set when its time is.
        read = j["read"]?.bool ?? (j["readAt"] != nil)
        starred = j["starred"]?.bool ?? (j["starredAt"] != nil)
        later = j["later"]?.bool ?? (j["laterAt"] != nil)
    }
}

/// The selector's rule. `Rule` alone names the hairline view in this target.
typealias SelectionRule = ReaderLogic.Rule
