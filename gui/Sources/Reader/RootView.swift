import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(FloatLayer.self) private var layer
    @Environment(\.openSettings) private var openSettings
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Sidebar()
            Rule(vertical: true)
            content
        }
        .ignoresSafeArea()
        .background(WindowButtons())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { focused = true }
        .task { await model.start() }
        .task {
            if ProcessInfo.processInfo.environment["RSS_SCREEN"] == "settings" { openSettings() }
        }
        .onChange(of: model.showingShortcuts) { _, showing in if !showing { focused = true } }
        .onChange(of: model.renaming) { _, renaming in if renaming == nil { focused = true } }
        .onChange(of: model.web == nil) { _, closed in if closed { focused = true } }
        .onChange(of: model.confirmation == nil) { _, closed in if closed { focused = true } }
        .onChange(of: model.search.isShowing) { _, showing in if !showing { focused = true } }
        .onChange(of: model.showingAddFeed) { _, showing in if !showing { focused = true } }
        .sheet(isPresented: $model.showingAddFeed) { AddFeedSheet() }
        .overlay { if model.search.isShowing { SearchPanel() } }
        .overlay { if model.showingShortcuts { ShortcutsPopup() } }
        .overlay {
            if let confirmation = model.confirmation { ConfirmationDialog(confirmation: confirmation).id(confirmation.id) }
        }
        .overlay(alignment: .bottom) {
            if let problem = model.problem ?? Prefs.shared.fileProblem.map({ "config.json has a mistake, so the last good settings stay in use: \($0)" }) {
                Text(problem)
                    .font(.ui(13))
                    .foregroundStyle(p.onAccent)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(p.ink, in: RoundedRectangle(cornerRadius: Radii.control))
                    .padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.isEmpty {
            FirstRunView()
        } else if model.place == .briefing && model.web == nil {
            BriefingView()
        } else if model.usesPanes {
            Panes()
        } else if model.article != nil || model.web != nil {
            ReaderPane()
        } else {
            TimelineView()
        }
    }

    /// The same keys as the terminal app, where it has them.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        // A dialog is modal: its own buttons act, and keys must not reach the app behind.
        if model.confirmation != nil { return .handled }
        if model.showingShortcuts {
            if press.key == .escape || press.characters == "?" { model.showingShortcuts = false }
            return .handled
        }
        switch press.key {
        case .return: model.openSelected(); return .handled
        case .escape:
            if layer.item != nil { layer.close() } else { model.back() }
            return .handled
        case .downArrow: model.moveSelection(1); return .handled
        case .upArrow: model.moveSelection(-1); return .handled
        default: break
        }
        switch press.characters {
        case "j": model.moveSelection(1)
        case "k": model.moveSelection(-1)
        case "n": model.nextUnread()
        case "s": model.toggleStar()
        case "m": model.toggleRead()
        case "u": model.toggleUnreadOnly()
        case "o": model.openPage()
        case "O": model.openInBrowser()
        case "f": model.fetchFull()
        case "r": model.refresh()
        case "a": model.showingAddFeed = true
        case "t": model.showingType.toggle()
        case "/": model.search.show()
        case "?": model.showingShortcuts = true
        default: return .ignored
        }
        return .handled
    }
}

/// The article list and the reader, with a divider between them that drags.
struct Panes: View {
    @State private var dragStart: Double?
    @State private var live: Double?
    @State private var hovering = false
    @Environment(\.palette) private var p

    private static let standard = 375.0
    private static let smallest = 280.0
    /// The reader needs room to be read in.
    private static let readerMinimum = 400.0

    var body: some View {
        GeometryReader { proxy in
            let widest = max(Self.smallest, min(640, proxy.size.width - Self.readerMinimum))
            let width = min(max(live ?? Prefs.shared.ui.listWidth, Self.smallest), widest)
            HStack(spacing: 0) {
                EntryList().frame(width: width)
                divider(current: width, widest: widest)
                ReaderPane()
            }
        }
    }

    private func divider(current: Double, widest: Double) -> some View {
        ZStack {
            Rectangle().fill(hovering || dragStart != nil ? p.control : p.hairline).frame(width: 1)
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .pointerStyle(.columnResize)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? current
                    dragStart = start
                    live = min(max(start + drag.translation.width, Self.smallest), widest)
                }
                .onEnded { _ in
                    if let live { Prefs.shared.ui.listWidth = live }
                    dragStart = nil
                    live = nil
                }
        )
        .onTapGesture(count: 2) { Prefs.shared.ui.listWidth = Self.standard }
        .accessibilityLabel("Resize the article list")
    }
}

struct Rule: View {
    var vertical = false
    var strong = false
    @Environment(\.palette) private var p

    var body: some View {
        Rectangle()
            .fill(strong ? p.ink : p.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

enum Dates {
    static func short(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The last week by weekday, older by date.
    static func relative(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 99
        return days < 7 ? date.formatted(.dateTime.weekday(.wide)) : short(date)
    }

    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day())
    }
}

/// Feed list column: title, summary, date.
struct EntryList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.readingFamily) private var family
    @Environment(\.titleFamily) private var titleFamily
    @State private var hovered: Int64?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.entries) { row in
                            rowView(row).id(row.id)
                                .onAppear {
                                    if row.id == model.entries.last?.id { Task { await model.loadMore() } }
                                }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
                .themedScrollbar()
                .onChange(of: model.selectedId) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                }
            }
        }
        .background(p.ground)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.placeTitle).font(.ui(20, .semibold)).tracking(-0.2).lineLimit(1)
            Spacer()
            Text("\(model.placeUnread) unread").font(.ui(13)).foregroundStyle(p.muted)
        }
        .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 16)
    }

    private func rowView(_ row: EntrySummary) -> some View {
        let selected = model.selectedId == row.id
        return Button { Task { await model.open(row.id) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title ?? "Untitled")
                    .font(.custom(titleFamily, fixedSize: 18).weight(.medium))
                    .foregroundStyle(row.read ? p.read : p.unread)
                    .line(23, size: 18)
                if let text = row.preview {
                    Text(text).font(.ui(13)).foregroundStyle(selected ? p.inkSoft : p.muted).lineLimit(2).line(18, size: 13)
                }
                Text(Dates.short(row.date)).font(.ui(12)).foregroundStyle(p.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(selected ? p.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            StarToggle(row: row, showing: selected || hovered == row.id).padding(6)
        }
        .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
    }
}

/// Filled once starred. Until then it appears only on the row in use, so a long list
/// stays quiet.
struct StarToggle: View {
    let row: EntrySummary
    let showing: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        if row.starred || showing {
            Button { model.toggleStar(row.id) } label: {
                Icon(glyph: .star, size: 14, color: row.starred ? p.unread : p.muted, filled: row.starred)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.starred ? "Remove star" : "Star")
        }
    }
}

/// All and Starred: one wide column grouped into this week and earlier.
struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.readingFamily) private var family
    @Environment(\.titleFamily) private var titleFamily

    @State private var hovered: Int64?

    private var cutoff: Date { Calendar.current.date(byAdding: .day, value: -7, to: .now)! }
    private var recent: [EntrySummary] { model.entries.filter { $0.date >= cutoff } }
    private var earlier: [EntrySummary] { model.entries.filter { $0.date < cutoff } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.placeTitle)
                            .font(.custom(titleFamily, fixedSize: 48).weight(.semibold)).tracking(-0.72)
                        Spacer()
                        Button { model.toggleUnreadOnly() } label: {
                            Text(model.unreadOnly ? "Unread · \(model.totalUnread)" : "All · \(model.totalUnread) unread")
                                .font(.ui(14, .medium)).foregroundStyle(p.inkSoft)
                        }.buttonStyle(.plain)
                    }
                    .padding(.bottom, 36)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        group("THIS WEEK", recent)
                        group("EARLIER", earlier)
                    }
                    if model.entries.isEmpty && model.hasLoaded {
                        Text(model.place == .starred ? "Star an article to keep it here." : "No articles to show.")
                            .font(.ui(14)).foregroundStyle(p.muted)
                    }
                }
                .frame(width: 760)
                .padding(.top, 72).padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .themedScrollbar()
            .onChange(of: model.selectedId) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ rows: [EntrySummary]) -> some View {
        if !rows.isEmpty {
            Text(title).font(.ui(11, .semibold)).tracking(0.66).foregroundStyle(p.muted)
                .padding(.top, title == "EARLIER" ? 30 : 0).padding(.bottom, 8)
            Rule(strong: true)
            ForEach(rows) { row in
                rowView(row).id(row.id)
                    .onAppear {
                        if row.id == model.entries.last?.id { Task { await model.loadMore() } }
                    }
            }
        }
    }

    private func rowView(_ row: EntrySummary) -> some View {
        Button { Task { await model.open(row.id) } } label: {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title ?? "Untitled")
                            .font(.custom(titleFamily, fixedSize: 21).weight(.medium))
                            .foregroundStyle(row.read ? p.read : p.unread)
                        if let text = row.preview {
                            Text(text).font(.ui(14)).foregroundStyle(p.inkSoft).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(row.feedTitle ?? "").lineLimit(1)
                        Text(Dates.relative(row.date))
                    }
                    .font(.ui(13)).foregroundStyle(p.muted)
                    .frame(width: 120, alignment: .trailing)
                    .padding(.top, 5)
                    StarToggle(row: row, showing: model.selectedId == row.id || hovered == row.id)
                        .frame(width: 26).padding(.top, 2)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, model.selectedId == row.id ? 8 : 0)
                .background(model.selectedId == row.id ? p.selected : .clear)
                Rule()
            }
            .contentShape(Rectangle())
        }
        .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
        .buttonStyle(.plain)
    }
}

/// Shown until the aggregator produces a digest.
struct BriefingView: View {
    @Environment(\.palette) private var p
    @Environment(\.readingFamily) private var family
    @Environment(\.titleFamily) private var titleFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Date.now.formatted(.dateTime.weekday(.wide)) + ",\n" + Date.now.formatted(.dateTime.day().month(.wide)))
                .font(.custom(titleFamily, fixedSize: 64).weight(.semibold)).tracking(-1)
            Text("No briefing yet. It arrives with the aggregator.")
                .font(.custom(family, fixedSize: 21)).foregroundStyle(p.inkSoft)
        }
        .padding(.leading, 96).padding(.top, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FirstRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.readingFamily) private var family
    @Environment(\.titleFamily) private var titleFamily
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nothing to read yet.")
                .font(.custom(titleFamily, fixedSize: 52).weight(.semibold)).tracking(-1)
            Text("Add a site you like. Everything stays on this Mac.")
                .font(.custom(family, fixedSize: 21)).foregroundStyle(p.inkSoft)
                .padding(.top, 14).padding(.bottom, 32)
            HStack(spacing: 8) {
                TextField("Paste a site or feed address", text: $address)
                    .textFieldStyle(.plain).font(.ui(15))
                    .padding(.horizontal, 12).frame(height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.unread, lineWidth: 2))
                    .onSubmit(submit)
                Button("Add", action: submit).buttonStyle(Primary()).frame(height: 40)
            }
            HStack(spacing: 4) {
                Text("Moving from another reader?").foregroundStyle(p.muted)
                Button("Import OPML") { OPML.importFile(model) }.buttonStyle(.plain).foregroundStyle(p.unread)
            }
            .font(.ui(14)).padding(.top, 16)
        }
        .frame(width: 560, alignment: .leading)
        .padding(.leading, 168).padding(.bottom, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func submit() {
        AddFeedDraft.shared.address = address
        model.showingAddFeed = true
    }
}

struct Primary: ButtonStyle {
    @Environment(\.palette) private var p
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(14, .medium)).foregroundStyle(p.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(p.unread, in: RoundedRectangle(cornerRadius: Radii.control))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct Plain: ButtonStyle {
    @Environment(\.palette) private var p
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(14)).foregroundStyle(p.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: Radii.control).stroke(p.control))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
