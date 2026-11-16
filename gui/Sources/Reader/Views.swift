// A view's rule shown as a sentence with words that can be tapped. Each tap opens
// one small editor for that word, and the change applies at once with Undo.
import ReaderLogic
import SwiftUI

struct ViewSentence: View {
    let view: SavedView
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @State private var frames: [Int: CGRect] = [:]
    @State private var open: Int?

    private var parts: [SentencePart] {
        RuleSentence.parts(view.rule, feedName: { id in model.feeds.first { $0.id == id }?.name }, folderName: { id in model.folders.first { $0.id == id }?.name })
    }

    var body: some View {
        Flow(spacing: 5, lineHeight: 28) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                switch part {
                case .joiner(let text):
                    Text(text).font(.ui(13)).foregroundStyle(p.muted)
                case .chip(let clause, let text, let value):
                    Chip(text: text, selected: open == index && layer.item != nil) { edit(clause, value: value, at: index) }
                        .floatFrame(Binding(get: { frames[index] ?? .zero }, set: { frames[index] = $0 }))
                        .accessibilityLabel("\(clause.rawValue): \(text)")
                        .accessibilityHint("Changes this part of the rule")
                }
            }
            Chip(text: "+", muted: true) { add() }
                .floatFrame(Binding(get: { frames[-1] ?? .zero }, set: { frames[-1] = $0 }))
                .accessibilityLabel("Add to the rule")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rule: \(RuleSentence.text(parts))")
        .onChange(of: layer.item == nil) { _, closed in if closed { open = nil } }
    }

    private func apply(_ change: (inout SelectionRule) -> Void) {
        var rule = view.rule
        change(&rule)
        layer.close()
        model.setRule(rule, of: view.id)
    }

    private func show(at index: Int, @ViewBuilder _ content: () -> some View) {
        open = index
        layer.show(at: frames[index] ?? .zero) { content().floatPanel() }
    }

    private func edit(_ clause: Clause, value: String?, at index: Int) {
        let rule = view.rule
        switch clause {
        case .state:
            show(at: index) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SelectionRule.State.allCases, id: \.self) { state in
                        MenuRow(title: RuleSentence.stateWord(state), checked: (rule.state ?? .any) == state) { apply { $0.setState(state) } }
                    }
                }
                .frame(width: 180)
            }
        case .scope:
            show(at: index) { ScopeEditor(rule: rule) { feeds, folders in apply { $0.setScope(feeds: feeds, folders: folders) } } }
        case .words:
            show(at: index) {
                TextClauseEditor(title: "About these words", text: rule.words ?? "", toggle: ("Any one of them is enough", rule.anyWords == true),
                                 remove: { apply { $0.clear(.words) } }) { text, any in apply { $0.setWords(text, any: any) } }
            }
        case .host:
            show(at: index) {
                TextClauseEditor(title: "On this site", text: rule.host ?? "", placeholder: "example.com", toggle: ("Include its subdomains", rule.subdomains == true),
                                 remove: { apply { $0.clear(.host) } }) { text, any in apply { $0.setHost(text, subdomains: any) } }
            }
        case .path:
            show(at: index) {
                TextClauseEditor(title: "Under this path", text: rule.pathPrefix ?? "", placeholder: "/blog/", remove: { apply { $0.clear(.path) } }) { text, _ in apply { $0.setPath(text) } }
            }
        case .exclude:
            show(at: index) {
                TextClauseEditor(title: "Skip this path", text: value ?? "", placeholder: "/jobs/", remove: { apply { $0.removeExclude(value ?? "") } }) { text, _ in
                    apply {
                        $0.removeExclude(value ?? "")
                        $0.addExclude(text)
                    }
                }
            }
        case .within:
            show(at: index) { withinMenu(rule) }
        }
    }

    private func withinMenu(_ rule: SelectionRule) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([1, 7, 30, 90], id: \.self) { days in
                MenuRow(title: RuleSentence.withinWords(days).prefix(1).uppercased() + RuleSentence.withinWords(days).dropFirst(), checked: rule.withinDays == days) { apply { $0.setWithin(days) } }
            }
            MenuRow(title: "Any time", checked: rule.withinDays == nil) { apply { $0.clear(.within) } }
        }
        .frame(width: 180)
    }

    /// Lists what the rule does not say yet. Choosing one opens its editor.
    private func add() {
        let rule = view.rule
        show(at: -1) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rule.missing, id: \.self) { clause in
                    MenuRow(title: Self.addTitle(clause)) {
                        layer.close()
                        DispatchQueue.main.async {
                            if clause == .within { show(at: -1) { withinMenu(rule) } } else { edit(clause, value: nil, at: -1) }
                        }
                    }
                }
            }
            .frame(width: 200)
        }
    }

    static func addTitle(_ clause: Clause) -> String {
        switch clause {
        case .words: "About words…"
        case .host: "On a site…"
        case .path: "Under a path…"
        case .exclude: "Skipping a path…"
        case .within: "From recent days…"
        case .state: "Reading state…"
        case .scope: "From feeds…"
        }
    }
}

/// Feeds and folders to look in. None chosen means every feed.
private struct ScopeEditor: View {
    let rule: SelectionRule
    let done: ([Int64], [Int64]) -> Void
    @Environment(AppModel.self) private var model
    @State private var feeds: Set<Int64> = []
    @State private var folders: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuList(rows: model.folders.count + model.feeds.count + 1) {
                MenuRow(title: "All feeds", checked: feeds.isEmpty && folders.isEmpty) {
                    feeds = []
                    folders = []
                }
                ForEach(model.folderOutline(), id: \.folder.id) { row in
                    MenuRow(title: row.folder.name, checked: folders.contains(row.folder.id), indent: CGFloat(row.depth) * 16) { toggle(&folders, row.folder.id) }
                }
                ForEach(model.feeds) { feed in
                    MenuRow(title: feed.name, checked: feeds.contains(feed.id)) { toggle(&feeds, feed.id) }
                }
            }
            Rule().padding(.vertical, 4)
            HStack {
                Spacer()
                Button("Apply") { done(Array(feeds).sorted(), Array(folders).sorted()) }
                    .buttonStyle(ActionStyle(kind: .primary, height: 28))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(4)
        }
        .frame(width: 260)
        .onAppear {
            feeds = Set(rule.feeds ?? [])
            folders = Set(rule.folders ?? [])
        }
    }

    private func toggle(_ set: inout Set<Int64>, _ id: Int64) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
}

/// One word or address, typed, with an optional switch and a way to drop the clause.
private struct TextClauseEditor: View {
    let title: String
    @State var text: String
    var placeholder = ""
    var toggle: (String, Bool)?
    let remove: () -> Void
    let done: (String, Bool) -> Void
    @State private var on = false
    @Environment(\.palette) private var p

    init(title: String, text: String, placeholder: String = "", toggle: (String, Bool)? = nil, remove: @escaping () -> Void, done: @escaping (String, Bool) -> Void) {
        self.title = title
        _text = State(initialValue: text)
        self.placeholder = placeholder
        self.toggle = toggle
        self.remove = remove
        self.done = done
        _on = State(initialValue: toggle?.1 ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.ui(12, .medium)).foregroundStyle(p.muted)
            Field(placeholder: placeholder, text: $text, submit: { done(text, on) }, autofocus: true)
            if let toggle {
                HStack(spacing: 8) {
                    Checkbox(on: $on)
                    Text(toggle.0).font(.ui(13))
                }
            }
            HStack {
                Button("Remove", action: remove).buttonStyle(ActionStyle(kind: .quiet, height: 28)).padding(.leading, -10)
                Spacer()
                Button("Apply") { done(text, on) }.buttonStyle(ActionStyle(kind: .primary, height: 28))
            }
        }
        .padding(8)
        .frame(width: 280)
    }
}

/// The menu a view row and a view header share.
struct ViewMenu: View {
    let view: SavedView
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(title: "Rename") { act { model.renaming = .view(view.id) } }
            MenuRow(title: "Write a brief of this view") { act { model.runBrief(view: view.id) } }
            MenuRow(title: "Catch up") { act {
                if model.place != .view(view.id) { model.go(to: .view(view.id)) }
                model.startCatchUp()
            } }
            MenuRow(title: "Make a routine…") { act { model.newRoutine(view: view.id) } }
            MenuRow(title: "Mark all read") { act { model.markAllRead(view: view.id) } }
            Rule().padding(.vertical, 3)
            MenuRow(title: "Move up") { act { model.moveView(view.id, by: -1) } }
            MenuRow(title: "Move down") { act { model.moveView(view.id, by: 1) } }
            Rule().padding(.vertical, 3)
            MenuRow(title: "Remove view") { act { model.removeView(view.id) } }
        }
        .frame(width: 220, alignment: .leading)
        .floatPanel()
    }

    private func act(_ run: () -> Void) {
        layer.close()
        run()
    }
}
