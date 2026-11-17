// The comments beside an article. A Hacker News thread is read into the reader, under
// the article, from `entries.discussion`. Any other discussion page is a link.
import AppKit
import SwiftUI

struct DiscussionComment: Decodable, Sendable, Identifiable {
    let id: Int64
    /// Nil when the comment was deleted. Its replies stay in place under it.
    let author: String?
    let at: Int64?
    let depth: Int
    let blocks: [Block]
}

struct Discussion: Decodable, Sendable {
    let source: String
    let url: String
    let comments: [DiscussionComment]
    let truncated: Bool
}

enum DiscussionLoad {
    case idle, loading, loaded(Discussion), failed(String)
}

enum Discussions {
    /// The thread number of a Hacker News discussion page, as the daemon reads it.
    static func hackerNewsId(_ url: URL?) -> Int64? {
        guard let url, url.scheme == "https" || url.scheme == "http",
              url.host()?.lowercased() == "news.ycombinator.com", url.path() == "/item" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "id" }?.value.flatMap { Int64($0) }
    }

    static func hackerNewsId(_ text: String?) -> Int64? {
        hackerNewsId(text.flatMap { URL(string: $0) })
    }
}

/// The comments under an article. It stays one quiet line until asked, since a thread
/// costs a request and most articles are read without one.
struct DiscussionSection: View {
    let entry: Entry
    let size: Double
    let spacing: Double
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var collapsed: Set<Int64> = []

    var body: some View {
        if let address = entry.discussionUrl, let url = URL(string: address), Links.isSafe(url) {
            VStack(alignment: .leading, spacing: 0) {
                Rule().padding(.top, 16).padding(.bottom, 24)
                if Discussions.hackerNewsId(url) != nil {
                    thread(url)
                } else {
                    header("Discussion", detail: url.host() ?? address) {
                        Button("Open discussion") { model.openLink(url) }.buttonStyle(ActionStyle(kind: .secondary))
                    }
                }
            }
            .id(DiscussionSection.anchor)
        }
    }

    static let anchor = "discussion"

    @ViewBuilder private func thread(_ url: URL) -> some View {
        switch model.discussion {
        case .idle:
            header("Comments on Hacker News", detail: "Read the thread here, under the article.") {
                Button("Show comments") { model.showDiscussion() }.buttonStyle(ActionStyle(kind: .secondary))
            }
        case .loading:
            HStack(spacing: 8) {
                Spinner(size: 12)
                Text("Loading comments from Hacker News…").font(.ui(13)).foregroundStyle(p.muted)
            }
        case .failed(let text):
            header("The comments did not load", detail: "\(text) The article is unaffected.") {
                HStack(spacing: 8) {
                    Button("Try again") { model.loadDiscussion() }.buttonStyle(ActionStyle(kind: .secondary))
                    Button("Open on Hacker News") { model.openLink(url) }.buttonStyle(ActionStyle(kind: .link))
                }
            }
        case .loaded(let discussion):
            loaded(discussion, url)
        }
    }

    private func header(_ title: String, detail: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(15, .semibold)).foregroundStyle(p.ink)
                Text(detail).font(.ui(13)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            actions()
        }
    }

    private func loaded(_ discussion: Discussion, _ url: URL) -> some View {
        let count = discussion.comments.count
        return VStack(alignment: .leading, spacing: 0) {
            header(count == 1 ? "1 comment" : "\(count.formatted()) comments", detail: discussion.truncated ? "The first \(count.formatted()) from Hacker News. The rest are on the site." : "From Hacker News") {
                Button("Open on Hacker News") { model.openLink(url) }.buttonStyle(ActionStyle(kind: .link))
            }
            .padding(.bottom, 20)
            if count == 0 {
                Text("No one has commented yet.").font(.ui(13)).foregroundStyle(p.muted)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visible(discussion.comments)) { comment in
                    row(comment, replies: replies(of: comment, in: discussion.comments))
                }
            }
        }
    }

    /// Comments outside any collapsed reply.
    private func visible(_ comments: [DiscussionComment]) -> [DiscussionComment] {
        var shown: [DiscussionComment] = []
        var hiddenBelow: Int?
        for comment in comments {
            if let depth = hiddenBelow, comment.depth > depth { continue }
            hiddenBelow = collapsed.contains(comment.id) ? comment.depth : nil
            shown.append(comment)
        }
        return shown
    }

    private func replies(of comment: DiscussionComment, in comments: [DiscussionComment]) -> Int {
        guard let start = comments.firstIndex(where: { $0.id == comment.id }) else { return 0 }
        return comments[(start + 1)...].prefix { $0.depth > comment.depth }.count
    }

    private func row(_ comment: DiscussionComment, replies: Int) -> some View {
        let folded = collapsed.contains(comment.id)
        let depth = min(comment.depth, Metrics.replyDepths)
        return HStack(alignment: .top, spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle().fill(p.hairline).frame(width: 1).padding(.trailing, Metrics.replyIndent - 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if folded { collapsed.remove(comment.id) } else { collapsed.insert(comment.id) }
                } label: {
                    HStack(spacing: 6) {
                        Icon(glyph: folded ? .right : .down, size: 12, color: p.muted)
                        Text(comment.author ?? "Deleted comment").font(.ui(13, .semibold))
                            .foregroundStyle(comment.author == nil ? p.muted : p.ink)
                        if let at = comment.at {
                            Text(Date(timeIntervalSince1970: Double(at) / 1000).formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                                .font(.ui(13)).foregroundStyle(p.muted)
                        }
                        if folded && replies > 0 {
                            Text(replies == 1 ? "1 reply hidden" : "\(replies) replies hidden").font(.ui(13)).foregroundStyle(p.muted)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bare)
                .help(folded ? "Show this comment and its replies" : "Hide this comment and its replies")
                .accessibilityLabel("\(comment.author ?? "Deleted comment"), \(folded ? "collapsed" : "expanded")")
                if !folded && !comment.blocks.isEmpty {
                    BlocksView(blocks: comment.blocks, size: size * 0.85, spacing: spacing)
                }
            }
            .padding(.bottom, folded ? 12 : 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The browser that opens web links on this Mac, as it names itself.
enum DefaultBrowser {
    @MainActor static var current: (name: String, icon: NSImage)? {
        guard let probe = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        var name = FileManager.default.displayName(atPath: app.path(percentEncoded: false))
        if name.hasSuffix(".app") { name.removeLast(4) }
        return (name, NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false)))
    }
}
