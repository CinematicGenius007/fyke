// ⌘K: every destination and every command in one list, matched as you type. Every
// action in the app is here, so the keyboard reaches all of it.
import Observation
import ReaderLogic
import SwiftUI

struct Command: Identifiable {
    enum Group: String { case go = "Go to", act = "Do" }

    let id: String
    let group: Group
    let title: String
    var detail: String?
    var symbol: String
    var shortcut: String?
    let run: @MainActor () -> Void
}

@MainActor @Observable
final class CommandModel {
    var isShowing = false
    var query = ""
    var selection = 0
    var articles: [EntrySummary] = []
    private var pending: Task<Void, Never>?

    func show() {
        query = ""
        selection = 0
        articles = []
        isShowing = true
    }

    func close() {
        pending?.cancel()
        isShowing = false
    }

    private struct SearchParams: Encodable, Sendable { let query: String; let limit: Int }

    func searchArticles() {
        pending?.cancel()
        selection = 0
        let words = query.trimmingCharacters(in: .whitespaces)
        guard words.count >= 2 else {
            articles = []
            return
        }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found: Items<EntrySummary>? = try? await Daemon.shared.call("entries.search", SearchParams(query: words, limit: 4))
            if !Task.isCancelled { articles = found?.items ?? [] }
        }
    }

    /// Everything the palette can do, built from what exists now.
    static func all(_ model: AppModel) -> [Command] {
        var out: [Command] = [
            Command(id: "go.today", group: .go, title: "Today", detail: "Briefs", symbol: "calendar", shortcut: "⌘1") { model.go(to: .today) },
            Command(id: "go.all", group: .go, title: "All", detail: "\(model.totalUnread) unread", symbol: "tray", shortcut: "⌘2") { model.go(to: .all) },
            Command(id: "go.starred", group: .go, title: "Starred", symbol: "star", shortcut: "⌘3") { model.go(to: .starred) },
            Command(id: "go.routines", group: .go, title: "Routines", symbol: "clock.arrow.circlepath", shortcut: "⌘4") { model.go(to: .routines) },
        ]
        for view in model.library.views {
            out.append(Command(id: "go.view\(view.id)", group: .go, title: view.name, detail: "View · \(view.unread) unread", symbol: "line.3.horizontal.decrease") { model.go(to: .view(view.id)) })
        }
        for folder in model.folders {
            out.append(Command(id: "go.folder\(folder.id)", group: .go, title: folder.name, detail: "Folder", symbol: "folder") { model.go(to: .folder(folder.id)) })
        }
        for feed in model.feeds {
            let folder = model.folders.first { $0.id == feed.folderId }?.name
            out.append(Command(id: "go.feed\(feed.id)", group: .go, title: feed.name, detail: ["Feed", folder].compactMap { $0 }.joined(separator: " · "), symbol: "dot.radiowaves.up.forward") { model.go(to: .feed(feed.id)) })
        }
        out += [
            Command(id: "do.search", group: .act, title: "Search articles", symbol: "magnifyingglass", shortcut: "⌘F") { model.search.show() },
            Command(id: "do.brief", group: .act, title: model.place.viewId != nil ? "Write a brief of this view" : "Write a brief", symbol: "doc.text", shortcut: "⌘R") { model.runBrief() },
            Command(id: "do.catchup", group: .act, title: "Catch up on \(model.placeTitle)", symbol: "rectangle.stack", shortcut: "⌘J") { model.startCatchUp() },
            Command(id: "do.ask", group: .act, title: "Ask your feeds", symbol: "sparkle", shortcut: "⇧⌘A") { model.ask.start(question: "", view: model.place.viewId, model: model) },
            Command(id: "do.routine", group: .act, title: "New routine", symbol: "plus") { model.newRoutine() },
            Command(id: "do.refresh", group: .act, title: "Refresh feeds", symbol: "arrow.clockwise", shortcut: "R") { model.refresh() },
            Command(id: "do.add", group: .act, title: "Add feed", symbol: "plus", shortcut: "⌘N") { model.showingAddFeed = true },
            Command(id: "do.folder", group: .act, title: "New folder", symbol: "folder.badge.plus") { model.newFolder(in: nil) },
            Command(id: "do.activity", group: .act, title: "Show activity", symbol: "waveform.path.ecg") { model.showingActivity = true },
            Command(id: "do.unread", group: .act, title: model.unreadOnly ? "Show all articles" : "Show unread only", symbol: "circle", shortcut: "U") { model.toggleUnreadOnly() },
            Command(id: "do.shortcuts", group: .act, title: "Keyboard shortcuts", symbol: "keyboard", shortcut: "?") { model.showingShortcuts = true },
            Command(id: "do.settings", group: .act, title: "Settings", symbol: "gearshape", shortcut: "⌘,") { model.openSettings() },
            Command(id: "do.agents", group: .act, title: "Settings · Agents", symbol: "gearshape") { model.openSettings(.Agents) },
        ]
        if model.canMarkAllHere {
            out.append(Command(id: "do.markall", group: .act, title: "Mark all read in \(model.placeTitle)", symbol: "checkmark.circle") { model.markAllHere() })
        }
        if model.undo.canUndo {
            out.append(Command(id: "do.undo", group: .act, title: "Undo: \(model.undo.stack.last?.message ?? "")", symbol: "arrow.uturn.backward", shortcut: "⌘Z") { model.undo.undoLast() })
        }
        for routine in model.library.routines {
            out.append(Command(id: "do.run\(routine.id ?? 0)", group: .act, title: "Run \(routine.name) now", detail: "Routine", symbol: "play") {
                if let id = routine.id { Task { try? await model.library.runRoutine(id); model.showingActivity = true } }
            })
        }
        for recipe in model.library.recipes {
            out.append(Command(id: "do.recipe\(recipe.id)", group: .act, title: "Edit the \(recipe.name) recipe", detail: "Recipe", symbol: "doc.text") {
                if model.place != .today { model.go(to: .today) }
                model.openRecipe(recipe.id)
            })
        }
        return out
    }
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily
    @FocusState private var focused: Bool

    private var commands: CommandModel { model.commands }

    private enum Row: Identifiable {
        case command(Command, Fuzzy.Match)
        case article(EntrySummary)
        case ask(String)

        var id: String {
            switch self {
            case .command(let c, _): c.id
            case .article(let e): "article\(e.id)"
            case .ask: "ask"
            }
        }
    }

    private var sections: [(title: String, rows: [Row])] {
        let all = CommandModel.all(model)
        let query = commands.query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            let go = all.filter { $0.group == .go }.prefix(4 + model.library.views.count).map { Row.command($0, Fuzzy.Match(score: 0, positions: [])) }
            let act = all.filter { $0.group == .act }.prefix(8).map { Row.command($0, Fuzzy.Match(score: 0, positions: [])) }
            return [("Go to", Array(go)), ("Do", Array(act))]
        }
        let ranked = Fuzzy.rank(query, all) { $0.title }
        let go = ranked.filter { $0.item.group == .go }.prefix(5).map { Row.command($0.item, $0.match) }
        let act = ranked.filter { $0.item.group == .act }.prefix(5).map { Row.command($0.item, $0.match) }
        var out: [(String, [Row])] = []
        if !go.isEmpty { out.append(("Go to", Array(go))) }
        if !act.isEmpty { out.append(("Do", Array(act))) }
        if !commands.articles.isEmpty { out.append(("Articles", commands.articles.map(Row.article))) }
        out.append(("", [.ask(query)]))
        return out
    }

    private var flat: [Row] { sections.flatMap(\.rows) }

    var body: some View {
        @Bindable var commands = commands
        ZStack(alignment: .top) {
            p.scrim.opacity(0.6).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { commands.close() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(p.muted)
                    TextField("", text: $commands.query, prompt: Text("Go to, do, or find…").foregroundStyle(p.muted))
                        .textFieldStyle(.plain).font(.ui(18))
                        .focused($focused)
                        .onChange(of: commands.query) { commands.searchArticles() }
                        .onSubmit { run(commands.selection) }
                        .onExitCommand { commands.close() }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.tab) { askNow(); return .handled }
                        .accessibilityLabel("Command")
                    Text("esc").font(.ui(12)).foregroundStyle(p.muted)
                }
                .padding(.horizontal, 20).frame(height: 56)
                Rule()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            let rows = flat
                            ForEach(sections, id: \.title) { section in
                                if !section.title.isEmpty {
                                    SectionLabel(text: section.title + (section.title == "Articles" ? " · \(commands.articles.count)" : ""))
                                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                                } else {
                                    Rule().padding(.top, 8)
                                }
                                ForEach(section.rows) { row in
                                    let index = rows.firstIndex { $0.id == row.id } ?? 0
                                    rowView(row, selected: index == commands.selection) { run(index) }
                                        .id(row.id)
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                    .themedScrollbar()
                    .frame(maxHeight: 420)
                    .onChange(of: commands.selection) { _, index in
                        let rows = flat
                        if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
                    }
                }
            }
            .frame(width: 620)
            .fixedSize(horizontal: false, vertical: true)
            .popoverPanel()
            .padding(.top, 120)
        }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private func move(_ offset: Int) {
        let count = flat.count
        guard count > 0 else { return }
        commands.selection = min(max(commands.selection + offset, 0), count - 1)
    }

    private func run(_ index: Int) {
        let rows = flat
        guard rows.indices.contains(index) else { return }
        commands.close()
        switch rows[index] {
        case .command(let command, _): command.run()
        case .article(let entry): model.openResult(entry.id)
        case .ask(let query): model.ask.start(question: query, view: model.place.viewId, model: model)
        }
    }

    private func askNow() {
        let query = commands.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        commands.close()
        model.ask.start(question: query, view: model.place.viewId, model: model)
    }

    @ViewBuilder private func rowView(_ row: Row, selected: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Group {
                switch row {
                case .command(let command, let match):
                    HStack(spacing: 12) {
                        Image(systemName: command.symbol).font(.system(size: 13)).foregroundStyle(p.inkSoft).frame(width: 16)
                        Text(highlight(command.title, match.positions)).font(.ui(14))
                        Spacer(minLength: 12)
                        if let detail = command.detail { Text(detail).font(.ui(12)).foregroundStyle(p.muted).lineLimit(1) }
                        if let shortcut = command.shortcut { KeyHint(text: shortcut) }
                        else if selected { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(p.muted) }
                    }
                    .frame(height: 36)
                case .article(let entry):
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(entry.read ? .clear : p.unread).frame(width: Metrics.dot, height: Metrics.dot).frame(width: 16).padding(.top, 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title ?? "Untitled").font(.title(titleFamily, 16, .medium))
                                .foregroundStyle(entry.read ? p.read : p.unread).lineLimit(1)
                            Text([entry.feedTitle, Dates.relative(entry.date)].compactMap { $0 }.joined(separator: " · ")).font(.ui(12)).foregroundStyle(p.muted)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                case .ask(let query):
                    HStack(spacing: 12) {
                        Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(p.unread).frame(width: 16)
                        Text("Ask your feeds about “\(query)”").font(.ui(14)).foregroundStyle(p.unread)
                        Spacer()
                        KeyHint(text: "⇥ Tab")
                    }
                    .frame(height: 36)
                }
            }
            .padding(.horizontal, 12)
            .background(selected ? p.selected : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.bare)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Matched letters in the ink's weight, the rest regular.
    private func highlight(_ text: String, _ positions: [Int]) -> AttributedString {
        var out = AttributedString()
        let marked = Set(positions)
        for (index, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            piece.font = marked.contains(index) ? .ui(14, .semibold) : .ui(14)
            out += piece
        }
        return out
    }
}
