// Wire types. These mirror the Result structs in src/ops.zig and src/store.zig.
import Foundation

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
