import ReaderLogic
import SwiftUI

private enum TreeRow: Identifiable {
    case folder(Folder, depth: Int)
    case feed(Feed, depth: Int)

    var id: String {
        switch self {
        case .folder(let folder, _): "folder\(folder.id)"
        case .feed(let feed, _): "feed\(feed.id)"
        }
    }
}

/// The sidebar's measurements, from the design rules: rows 32 high, padding 10, icons
/// 14, gap 8, radius 6. Indent comes from `SidebarIndent`, one value per depth.
enum SidebarGrid {
    static let row: CGFloat = 32
    static let edge = CGFloat(SidebarIndent.edge)
    static let trailing: CGFloat = 8
    static let icon = CGFloat(SidebarIndent.icon)
    static let gap = CGFloat(SidebarIndent.gap)
    static var label: CGFloat { edge + icon + gap }
    static func leading(_ depth: Int) -> CGFloat { CGFloat(SidebarIndent.leading(depth: depth)) }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @State private var addFrame = CGRect.zero
    @State private var statusFrame = CGRect.zero
    @State private var dropTarget = false

    /// Folders first, then feeds, at each level. A closed folder hides what it holds.
    /// A feed sits one level below its folder, so its name lines up with the folder's.
    private func rows(parent: Int64? = nil, depth: Int = 0) -> [TreeRow] {
        var rows: [TreeRow] = []
        for folder in model.childFolders(of: parent) {
            rows.append(.folder(folder, depth: depth))
            if !Prefs.shared.ui.collapsedFolders.contains(folder.id) { rows += self.rows(parent: folder.id, depth: depth + 1) }
        }
        let feedDepth = SidebarIndent.feedDepth(folderDepth: parent == nil ? nil : depth - 1)
        rows += model.feeds.filter { $0.folderId == parent }.map { .feed($0, depth: feedDepth) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarRow(title: "Search", symbol: "magnifyingglass", selected: false, action: { model.commands.show() }) {
                Text("⌘K").font(.ui(12)).foregroundStyle(p.muted)
            }
            SidebarRow(title: "Today", symbol: "calendar", selected: model.isShowing(.today), action: { model.go(to: .today) }) {
                if model.briefJob != nil { Spinner(size: 10) }
                else if hasNewBrief { Circle().fill(p.unread).frame(width: Metrics.dot, height: Metrics.dot).accessibilityLabel("New brief") }
            }
            SidebarRow(title: "All", symbol: "tray", selected: model.isShowing(.all), action: { model.go(to: .all) }) {
                if !model.feeds.isEmpty { Count(value: model.totalUnread) }
            }
            SidebarRow(title: "Starred", symbol: "star", selected: model.isShowing(.starred), action: { model.go(to: .starred) }) {
                if model.totalStarred > 0 { Count(value: model.totalStarred, quiet: true) }
            }
            SidebarRow(title: "Catch up", symbol: "rectangle.stack", selected: model.catchUp != nil, action: { model.startCatchUp() }) {
                Text("⌘J").font(.ui(12)).foregroundStyle(p.muted)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Views", help: "Save a search as a view (⌘F, then ⌘S)") { model.search.show() }
                    if model.library.views.isEmpty {
                        Text(model.library.available ? "Search, then ⌘S to keep it here" : "Views need a newer Fyke service")
                            .font(.ui(12)).foregroundStyle(p.muted)
                            .padding(.leading, SidebarGrid.label).frame(height: 24)
                    }
                    ForEach(model.library.views) { view in ViewRow(view: view) }

                    sectionHeader("Feeds", help: "Add a feed or a folder", action: showAddMenu)
                        .floatFrame($addFrame)
                        .background(dropTarget ? p.selected : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
                        .dropDestination(for: String.self) { items, _ in
                            Drag.apply(items, to: nil, model: model)
                        } isTargeted: { dropTarget = $0 }
                    ForEach(rows()) { row in
                        switch row {
                        case .folder(let folder, let depth): FolderRow(folder: folder, depth: depth)
                        case .feed(let feed, let depth): FeedRow(feed: feed, depth: depth)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .themedScrollbar()

            SidebarRow(title: "Routines", symbol: "clock.arrow.circlepath", selected: model.isShowing(.routines), action: { model.go(to: .routines) }) {
                if let next = model.library.nextRoutine?.nextRunAt {
                    Text("Next \(next.formatted(.dateTime.hour().minute()))").font(.ui(12)).foregroundStyle(p.muted)
                }
            }
            statusLine
        }
        .padding(.horizontal, 12).padding(.top, 48).padding(.bottom, 8)
        .frame(width: 231)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.surface)
        .onChange(of: model.showingActivity) { _, showing in
            if showing { layer.show(at: statusFrame) { ActivityPanel() } }
        }
        .onChange(of: layer.item == nil) { _, closed in
            if closed {
                model.showingActivity = false
                model.healthFeed = nil
            }
        }
        .onChange(of: model.healthFeed) { _, id in
            // A failing feed inside a closed folder: open the folders above it.
            guard let id, let feed = model.feeds.first(where: { $0.id == id }), var folder = feed.folderId else { return }
            while true {
                Prefs.shared.ui.collapsedFolders.removeAll { $0 == folder }
                guard let parent = model.folders.first(where: { $0.id == folder })?.parentId else { break }
                folder = parent
            }
        }
    }

    private var hasNewBrief: Bool {
        guard let newest = model.library.briefs.first?.id else { return false }
        return model.place != .today && newest != model.selectedBrief
    }

    private func sectionHeader(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        HStack {
            SectionLabel(text: title)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 20, height: 20)
            }
            .buttonStyle(SymbolStyle())
            .help(help)
            .accessibilityLabel(help)
        }
        .padding(.leading, SidebarGrid.edge).padding(.trailing, 4).padding(.top, 20).padding(.bottom, 4)
    }

    /// The one line of background work. It opens Activity.
    private var statusLine: some View {
        HStack(spacing: SidebarGrid.gap) {
            Button { model.showingActivity.toggle() } label: {
                HStack(spacing: SidebarGrid.gap) {
                    Group {
                        if model.statusIsBusy { Spinner(size: 10) }
                        else { Circle().fill(model.statusNeedsYou ? p.unread : p.control).frame(width: Metrics.dot, height: Metrics.dot) }
                    }
                    .frame(width: SidebarGrid.icon)
                    Text(model.statusWords).font(.ui(12)).foregroundStyle(model.statusNeedsYou ? p.ink : p.muted).lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.leading, SidebarGrid.edge)
                .frame(height: SidebarGrid.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowStyle(selected: model.showingActivity))
            .floatFrame($statusFrame)
            .accessibilityLabel("Activity: \(model.statusWords)")
            .accessibilityHint("Shows background work")
            SymbolButton(symbol: "gearshape", label: "Settings (⌘,)", selected: model.showingSettings) {
                if model.showingSettings { model.showingSettings = false } else { model.openSettings() }
            }
            .accessibilityAddTraits(model.showingSettings ? .isSelected : [])
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Rule() }
    }

    private func showAddMenu() {
        layer.show(at: addFrame) {
            VStack(alignment: .leading, spacing: 0) {
                MenuRow(title: "Add feed") {
                    layer.close()
                    model.showingAddFeed = true
                }
                MenuRow(title: "New folder") {
                    layer.close()
                    model.newFolder(in: nil)
                }
            }
            .frame(width: 180, alignment: .leading)
            .floatPanel()
        }
    }
}

/// A count at the end of a row: blue for unread, muted for everything else.
struct Count: View {
    let value: Int64
    var quiet = false
    @Environment(\.palette) private var p
    var body: some View {
        Text(value, format: .number.grouping(.never))
            .font(.ui(13, quiet ? .regular : .medium)).foregroundStyle(quiet || value == 0 ? p.muted : p.unread)
            .accessibilityLabel(quiet ? "\(value)" : "\(value) unread")
    }
}

/// Rest, hover, pressed, selected and focused, for every sidebar row.
struct RowStyle: ButtonStyle {
    var selected = false
    var target = false
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration, selected: selected, target: target) }
}

private struct RowBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let target: Bool
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .opacity(enabled ? 1 : 0.5)
            .background(fill, in: RoundedRectangle(cornerRadius: Radii.control))
            .onHover { hovering = $0 }
            .interactiveCursor()
            .motion(hovering, Motion.quick)
    }

    private var fill: Color {
        if selected || configuration.isPressed { return p.selectedStrong }
        if target || hovering { return p.selected }
        return .clear
    }
}

/// One destination row: icon, name, and whatever trails it.
struct SidebarRow<Trailing: View>: View {
    let title: String
    var symbol: String?
    var depth = 0
    let selected: Bool
    var muted = false
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarGrid.gap) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12.5)).foregroundStyle(p.inkSoft)
                        .frame(width: SidebarGrid.icon, height: SidebarGrid.icon)
                }
                Text(title).font(.ui(14, selected ? .semibold : .regular)).foregroundStyle(muted ? p.muted : p.ink).lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.leading, SidebarGrid.leading(depth)).padding(.trailing, SidebarGrid.trailing)
            .frame(height: SidebarGrid.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ViewRow: View {
    let view: SavedView
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    private var selected: Bool { model.isShowing(.view(view.id)) }

    var body: some View {
        Group {
            if model.renaming == .view(view.id) {
                HStack(spacing: SidebarGrid.gap) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12.5)).foregroundStyle(p.inkSoft).frame(width: SidebarGrid.icon)
                    RenameField(name: view.name) { model.renameView(view.id, to: $0) }
                    Text("↵ to keep").font(.ui(11)).foregroundStyle(p.muted).fixedSize()
                }
                .padding(.leading, SidebarGrid.edge).padding(.trailing, SidebarGrid.trailing)
                .frame(height: SidebarGrid.row)
            } else {
                SidebarRow(title: view.name, symbol: "line.3.horizontal.decrease", selected: selected, action: { model.go(to: .view(view.id)) }) {
                    Count(value: view.unread, quiet: view.unread == 0)
                }
                .accessibilityHint(view.sentence ?? "")
            }
        }
        .rightClickMenu { ViewMenu(view: view) }
    }
}
/// What a sidebar row carries while dragged.
enum Drag {
    static func feed(_ id: Int64) -> String { "feed:\(id)" }
    static func folder(_ id: Int64) -> String { "folder:\(id)" }

    @MainActor static func apply(_ items: [String], to folder: Int64?, model: AppModel) -> Bool {
        guard let item = items.first else { return false }
        let parts = item.split(separator: ":")
        guard parts.count == 2, let id = Int64(parts[1]) else { return false }
        switch parts[0] {
        case "feed": model.moveFeed(id, to: folder)
        case "folder": if id != folder { model.moveFolder(id, to: folder) }
        default: return false
        }
        return true
    }
}

/// Text field that replaces a row's name while renaming.
private struct RenameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).font(.ui(14))
            .padding(.horizontal, 4)
            .frame(height: 24)
            .background(p.ground, in: RoundedRectangle(cornerRadius: Radii.control))
            .overlay(RoundedRectangle(cornerRadius: Radii.control).stroke(p.unread))
            .focused($focused)
            .onAppear {
                text = name
                focused = true
            }
            .onSubmit { commit(text) }
            .onKeyPress(.escape) {
                model.renaming = nil
                return .handled
            }
            .onChange(of: focused) { _, on in if !on && model.renaming != nil { model.renaming = nil } }
    }
}

private struct FolderRow: View {
    let folder: Folder
    let depth: Int
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @State private var target = false

    private var unread: Int64 { model.feedsInside(folder.id).reduce(0) { $0 + $1.unread } }
    private var closed: Bool { Prefs.shared.ui.collapsedFolders.contains(folder.id) }
    private var selected: Bool { model.isShowing(.folder(folder.id)) }

    var body: some View {
        Group {
            if model.renaming == .folder(folder.id) {
                HStack(spacing: SidebarGrid.gap) {
                    chevron
                    RenameField(name: folder.name) { model.renameFolder(folder.id, to: $0) }
                }
                .padding(.leading, SidebarGrid.leading(depth)).padding(.trailing, SidebarGrid.trailing)
                .frame(height: SidebarGrid.row)
            } else {
                Button { model.go(to: .folder(folder.id)) } label: {
                    HStack(spacing: SidebarGrid.gap) {
                        Color.clear.frame(width: SidebarGrid.icon)
                        Text(folder.name).font(.ui(14, selected ? .semibold : .medium)).foregroundStyle(p.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        if unread > 0 { Count(value: unread) }
                    }
                    .padding(.leading, SidebarGrid.leading(depth)).padding(.trailing, SidebarGrid.trailing)
                    .frame(height: SidebarGrid.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowStyle(selected: selected, target: target))
                .overlay(alignment: .leading) { chevron.padding(.leading, SidebarGrid.leading(depth)) }
                .accessibilityLabel("\(folder.name), folder")
            }
        }
        .draggable(Drag.folder(folder.id))
        .dropDestination(for: String.self) { items, _ in
            Drag.apply(items, to: folder.id, model: model)
        } isTargeted: { target = $0 }
        .rightClickMenu { menu }
    }

    private var chevron: some View {
        Button { model.toggleFolder(folder.id) } label: {
            Image(systemName: closed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted)
                .frame(width: SidebarGrid.icon, height: 24).contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.bare)
        .help(closed ? "Open folder" : "Close folder")
        .accessibilityLabel(closed ? "Open \(folder.name)" : "Close \(folder.name)")
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(title: "Rename") { act { model.renaming = .folder(folder.id) } }
            MenuRow(title: "New folder inside") { act { model.newFolder(in: folder.id) } }
            MenuRow(title: "Add feed here") {
                act {
                    model.addFeedFolder = folder.id
                    model.showingAddFeed = true
                }
            }
            MenuRow(title: "Catch up") { act {
                model.go(to: .folder(folder.id))
                model.startCatchUp()
            } }
            MenuRow(title: "Mark all read") { act { model.markAllRead(folder: folder.id) } }
            Rule().padding(.vertical, 3)
            MenuRow(title: "Delete folder…") { act { model.confirmation = .deleteFolder(folder) } }
        }
        .frame(width: 204, alignment: .leading)
        .floatPanel()
    }

    private func act(_ run: () -> Void) {
        layer.close()
        run()
    }
}

private struct FeedRow: View {
    let feed: Feed
    let depth: Int
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @State private var frame = CGRect.zero

    private var selected: Bool { model.isShowing(.feed(feed.id)) }

    var body: some View {
        Group {
            if model.renaming == .feed(feed.id) {
                RenameField(name: feed.name) { model.renameFeed(feed.id, to: $0) }
                    .padding(.leading, SidebarGrid.leading(depth) - 4).padding(.trailing, SidebarGrid.trailing)
                    .frame(height: SidebarGrid.row)
            } else {
                SidebarRow(title: feed.name, depth: depth, selected: selected, muted: feed.unread == 0 && !feed.isFailing, action: { model.go(to: .feed(feed.id)) }) {
                    if feed.isFailing {
                        Button { model.healthFeed = feed.id } label: {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(p.ink).frame(width: 20, height: 20)
                        }
                        .buttonStyle(SymbolStyle(selected: model.healthFeed == feed.id))
                        .help("\(feed.name) is not loading")
                        .accessibilityLabel("\(feed.name) is not loading. Show why")
                    } else if feed.unread > 0 {
                        Count(value: feed.unread)
                    }
                }
            }
        }
        .floatFrame($frame)
        .draggable(Drag.feed(feed.id))
        .rightClickMenu { FeedMenu(feed: feed) }
        .onChange(of: model.healthFeed, initial: true) { _, id in
            if id == feed.id {
                DispatchQueue.main.async {
                    let anchor = CGRect(x: frame.maxX + 8, y: frame.minY - 8, width: 0, height: 0)
                    layer.show(at: anchor) { FeedHealthPanel(feed: feed) }
                }
            }
        }
    }
}

private struct FeedMenu: View {
    let feed: Feed
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @State private var moveFrame = CGRect.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(title: "Refresh") { act { model.refreshFeed(feed.id) } }
            MenuRow(title: "Rename") { act { model.renaming = .feed(feed.id) } }
            MenuRow(title: "Move to", trailing: .right, run: showMove).floatFrame($moveFrame)
            MenuRow(title: "Mark all read") { act { model.markAllRead(feed: feed.id) } }
            if let site = feed.siteUrl, let url = URL(string: site) {
                MenuRow(title: "Open site") { act { model.openLink(url) } }
            }
            Rule().padding(.vertical, 3)
            MenuRow(title: "Remove feed…") { act { model.confirmation = .removeFeed(feed) } }
        }
        .frame(width: 204, alignment: .leading)
        .floatPanel()
    }

    private func showMove() {
        let anchor = CGRect(x: moveFrame.maxX + 8, y: moveFrame.minY - 10, width: 0, height: 0)
        layer.showSide(at: anchor) {
            VStack(alignment: .leading, spacing: 0) {
                MenuList(rows: model.folders.count + 1) {
                    MenuRow(title: "Top level", checked: feed.folderId == nil) { act { model.moveFeed(feed.id, to: nil) } }
                    ForEach(model.folderOutline(), id: \.folder.id) { row in
                        MenuRow(title: row.folder.name, checked: feed.folderId == row.folder.id, indent: CGFloat(row.depth) * 16) {
                            act { model.moveFeed(feed.id, to: row.folder.id) }
                        }
                    }
                }
                Rule().padding(.vertical, 3)
                MenuRow(title: "New folder") { act { model.newFolderHolding(feed.id) } }
            }
            .frame(width: 184, alignment: .leading)
            .floatPanel()
        }
    }

    private func act(_ run: () -> Void) {
        layer.close()
        run()
    }
}

/// Asks before anything that loses data. Keeping data is the default.
struct ConfirmationDialog: View {
    let confirmation: Confirmation
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var family
    @State private var deleteContents = false

    var body: some View {
        ZStack {
            p.scrim.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                switch confirmation {
                case .deleteFolder(let folder): deleteFolder(folder)
                case .removeFeed(let feed): removeFeed(feed)
                }
            }
            .padding(24)
            .frame(width: 460, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radii.sheet).fill(p.ground)
                    .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.15), radius: 25, y: 18)
            }
            .overlay(RoundedRectangle(cornerRadius: Radii.sheet).stroke(p.hairline))
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.title(family, 24, .semibold)).tracking(-0.24).padding(.bottom, 6)
    }

    private func count(_ number: Int64, _ noun: String) -> String {
        "\(number.formatted()) \(noun)\(number == 1 ? "" : "s")"
    }

    private func buttons(_ action: String, run: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { model.confirmation = nil }.buttonStyle(Plain()).keyboardShortcut(.cancelAction)
            Button(action) {
                model.confirmation = nil
                run()
            }
            .buttonStyle(Solid())
        }
        .padding(.top, 18)
    }

    @ViewBuilder private func deleteFolder(_ folder: Folder) -> some View {
        let folders = Int64(model.foldersInside(folder.id).count)
        let feeds = model.feedsInside(folder.id)
        let articles = feeds.reduce(0) { $0 + $1.entries }
        let starred = feeds.reduce(0) { $0 + $1.starred }
        let parts = [folders > 0 ? count(folders, "folder") : nil, feeds.isEmpty ? nil : count(Int64(feeds.count), "feed")].compactMap { $0 }
        let target = folder.parentId == nil ? "the top level" : "the folder above"
        title("Delete \(folder.name)?")
        Text(parts.isEmpty ? "The folder is empty." : "Its \(parts.joined(separator: " and ")) \(folders + Int64(feeds.count) == 1 ? "moves" : "move") up to \(target). Your articles stay.")
            .font(.ui(14)).foregroundStyle(p.inkSoft).padding(.bottom, 16)
        if !parts.isEmpty {
            Rule()
            HStack(alignment: .top, spacing: 10) {
                Checkbox(on: $deleteContents)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also delete everything inside").font(.ui(14))
                    Text("Removes \((parts + [count(articles, "article")]).joined(separator: ", "))\(starred > 0 ? ", including \(starred) starred" : ""). This cannot be undone.")
                        .font(.ui(13)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 12)
            Rule()
        }
        buttons("Delete folder") { model.removeFolder(folder.id, deleteContents: deleteContents) }
    }

    @ViewBuilder private func removeFeed(_ feed: Feed) -> some View {
        title("Remove \(feed.name)?")
        Text("This deletes \(count(feed.entries, "article"))\(feed.starred > 0 ? ", including \(feed.starred) starred" : ""). This cannot be undone.")
            .font(.ui(14)).foregroundStyle(p.inkSoft).fixedSize(horizontal: false, vertical: true)
        buttons("Remove feed") { model.removeFeed(feed.id) }
    }
}

/// A filled button in ink, for the one action a dialog is about.
struct Solid: ButtonStyle {
    @Environment(\.palette) private var p
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(14, .medium)).foregroundStyle(p.ground)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(p.ink, in: RoundedRectangle(cornerRadius: Radii.control))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .interactiveCursor()
    }
}

enum ShortcutList {
    static let move = [
        ("Next, previous", "j k"), ("Open", "Return"), ("Back", "Esc"), ("Next unread", "n"),
        ("Search", "/"), ("Today, All, Starred, Routines", "⌘1–4"), ("Everything", "⌘K"),
    ]
    static let act = [
        ("Star", "s"), ("Read or unread", "m"), ("Unread only", "u"), ("Open page here", "o"), ("Open in browser", "⇧O"), ("Comments", "c"),
        ("Fetch full article", "f"), ("Refresh", "r"), ("Add feed", "a"), ("Text and theme", "t"),
        ("Save search as view", "⌘S"), ("Settings", "⌘,"), ("Catch up", "⌘J"), ("Ask your feeds", "⇧⌘A"), ("Undo", "⌘Z"),
    ]
}

/// The key list, over the app, so that looking one up loses no place.
struct ShortcutsPopup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var family

    var body: some View {
        ZStack {
            p.scrim.ignoresSafeArea().onTapGesture { model.showingShortcuts = false }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Shortcuts").font(.title(family, 26, .semibold)).tracking(-0.26)
                    Spacer()
                    Text("Esc to close").font(.ui(13)).foregroundStyle(p.muted)
                }
                .padding(.bottom, 18)
                HStack(alignment: .top, spacing: 40) {
                    column("MOVE", ShortcutList.move)
                    column("ACT", ShortcutList.act)
                }
                Rule().padding(.top, 8)
                Text("Press ? anywhere to see this list.").font(.ui(13)).foregroundStyle(p.muted).padding(.top, 14)
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 20)
            .frame(width: 640)
            .background {
                RoundedRectangle(cornerRadius: Radii.sheet).fill(p.ground)
                    .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.15), radius: 25, y: 18)
            }
            .overlay(RoundedRectangle(cornerRadius: Radii.sheet).stroke(p.hairline))
        }
    }

    private func column(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.ui(11, .semibold)).tracking(0.66).foregroundStyle(p.muted).padding(.bottom, 8)
            ForEach(rows, id: \.0) { row in
                Rule()
                HStack {
                    Text(row.0).font(.ui(14))
                    Spacer()
                    Text(row.1).font(.code(13)).foregroundStyle(p.inkSoft)
                }
                .frame(height: 30)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Asks before the data folder moves, and shows the move while it runs.
struct MoveDialog: View {
    let move: DataMove
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var family

    private var place: String {
        move.target.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var size: String { move.bytes.formatted(.byteCount(style: .file)) }

    var body: some View {
        ZStack {
            p.scrim.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(move.phase == .asking || isFailed ? "Move your data?" : "Moving your data")
                    .font(.title(family, 22, .semibold)).tracking(-0.22).padding(.bottom, 6)
                switch move.phase {
                case .asking: asking
                case .moving(let stage): Text(stage).font(.ui(14)).foregroundStyle(p.inkSoft)
                case .failed(let reason): failed(reason)
                }
            }
            .padding(22)
            .frame(width: 420, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radii.sheet).fill(p.ground)
                    .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.15), radius: 25, y: 18)
            }
            .overlay(RoundedRectangle(cornerRadius: Radii.sheet).stroke(p.hairline))
        }
    }

    private var isFailed: Bool {
        if case .failed = move.phase { return true }
        return false
    }

    private var summary: some View {
        (Text("\(size) moves to ") + Text(place).font(.code(13)).foregroundStyle(p.ink) + Text(". Fyke restarts when it is done."))
            .font(.ui(14)).foregroundStyle(p.inkSoft).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var asking: some View {
        summary
        if let warning = move.warning {
            HStack(alignment: .top, spacing: 8) {
                Icon(glyph: .warning).padding(.top, 1)
                Text(warning.text).font(.ui(13)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
        }
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { model.dataMove = nil }.buttonStyle(Plain()).keyboardShortcut(.cancelAction)
            Button("Move data") { model.startMove() }.buttonStyle(Solid()).disabled(move.warning == .noSpace)
        }
        .padding(.top, 18)
    }

    @ViewBuilder private func failed(_ reason: String) -> some View {
        Text(reason).font(.ui(14)).foregroundStyle(p.inkSoft).fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Close") { model.dataMove = nil }.buttonStyle(Plain()).keyboardShortcut(.cancelAction)
        }
        .padding(.top, 18)
    }
}
