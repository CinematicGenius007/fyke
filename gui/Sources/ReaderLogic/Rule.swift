// A rule says which articles a view holds. It mirrors `Rule` in src/selector.zig,
// which validates it; this side only shows it and edits it.
import Foundation

public struct Rule: Codable, Equatable, Hashable, Sendable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case any, unread, starred, later
    }

    public var feeds: [Int64]?
    public var folders: [Int64]?
    public var state: State?
    public var words: String?
    public var anyWords: Bool?
    public var host: String?
    public var subdomains: Bool?
    public var pathPrefix: String?
    public var excludePathPrefix: [String]?
    public var withinDays: Int?

    public init(
        feeds: [Int64]? = nil, folders: [Int64]? = nil, state: State? = nil, words: String? = nil, anyWords: Bool? = nil,
        host: String? = nil, subdomains: Bool? = nil, pathPrefix: String? = nil, excludePathPrefix: [String]? = nil, withinDays: Int? = nil
    ) {
        self.feeds = feeds
        self.folders = folders
        self.state = state
        self.words = words
        self.anyWords = anyWords
        self.host = host
        self.subdomains = subdomains
        self.pathPrefix = pathPrefix
        self.excludePathPrefix = excludePathPrefix
        self.withinDays = withinDays
    }

    /// The daemon writes every field back, with empty lists and defaults. Two rules
    /// that select the same articles compare equal after this.
    public var normalized: Rule {
        var rule = self
        if rule.feeds?.isEmpty == true { rule.feeds = nil }
        if rule.folders?.isEmpty == true { rule.folders = nil }
        if rule.state == .any { rule.state = nil }
        if rule.words.map(Self.blank) ?? false { rule.words = nil }
        if rule.words == nil || rule.anyWords == false { rule.anyWords = nil }
        if rule.host.map(Self.blank) ?? false { rule.host = nil }
        if rule.host == nil || rule.subdomains == false { rule.subdomains = nil }
        if rule.pathPrefix.map(Self.blank) ?? false { rule.pathPrefix = nil }
        if rule.excludePathPrefix?.isEmpty == true { rule.excludePathPrefix = nil }
        return rule
    }

    static func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The rule a search becomes when it is kept. Search matches every word, so the
    /// view does too.
    public static func fromSearch(_ query: String, unreadOnly: Bool) -> Rule {
        let words = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return Rule(state: unreadOnly ? .unread : nil, words: words.isEmpty ? nil : words).normalized
    }
}

// MARK: Editing

/// One part of a rule, as the sentence shows it and as one tap changes it.
public enum Clause: String, CaseIterable, Sendable {
    case state, scope, words, host, path, exclude, within
}

extension Rule {
    public mutating func setState(_ state: State) {
        self.state = state
        self = normalized
    }

    public mutating func setScope(feeds: [Int64], folders: [Int64]) {
        self.feeds = feeds
        self.folders = folders
        self = normalized
    }

    /// Words are tokens, never syntax: runs of space collapse, and nothing is quoted.
    public mutating func setWords(_ text: String, any: Bool) {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.words = words.isEmpty ? nil : String(words.prefix(200))
        anyWords = any
        self = normalized
    }

    public mutating func setHost(_ text: String, subdomains: Bool) {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // People paste addresses. Only the host is kept.
        if let url = URL(string: host), let found = url.host() { host = found }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
        self.host = host.isEmpty ? nil : host
        self.subdomains = subdomains
        self = normalized
    }

    /// A path always starts with a slash, which people often leave out.
    public static func path(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    public mutating func setPath(_ text: String) {
        pathPrefix = Self.path(text)
        self = normalized
    }

    public mutating func addExclude(_ text: String) {
        guard let path = Self.path(text) else { return }
        var list = excludePathPrefix ?? []
        if !list.contains(path) { list.append(path) }
        excludePathPrefix = list
        self = normalized
    }

    public mutating func removeExclude(_ path: String) {
        excludePathPrefix?.removeAll { $0 == path }
        self = normalized
    }

    public mutating func setWithin(_ days: Int?) {
        withinDays = days.map { min(max($0, 1), 3650) }
    }

    public mutating func clear(_ clause: Clause) {
        switch clause {
        case .state: state = nil
        case .scope: feeds = nil; folders = nil
        case .words: words = nil; anyWords = nil
        case .host: host = nil; subdomains = nil
        case .path: pathPrefix = nil
        case .exclude: excludePathPrefix = nil
        case .within: withinDays = nil
        }
        self = normalized
    }

    /// Clauses a person can still add, in sentence order.
    public var missing: [Clause] {
        let rule = normalized
        var out: [Clause] = []
        if rule.words == nil { out.append(.words) }
        if rule.host == nil { out.append(.host) }
        if rule.pathPrefix == nil { out.append(.path) }
        out.append(.exclude)
        if rule.withinDays == nil { out.append(.within) }
        return out
    }
}

// MARK: Sentence

/// The rule as words, some of which can be tapped. "Unread from Engineering about
/// storage or query skipping /jobs/" is two joiners and four chips.
public enum SentencePart: Equatable, Sendable {
    case chip(Clause, String, value: String? = nil)
    case joiner(String)

    public var text: String {
        switch self {
        case .chip(_, let text, _), .joiner(let text): text
        }
    }
}

public enum RuleSentence {
    public static func stateWord(_ state: Rule.State?) -> String {
        switch state ?? .any {
        case .any: "All"
        case .unread: "Unread"
        case .starred: "Starred"
        case .later: "Later"
        }
    }

    public static func withinWords(_ days: Int) -> String {
        switch days {
        case 1: "last day"
        case 7: "last week"
        case 30, 31: "last month"
        default: "last \(days) days"
        }
    }

    /// Names that a deleted feed or folder no longer has read "Deleted source", as the
    /// daemon's sentence does.
    public static func parts(_ rule: Rule, feedName: (Int64) -> String?, folderName: (Int64) -> String?) -> [SentencePart] {
        let rule = rule.normalized
        var parts: [SentencePart] = [.chip(.state, stateWord(rule.state)), .joiner("from")]
        let names = (rule.folders ?? []).map { folderName($0) ?? "Deleted source" } + (rule.feeds ?? []).map { feedName($0) ?? "Deleted source" }
        parts.append(.chip(.scope, scopeWords(names)))
        if let words = rule.words {
            parts.append(.joiner("about"))
            let tokens = words.split(separator: " ").map(String.init)
            parts.append(.chip(.words, tokens.joined(separator: rule.anyWords == true ? " or " : " "), value: words))
        }
        if let host = rule.host {
            parts.append(.joiner("on"))
            parts.append(.chip(.host, rule.subdomains == true ? "any \(host)" : host, value: host))
        }
        if let path = rule.pathPrefix {
            parts.append(.joiner("under"))
            parts.append(.chip(.path, path))
        }
        for (index, path) in (rule.excludePathPrefix ?? []).enumerated() {
            parts.append(.joiner(index == 0 ? "skipping" : "and"))
            parts.append(.chip(.exclude, path, value: path))
        }
        if let days = rule.withinDays {
            parts.append(.joiner("from the"))
            parts.append(.chip(.within, withinWords(days)))
        }
        return parts
    }

    static func scopeWords(_ names: [String]) -> String {
        switch names.count {
        case 0: "all feeds"
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names[0]) and \(names.count - 1) more"
        }
    }

    /// The sentence as one line, for accessibility labels and the palette.
    public static func text(_ parts: [SentencePart]) -> String {
        parts.map(\.text).joined(separator: " ")
    }
}

/// The name a kept search starts with. The person can change it straight away.
public enum ViewName {
    public static func suggest(for rule: Rule) -> String {
        let rule = rule.normalized
        guard let words = rule.words else { return RuleSentence.stateWord(rule.state) == "All" ? "New view" : RuleSentence.stateWord(rule.state) }
        let joined = words.split(separator: " ").joined(separator: rule.anyWords == true ? " or " : " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// A name that no other view has, by adding a number.
    public static func unique(_ name: String, taken: Set<String>) -> String {
        if !taken.contains(name) { return name }
        return (2...999).lazy.map { "\(name) \($0)" }.first { !taken.contains($0) } ?? name
    }
}
