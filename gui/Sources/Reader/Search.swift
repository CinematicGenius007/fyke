// The search popup. Its state lives in SearchModel, so that opening it leaves the
// list and the reader behind it untouched.
import Observation
import SwiftUI

@MainActor @Observable
final class SearchModel {
    var isShowing = false
    var query = ""
    var results: [EntrySummary] = []
    var selection = 0
    var unreadOnly = false
    /// True once the current query has an answer, so that a slow reply does not
    /// flash "nothing found".
    var hasAnswer = false

    private var pending: Task<Void, Never>?

    private struct Params: Encodable, Sendable {
        var query: String
        var limit: Int
        var unreadOnly: Bool
    }

    static let limit = 100
    private static let typingPause = Duration.milliseconds(150)

    var words: [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }
    var isBlank: Bool { words.isEmpty }

    var countLabel: String? {
        guard hasAnswer, !results.isEmpty else { return nil }
        if results.count == Self.limit { return "\(Self.limit)+ results" }
        return results.count == 1 ? "1 result" : "\(results.count) results"
    }

    func show() {
        isShowing = true
    }

    func close() {
        pending?.cancel()
        isShowing = false
        query = ""
        results = []
        selection = 0
        hasAnswer = false
    }

    func toggleUnreadOnly() {
        unreadOnly.toggle()
        run()
    }

    func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + offset, 0), results.count - 1)
    }

    /// Waits for a pause in typing, so that each word costs one request.
    func run() {
        pending?.cancel()
        hasAnswer = false
        guard !isBlank else {
            results = []
            selection = 0
            return
        }
        let params = Params(query: query, limit: Self.limit, unreadOnly: unreadOnly)
        pending = Task {
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled else { return }
            let found: Items<EntrySummary>? = try? await Daemon.shared.call("entries.search", params)
            guard !Task.isCancelled else { return }
            results = found?.items ?? []
            selection = 0
            hasAnswer = true
        }
    }
}

/// A panel near the top of the window, over the scrim.
struct SearchPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 64
    private static let rowGap: CGFloat = 2
    private static let visibleRows = 8

    private var search: SearchModel { model.search }
    private var ground: Color { p.isDark ? p.surface : p.ground }

    var body: some View {
        ZStack(alignment: .top) {
            p.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { search.close() }
            VStack(spacing: 0) {
                queryRow
                Rule()
                content
                Rule()
                footer
            }
            .frame(width: 640)
            .background(ground, in: RoundedRectangle(cornerRadius: Radii.sheet))
            .overlay(RoundedRectangle(cornerRadius: Radii.sheet).stroke(p.control))
            .padding(.top, 96)
        }
        .onAppear { focused = true }
    }

    private var queryRow: some View {
        @Bindable var search = search
        return HStack(spacing: 12) {
            Icon(glyph: .search, color: p.muted)
            TextField("", text: $search.query, prompt: Text("Search your feeds").foregroundStyle(p.muted))
                .textFieldStyle(.plain)
                .font(.ui(20))
                .focused($focused)
                .onChange(of: search.query) { search.run() }
                .onSubmit(openSelected)
                .onExitCommand { search.close() }
                .onKeyPress(.upArrow) { search.move(-1); return .handled }
                .onKeyPress(.downArrow) { search.move(1); return .handled }
            if let label = search.countLabel {
                Text(label).font(.ui(13)).foregroundStyle(p.muted)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
    }

    @ViewBuilder private var content: some View {
        if search.isBlank {
            VStack(alignment: .leading, spacing: 4) {
                Text("Finds words in titles, article text and feed names.").font(.ui(14)).foregroundStyle(p.inkSoft)
                Text("Every word must match. Results come newest first.").font(.ui(13)).foregroundStyle(p.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 22)
        } else if search.results.isEmpty {
            nothingFound
        } else {
            results
        }
    }

    @ViewBuilder private var nothingFound: some View {
        if search.hasAnswer {
            VStack(alignment: .leading, spacing: 4) {
                ReadingText("Nothing matches “\(search.query)”.", size: 21)
                Text("Try fewer or related words.").font(.ui(14)).foregroundStyle(p.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 22)
        } else {
            Color.clear.frame(height: 40)
        }
    }

    private var results: some View {
        let rows = min(search.results.count, Self.visibleRows)
        let height = CGFloat(rows) * (Self.rowHeight + Self.rowGap) - Self.rowGap + 16
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Self.rowGap) {
                    ForEach(Array(search.results.enumerated()), id: \.element.id) { index, row in
                        rowView(row, selected: index == search.selection).id(row.id)
                    }
                }
                .padding(8)
            }
            .themedScrollbar()
            .frame(height: height)
            .onChange(of: search.selection) { _, index in
                guard search.results.indices.contains(index) else { return }
                proxy.scrollTo(search.results[index].id)
            }
        }
    }

    private func rowView(_ row: EntrySummary, selected: Bool) -> some View {
        Button { model.openResult(row.id) } label: {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    ReadingText(row.title ?? "Untitled", size: 18, color: row.read ? p.read : p.unread)
                    if let text = row.preview {
                        Text(highlighted(text)).font(.ui(13)).foregroundStyle(p.inkSoft).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(row.feedTitle ?? "").lineLimit(1)
                    Text(Dates.relative(row.date))
                }
                .font(.ui(13)).foregroundStyle(p.muted)
                .frame(width: 104, alignment: .trailing)
                .padding(.top, 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(height: Self.rowHeight)
            .background(selected ? p.selected : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Marks each searched word in the snippet.
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text.replacingOccurrences(of: "...", with: "…"))
        for word in search.words {
            var start = result.startIndex
            while let range = result[start...].range(of: word, options: .caseInsensitive) {
                result[range].foregroundColor = p.ink
                result[range].font = .ui(13, .semibold)
                start = range.upperBound
            }
        }
        return result
    }

    private var footer: some View {
        HStack {
            Button(action: search.toggleUnreadOnly) {
                Text(search.unreadOnly ? "Unread only" : "All articles")
                    .font(.ui(13, .medium)).foregroundStyle(p.inkSoft)
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: 16) {
                Text("↑↓ Move")
                Text("Return Open")
                Text("Esc Close")
            }
            .font(.ui(13)).foregroundStyle(p.muted)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func openSelected() {
        guard search.results.indices.contains(search.selection) else { return }
        model.openResult(search.results[search.selection].id)
    }
}

/// One line in the title font, as result titles and the empty message use it.
private struct ReadingText: View {
    @Environment(\.titleFamily) private var family
    @Environment(\.palette) private var p
    let text: String
    let size: CGFloat
    var color: Color?

    init(_ text: String, size: CGFloat, color: Color? = nil) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.custom(family, fixedSize: size).weight(.medium))
            .foregroundStyle(color ?? p.ink)
            .lineLimit(1)
    }
}
