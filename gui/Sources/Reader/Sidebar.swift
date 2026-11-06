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

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @State private var addFrame = CGRect.zero
    @State private var dropTarget = false

    /// Folders first, then feeds, at each level. A closed folder hides what it holds.
    private func rows(parent: Int64? = nil, depth: Int = 0) -> [TreeRow] {
        var rows: [TreeRow] = []
        for folder in model.childFolders(of: parent) {
            rows.append(.folder(folder, depth: depth))
            if !Prefs.shared.ui.collapsedFolders.contains(folder.id) { rows += self.rows(parent: folder.id, depth: depth + 1) }
        }
        rows += model.feeds.filter { $0.folderId == parent }.map { .feed($0, depth: depth) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            searchRow
            item("Briefing", glyph: .briefing, place: .briefing, count: nil)
            item("All", glyph: .inbox, place: .all, count: model.feeds.isEmpty ? nil : model.totalUnread)
            item("Starred", glyph: .star, place: .starred, count: model.totalStarred == 0 ? nil : model.totalStarred, quietCount: true)

            HStack {
                Text("FEEDS")
                    .font(.ui(11, .semibold)).tracking(0.66)
                    .foregroundStyle(p.muted)
                Spacer()
                Button(action: showAddMenu) {
                    Icon(glyph: .plus, size: 14).frame(width: 20, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a feed or a folder")
                .floatFrame($addFrame)
            }
            .padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 6)
            .background(dropTarget ? p.selected : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
            .dropDestination(for: String.self) { items, _ in
                drop(items, on: nil)
            } isTargeted: { dropTarget = $0 }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows()) { row in
                        switch row {
                        case .folder(let folder, let depth): FolderRow(folder: folder, depth: depth)
                        case .feed(let feed, let depth): FeedRow(feed: feed, depth: depth)
                        }
                    }
                }
            }
            .themedScrollbar()

            Text(status).font(.ui(12)).foregroundStyle(p.muted)
                .padding(.horizontal, 10).padding(.vertical, 14)
        }
        .padding(.horizontal, 12).padding(.top, 48)
        .frame(width: 231)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.surface)
    }

    private func drop(_ items: [String], on folder: Int64?) -> Bool {
        Drag.apply(items, to: folder, model: model)
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

    private var searchRow: some View {
        Button { model.search.show() } label: {
            HStack(spacing: 8) {
                Icon(glyph: .search, size: 14)
                Text("Search").font(.ui(14)).foregroundStyle(p.ink)
                Spacer(minLength: 8)
                Text("⌘F").font(.ui(13)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var status: String {
        guard let date = model.updatedAt else { return " " }
        return "Updated " + date.formatted(.relative(presentation: .named))
    }

    private func item(_ title: String, glyph: Glyph, place: Place, count: Int64?, quietCount: Bool = false) -> some View {
        let selected = model.place == place
        return Button { model.go(to: place) } label: {
            HStack(spacing: 8) {
                Icon(glyph: glyph, size: 14)
                Text(title).font(.ui(14, selected ? .semibold : .regular)).foregroundStyle(p.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let count {
                    Text(count, format: .number.grouping(.never))
                        .font(.ui(13, quietCount ? .regular : .medium)).foregroundStyle(quietCount ? p.muted : p.unread)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? p.selectedStrong : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        if parts[0] == "feed" {
            model.moveFeed(id, to: folder)
        } else if id != folder {
            model.moveFolder(id, to: folder)
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
    private var selected: Bool { model.place == .folder(folder.id) }

    var body: some View {
        HStack(spacing: 6) {
            Button { model.toggleFolder(folder.id) } label: {
                Icon(glyph: closed ? .right : .down, size: 14, color: p.muted)
                    .frame(width: 18, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(closed ? "Open folder" : "Close folder")
            if model.renaming == .folder(folder.id) {
                RenameField(name: folder.name) { model.renameFolder(folder.id, to: $0) }
            } else {
                Button { model.go(to: .folder(folder.id)) } label: {
                    HStack {
                        Text(folder.name).font(.ui(14, selected ? .semibold : .medium)).foregroundStyle(p.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        if unread > 0 {
                            Text(unread, format: .number.grouping(.never)).font(.ui(13, .medium)).foregroundStyle(p.unread)
                        }
                    }
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 2 + CGFloat(depth) * 16).padding(.trailing, 10)
        .background(selected ? p.selectedStrong : (target ? p.selected : .clear), in: RoundedRectangle(cornerRadius: Radii.control))
        .draggable(Drag.folder(folder.id))
        .dropDestination(for: String.self) { items, _ in
            Drag.apply(items, to: folder.id, model: model)
        } isTargeted: { target = $0 }
        .rightClickMenu { menu }
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

    private var selected: Bool { model.place == .feed(feed.id) }

    var body: some View {
        Group {
            if model.renaming == .feed(feed.id) {
                RenameField(name: feed.name) { model.renameFeed(feed.id, to: $0) }
                    .frame(height: 32)
            } else {
                Button { model.go(to: .feed(feed.id)) } label: {
                    HStack {
                        Text(feed.name)
                            .font(.ui(14, selected ? .semibold : .regular))
                            .foregroundStyle(feed.unread == 0 ? p.muted : p.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if feed.unread > 0 {
                            Text(feed.unread, format: .number.grouping(.never)).font(.ui(13, .medium)).foregroundStyle(p.unread)
                        }
                    }
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 26 + CGFloat(depth) * 16).padding(.trailing, 10)
        .background(selected ? p.selectedStrong : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
        .draggable(Drag.feed(feed.id))
        .rightClickMenu { FeedMenu(feed: feed) }
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
                MenuRow(title: "Top level", checked: feed.folderId == nil) { act { model.moveFeed(feed.id, to: nil) } }
                ForEach(model.folderOutline(), id: \.folder.id) { row in
                    MenuRow(title: row.folder.name, checked: feed.folderId == row.folder.id, indent: CGFloat(row.depth) * 16) {
                        act { model.moveFeed(feed.id, to: row.folder.id) }
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
        Text(text).font(.custom(family, fixedSize: 24).weight(.semibold)).tracking(-0.24).padding(.bottom, 6)
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
    }
}

enum ShortcutList {
    static let move = [
        ("Next, previous", "j k"), ("Open", "Return"), ("Back", "Esc"), ("Next unread", "n"),
        ("Search", "/"), ("Briefing, All, Starred", "⌘1 ⌘2 ⌘3"),
    ]
    static let act = [
        ("Star", "s"), ("Read or unread", "m"), ("Unread only", "u"), ("Open page here", "o"), ("Open in browser", "⇧O"),
        ("Fetch full article", "f"), ("Refresh", "r"), ("Add feed", "a"), ("Text and theme", "t"),
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
                    Text("Shortcuts").font(.custom(family, fixedSize: 26).weight(.semibold)).tracking(-0.26)
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
