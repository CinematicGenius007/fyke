// Pure pieces of the interface: they decide, and the views draw what they decide.
import Foundation

// MARK: Sidebar indent

/// Indent is `10 + 22 × depth`. 22 is the icon (14) and the gap (8), so a row one
/// level down starts where its parent's text starts. It is computed here, once, and
/// every row at one depth uses the same value, so siblings always line up.
public enum SidebarIndent {
    public static let edge: Double = 10
    public static let icon: Double = 14
    public static let gap: Double = 8
    public static var step: Double { icon + gap }

    public static func leading(depth: Int) -> Double { edge + step * Double(max(depth, 0)) }

    /// Folders draw a chevron in the icon column, feeds draw none, so a feed's name starts
    /// where its depth's icon would. Inside a folder a feed is a child: its name starts one
    /// step inside the folder's name, level with a sibling folder's name. A feed at the top
    /// level sits at depth 1, so its name lines up with All, Starred and top-level folders.
    public static func feedDepth(folderDepth: Int?) -> Int { folderDepth.map { $0 + 2 } ?? 1 }

    /// Where the text of a row starts.
    public static func textStart(depth: Int, hasIcon: Bool) -> Double {
        leading(depth: depth) + (hasIcon ? step : 0)
    }
}

// MARK: Undo

/// Changes that can be taken back, newest last. Bulk actions push here instead of
/// asking first, and ⌘Z pops.
public struct UndoStack<Item> {
    public private(set) var items: [Item] = []
    public let limit: Int

    public init(limit: Int = 100) { self.limit = limit }

    public mutating func push(_ item: Item) {
        items.append(item)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    public mutating func pop() -> Item? { items.popLast() }
    public var last: Item? { items.last }
    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
}

// MARK: Fuzzy match

/// Matches typed letters to a title in order, with gaps allowed. Runs of letters and
/// letters at the start of a word score higher, so "dbn" finds "Database Notes" and
/// ranks it above a title where the letters are scattered.
public enum Fuzzy {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Character offsets in the candidate that matched, for highlighting.
        public let positions: [Int]

        public init(score: Int, positions: [Int]) {
            self.score = score
            self.positions = positions
        }
    }

    public static func match(_ query: String, in candidate: String) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, positions: []) }
        let hay = Array(candidate.lowercased())
        let original = Array(candidate)
        var positions: [Int] = []
        var score = 0
        var at = 0
        var previous = -2
        for letter in needle {
            guard let found = (at..<hay.count).first(where: { hay[$0] == letter }) else { return nil }
            var points = 1
            if found == previous + 1 { points += 5 }
            if found == 0 || !(original[found - 1].isLetter || original[found - 1].isNumber) { points += 8 }
            else if original[found].isUppercase && original[found - 1].isLowercase { points += 4 }
            score += points
            positions.append(found)
            previous = found
            at = found + 1
        }
        // A whole-word prefix is what people mean most often.
        if hay.starts(with: needle) { score += 10 }
        // Shorter titles win ties: the match explains more of them.
        return Match(score: score * 100 - hay.count, positions: positions)
    }

    /// Candidates that match, best first. Equal scores keep their given order, so
    /// destinations stay above commands.
    public static func rank<T>(_ query: String, _ items: [T], text: (T) -> String) -> [(item: T, match: Match)] {
        items.enumerated()
            .compactMap { index, item in match(query, in: text(item)).map { (index, item, $0) } }
            .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }
}

// MARK: Catch up

/// Walks a list of articles one at a time. Each decision is remembered, so the last
/// one can be taken back and the article shown again.
public struct CatchUpSession<ID: Hashable> {
    public enum Decision: String, Sendable { case skip, later, read }

    public private(set) var queue: [ID]
    public private(set) var index = 0
    public private(set) var history: [(id: ID, decision: Decision)] = []

    public init(_ queue: [ID]) { self.queue = queue }

    public var current: ID? { queue.indices.contains(index) ? queue[index] : nil }
    public var isDone: Bool { index >= queue.count }
    public var progress: Double { queue.isEmpty ? 1 : Double(index) / Double(queue.count) }

    public func count(_ decision: Decision) -> Int { history.filter { $0.decision == decision }.count }

    @discardableResult
    public mutating func decide(_ decision: Decision) -> ID? {
        guard let id = current else { return nil }
        history.append((id, decision))
        index += 1
        return id
    }

    /// Puts the last decided article back in front.
    public mutating func undo() -> (id: ID, decision: Decision)? {
        guard let last = history.popLast() else { return nil }
        index = max(index - 1, 0)
        return last
    }
}

// MARK: Routine schedule

/// When a routine runs. Mirrors the `when` object in the routines operations.
public struct Schedule: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case manual, daily, weekdays, weekly }

    public var kind: Kind
    /// "HH:MM", in the computer's time zone.
    public var time: String?
    /// ISO weekdays, 1 for Monday through 7 for Sunday.
    public var days: [Int]?

    public init(kind: Kind, time: String? = nil, days: [Int]? = nil) {
        self.kind = kind
        self.time = time
        self.days = days
    }

    static let dayNames = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
    static let shortDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// The first chip of the When line.
    public var repeatWords: String {
        switch kind {
        case .manual: "Only when I run it"
        case .daily: "Every day"
        case .weekdays: "Every weekday"
        case .weekly:
            switch (days ?? []).sorted() {
            case []: "Every week"
            case let one where one.count == 1: "Every " + Self.dayNames[(one[0] - 1) % 7].dropLast()
            case let many: "On " + many.map { Self.shortDays[($0 - 1) % 7] }.joined(separator: ", ")
            }
        }
    }

    /// One line, as the routine list shows it: "Weekdays 07:30".
    public var summary: String {
        switch kind {
        case .manual: "Manual"
        case .daily: "Daily \(time ?? "")".trimmingCharacters(in: .whitespaces)
        case .weekdays: "Weekdays \(time ?? "")".trimmingCharacters(in: .whitespaces)
        case .weekly: "\(repeatWords.replacingOccurrences(of: "Every ", with: "")) \(time ?? "")".trimmingCharacters(in: .whitespaces)
        }
    }

    /// Every half hour of the day, for the time chip's menu.
    public static var halfHours: [String] {
        (0..<48).map { String(format: "%02d:%02d", $0 / 2, $0 % 2 * 30) }
    }
}

// MARK: Dry run

public enum DryRunWords {
    /// "Would have caught 38 articles over 5 days, about 8 each."
    public static func summary(counts: [Int]) -> String {
        let total = counts.reduce(0, +)
        let days = counts.filter { $0 > 0 }.count
        guard total > 0 else { return "Nothing would have matched last week." }
        let noun = total == 1 ? "article" : "articles"
        if days <= 1 { return "Would have caught \(total) \(noun) on one day." }
        let each = Int((Double(total) / Double(days)).rounded())
        return "Would have caught \(total) \(noun) over \(days) days, about \(each) each."
    }

    /// Bar heights from 0 to 1, against the busiest day. A day with any match is at
    /// least a sliver, so it never looks the same as an empty day.
    public static func bars(_ counts: [Int]) -> [Double] {
        let top = Double(counts.max() ?? 0)
        guard top > 0 else { return counts.map { _ in 0 } }
        return counts.map { $0 == 0 ? 0 : max(0.12, Double($0) / top) }
    }
}

// MARK: Counting words

public enum Plural {
    public static func count(_ number: Int, _ noun: String, _ plural: String? = nil) -> String {
        "\(number.formatted()) \(number == 1 ? noun : plural ?? noun + "s")"
    }
}

/// The line under a brief's or an answer's sources. Articles that matched but did not fit
/// were never read, so that comes first; otherwise it counts what was read but not cited.
/// Windows has the same wording in `BriefText.SourcesNote`.
public enum SourcesNote {
    public static func text(omitted: Int, read: Int, cited: Int) -> String? {
        if omitted > 0 { return "\(Plural.count(omitted, "more article")) matched but did not fit, so the writer did not read them." }
        return read > cited ? "\(Plural.count(read - cited, "more", "more")) read but not cited" : nil
    }
}
