// View state only. Everything durable lives behind the daemon, and this object
// reloads from it when an event says something changed.
import AppKit
import Observation
import SwiftUI

enum Place: Hashable {
    case briefing, all, starred
    case feed(Int64)
    case folder(Int64)
}

/// What the sidebar is renaming in place.
enum Renaming: Equatable {
    case feed(Int64)
    case folder(Int64)
}

enum Confirmation: Identifiable {
    case deleteFolder(Folder)
    case removeFeed(Feed)

    var id: String {
        switch self {
        case .deleteFolder(let folder): "folder\(folder.id)"
        case .removeFeed(let feed): "feed\(feed.id)"
        }
    }
}

struct Article {
    var entry: Entry
    var blocks: [Block]
}

@MainActor @Observable
final class AppModel {
    var feeds: [Feed] = []
    var folders: [Folder] = []
    var place: Place = .all
    var entries: [EntrySummary] = []
    var nextCursor: String?
    var selectedId: Int64?
    var article: Article?
    var unreadOnly = false
    let search = SearchModel()
    var hasLoaded = false
    var problem: String?
    var updatedAt: Date?
    var showingAddFeed = false
    var showingType = false
    var showingShortcuts = false
    var confirmation: Confirmation?
    var renaming: Renaming?
    /// The folder a feed added from a folder's menu goes to.
    var addFeedFolder: Int64?
    /// The remote page showing in place of the reader.
    var web: WebState?
    var fullTextStatus: String?
    var settingsTab = SettingsView.Tab(rawValue: ProcessInfo.processInfo.environment["RSS_TAB"] ?? "") ?? .General

    private var pendingReload: Task<Void, Never>?

    var totalUnread: Int64 { feeds.reduce(0) { $0 + $1.unread } }
    var isEmpty: Bool { hasLoaded && feeds.isEmpty }

    var placeTitle: String {
        switch place {
        case .briefing: "Briefing"
        case .all: "All"
        case .starred: "Starred"
        case .feed(let id): feeds.first { $0.id == id }?.name ?? "Feed"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "Folder"
        }
    }

    var placeUnread: Int64 {
        switch place {
        case .feed(let id): feeds.first { $0.id == id }?.unread ?? 0
        case .folder(let id): feedsInside(id).reduce(0) { $0 + $1.unread }
        default: totalUnread
        }
    }

    var totalStarred: Int64 { feeds.reduce(0) { $0 + $1.starred } }

    func childFolders(of parent: Int64?) -> [Folder] { folders.filter { $0.parentId == parent } }

    /// Every folder inside this one, at any depth.
    func foldersInside(_ id: Int64) -> [Folder] {
        childFolders(of: id).flatMap { [$0] + foldersInside($0.id) }
    }

    /// Feeds in a folder and in every folder inside it.
    func feedsInside(_ id: Int64) -> [Feed] {
        let ids = Set([id] + foldersInside(id).map(\.id))
        return feeds.filter { $0.folderId.map(ids.contains) ?? false }
    }

    /// Folders with their depth, in the order the sidebar shows them.
    func folderOutline(parent: Int64? = nil, depth: Int = 0) -> [(folder: Folder, depth: Int)] {
        childFolders(of: parent).flatMap { [($0, depth)] + folderOutline(parent: $0.id, depth: depth + 1) }
    }

    /// The daemon outlives the app, so after an update it can be an older one, and
    /// nothing else would replace it. Stopping it is safe: the next call starts ours.
    private func replaceOutdatedDaemon() async {
        func current() async -> Bool {
            let stats: Stats? = try? await Daemon.shared.call("stats.get")
            return (stats?.apiVersion ?? 0) >= Daemon.apiVersion
        }
        guard await !current() else { return }
        let _: Ok? = try? await Daemon.shared.call("daemon.stop")
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if await current() { return }
        }
    }

    func start() async {
        await replaceOutdatedDaemon()
        await Prefs.shared.start()
        do {
            let stats: Stats = try await Daemon.shared.call("stats.get")
            await reload()
            hasLoaded = true
            await openRequestedScreen()
            for await event in Daemon.shared.events(since: stats.lastEventSeq) {
                _ = event
                scheduleReload()
            }
        } catch {
            problem = error.localizedDescription
            hasLoaded = true
        }
    }

    /// `RSS_SCREEN` opens one screen at launch, for rendering checks.
    private func openRequestedScreen() async {
        switch ProcessInfo.processInfo.environment["RSS_SCREEN"] {
        case "feed":
            let index = Int(ProcessInfo.processInfo.environment["RSS_FEED"] ?? "") ?? 0
            guard feeds.indices.contains(index) else { return }
            go(to: .feed(feeds[index].id))
            try? await Task.sleep(for: .milliseconds(300))
            if let row = entries.dropFirst().first { await open(row.id) }
        case "briefing": go(to: .briefing)
        case "shortcuts": showingShortcuts = true
        case "web":
            if let url = URL(string: ProcessInfo.processInfo.environment["RSS_ADDRESS"] ?? "") { web = WebState(address: url) }
        case "delete-folder":
            if let folder = folders.first { confirmation = .deleteFolder(folder) }
        case "search":
            search.show()
            search.query = ProcessInfo.processInfo.environment["RSS_QUERY"] ?? ""
            search.run()
        case "add":
            AddFeedDraft.shared.address = ProcessInfo.processInfo.environment["RSS_ADDRESS"] ?? ""
            showingAddFeed = true
        default: break
        }
    }

    /// A poll can produce hundreds of events at once. One reload covers them.
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { await reload() }
        }
    }

    func reload() async {
        do {
            let feedList: Items<Feed> = try await Daemon.shared.call("feeds.list")
            let folderList: Items<Folder> = try await Daemon.shared.call("folders.list")
            feeds = feedList.items
            folders = folderList.items
            try await reloadEntries()
            updatedAt = Date()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private struct ListParams: Encodable, Sendable {
        var feedId: Int64?
        var folderId: Int64?
        var unreadOnly: Bool
        var starredOnly: Bool
        var limit: Int
        var before: String?
        var withSummary = true
    }

    private var listParams: ListParams {
        var params = ListParams(unreadOnly: unreadOnly, starredOnly: place == .starred, limit: 100)
        if case .feed(let id) = place { params.feedId = id }
        if case .folder(let id) = place { params.folderId = id }
        return params
    }

    private func reloadEntries() async throws {
        guard place != .briefing else {
            entries = []
            return
        }
        // Keep as many rows as were loaded, so that a background update does not
        // shorten the list under the reader's scroll position.
        var params = listParams
        params.limit = max(100, min(entries.count, 1000))
        let page: EntryPage = try await Daemon.shared.call("entries.list", params)
        entries = page.items
        nextCursor = page.nextCursor
    }

    func loadMore() async {
        guard let cursor = nextCursor else { return }
        var params = listParams
        params.before = cursor
        nextCursor = nil
        do {
            let page: EntryPage = try await Daemon.shared.call("entries.list", params)
            entries += page.items
            nextCursor = page.nextCursor
        } catch {
            problem = error.localizedDescription
        }
    }

    func go(to place: Place) {
        self.place = place
        web = nil
        article = nil
        selectedId = nil
        entries = []
        Task { try? await reloadEntries() }
    }

    /// Opens a search result where the reader can show it, which Briefing cannot.
    func openResult(_ id: Int64) {
        search.close()
        if place == .briefing { go(to: .all) }
        Task { await open(id) }
    }

    func toggleUnreadOnly() {
        unreadOnly.toggle()
        Task { try? await reloadEntries() }
    }

    private struct GetParams: Encodable, Sendable {
        let id: Int64
        var format = "blocks"
    }

    private struct MarkParams: Encodable, Sendable {
        let id: Int64
        var read: Bool?
        var starred: Bool?
    }

    func open(_ id: Int64) async {
        selectedId = id
        fullTextStatus = nil
        web = nil
        do {
            let entry: Entry = try await Daemon.shared.call("entries.get", GetParams(id: id))
            let blocks = try JSONDecoder().decode([Block].self, from: Data(entry.body.utf8))
            guard selectedId == id else { return }
            article = Article(entry: entry, blocks: blocks)
            if !entry.read { await setRead(id, true) }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func setRead(_ id: Int64, _ read: Bool) async {
        applyRead(id, read)
        do {
            let _: Ok = try await Daemon.shared.call("entries.mark", MarkParams(id: id, read: read))
        } catch {
            applyRead(id, !read)
            problem = error.localizedDescription
        }
        await refreshCounts()
    }

    private func applyRead(_ id: Int64, _ read: Bool) {
        update(id) { $0.read = read }
        if article?.entry.id == id { article?.entry.read = read }
    }

    private func applyStar(_ id: Int64, _ starred: Bool) {
        update(id) { $0.starred = starred }
        if article?.entry.id == id { article?.entry.starred = starred }
    }

    private func refreshCounts() async {
        if let list: Items<Feed> = try? await Daemon.shared.call("feeds.list") { feeds = list.items }
    }

    private func update(_ id: Int64, _ change: (inout EntrySummary) -> Void) {
        if let index = entries.firstIndex(where: { $0.id == id }) { change(&entries[index]) }
    }

    private var currentId: Int64? { article?.entry.id ?? selectedId }

    func toggleRead() {
        guard let id = currentId else { return }
        let read = article?.entry.id == id ? article?.entry.read : entries.first { $0.id == id }?.read
        guard let read else { return }
        Task { await setRead(id, !read) }
    }

    func toggleStar(_ row: Int64? = nil) {
        guard let id = row ?? currentId else { return }
        let current = article?.entry.id == id ? article?.entry.starred : entries.first { $0.id == id }?.starred
        let starred = !(current ?? false)
        applyStar(id, starred)
        Task {
            do {
                let _: Ok = try await Daemon.shared.call("entries.mark", MarkParams(id: id, starred: starred))
            } catch {
                applyStar(id, !starred)
                problem = error.localizedDescription
            }
            await refreshCounts()
        }
    }

    func moveSelection(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selectedId } ?? (offset > 0 ? -1 : entries.count)
        let next = min(max(index + offset, 0), entries.count - 1)
        selectedId = entries[next].id
        if article != nil || usesPanes { Task { await open(entries[next].id) } }
    }

    /// Feeds and folders show list and reader side by side. All and Starred replace
    /// the timeline with the reader.
    var usesPanes: Bool {
        switch place {
        case .feed, .folder: true
        default: false
        }
    }

    func openSelected() {
        if let id = selectedId { Task { await open(id) } }
    }

    func back() {
        if web != nil {
            closeWeb()
        } else if !usesPanes {
            article = nil
        }
    }

    func closeWeb() { web = nil }

    func nextUnread() {
        let start = (entries.firstIndex { $0.id == selectedId } ?? -1) + 1
        if let row = entries[min(start, entries.count)...].first(where: { !$0.read }) {
            Task { await open(row.id) }
        }
    }

    private struct IdParams: Encodable, Sendable { let id: Int64 }

    func refresh() {
        Task {
            if case .feed(let id) = place {
                let _: AddResult? = try? await Daemon.shared.callSlow("feeds.refresh", IdParams(id: id))
            } else {
                let _: Ok? = try? await Daemon.shared.callSlow("feeds.refresh_all", NoParams())
            }
            await reload()
        }
    }

    func fetchFull() {
        guard let id = article?.entry.id else { return }
        fullTextStatus = "Fetching the article…"
        Task {
            do {
                let result: StatusResult = try await Daemon.shared.callSlow("entries.fetch_full", IdParams(id: id))
                guard article?.entry.id == id else { return }
                if result.status == "done" {
                    await open(id)
                } else {
                    fullTextStatus = result.status == "later" ? "Could not reach the page. It will be tried again." : "No fuller article found on the page"
                }
            } catch {
                if article?.entry.id == id { fullTextStatus = error.localizedDescription }
            }
        }
    }

    private var pageAddress: String? { article?.entry.url ?? entries.first { $0.id == selectedId }?.url }

    /// Opens the article's page where the settings say links go.
    func openPage() {
        if let text = pageAddress, let url = URL(string: text) { openLink(url) }
    }

    func openInBrowser() {
        if let text = pageAddress { Links.open(text) }
    }

    /// Command-click always means the browser. Feed content chooses these addresses,
    /// and the check in `Links` applies on both routes.
    func openLink(_ url: URL) {
        guard Links.isSafe(url) else { return }
        if Prefs.shared.ui.openLinks == "browser" || NSEvent.modifierFlags.contains(.command) {
            NSWorkspace.shared.open(url)
        } else {
            web = WebState(address: url)
        }
    }

    // MARK: Folders and feeds

    private struct FolderAddParams: Encodable, Sendable { let name: String; var parentId: Int64? }
    private struct FolderRenameParams: Encodable, Sendable { let id: Int64; let name: String }
    private struct FolderMoveParams: Encodable, Sendable { let id: Int64; var parentId: Int64? }
    private struct FolderRemoveParams: Encodable, Sendable { let id: Int64; let deleteContents: Bool }
    private struct FeedUpdateParams: Encodable, Sendable {
        let id: Int64
        var title: String?
        var folderId: Int64?
        var topLevel = false
    }
    private struct MarkAllParams: Encodable, Sendable { var feedId: Int64?; var folderId: Int64? }

    /// Runs a change to subscriptions, then shows the result. The daemon names its
    /// refusals, and only the one a person can cause needs words.
    private func change(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                let text = error.localizedDescription
                problem = text.contains("FolderExists") ? "A folder with that name is already there" : text
            }
            await reload()
        }
    }

    /// Makes a folder and starts renaming it, so that naming is one step.
    func newFolder(in parent: Int64?, holding feed: Int64? = nil) {
        let taken = Set(childFolders(of: parent).map(\.name))
        let name = (["New folder"] + (2...99).map { "New folder \($0)" }).first { !taken.contains($0) } ?? "New folder"
        Task {
            do {
                let made: IdResult = try await Daemon.shared.call("folders.add", FolderAddParams(name: name, parentId: parent))
                if let parent { Prefs.shared.ui.collapsedFolders.removeAll { $0 == parent } }
                if let feed { let _: Ok = try await Daemon.shared.call("feeds.update", FeedUpdateParams(id: feed, folderId: made.id)) }
                await reload()
                renaming = .folder(made.id)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Makes a folder with a name already chosen.
    func addFolder(_ name: String) async -> Int64? {
        do {
            let made: IdResult = try await Daemon.shared.call("folders.add", FolderAddParams(name: name))
            await reload()
            return made.id
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    func newFolderHolding(_ feed: Int64) { newFolder(in: nil, holding: feed) }

    func renameFolder(_ id: Int64, to name: String) {
        renaming = nil
        change { let _: Ok = try await Daemon.shared.call("folders.rename", FolderRenameParams(id: id, name: name)) }
    }

    func moveFolder(_ id: Int64, to parent: Int64?) {
        change { let _: Ok = try await Daemon.shared.call("folders.move", FolderMoveParams(id: id, parentId: parent)) }
    }

    func removeFolder(_ id: Int64, deleteContents: Bool) {
        if place == .folder(id) || (deleteContents && leavesPlace(with: id)) { go(to: .all) }
        change { let _: Ok = try await Daemon.shared.call("folders.remove", FolderRemoveParams(id: id, deleteContents: deleteContents)) }
    }

    private func leavesPlace(with folder: Int64) -> Bool {
        if case .feed(let feed) = place { return feedsInside(folder).contains { $0.id == feed } }
        if case .folder(let inner) = place { return foldersInside(folder).contains { $0.id == inner } }
        return false
    }

    func renameFeed(_ id: Int64, to name: String) {
        renaming = nil
        change { let _: Ok = try await Daemon.shared.call("feeds.update", FeedUpdateParams(id: id, title: name)) }
    }

    func moveFeed(_ id: Int64, to folder: Int64?) {
        change {
            let _: Ok = try await Daemon.shared.call("feeds.update", FeedUpdateParams(id: id, folderId: folder, topLevel: folder == nil))
        }
    }

    func removeFeed(_ id: Int64) {
        if place == .feed(id) { go(to: .all) }
        change { let _: Ok = try await Daemon.shared.call("feeds.remove", IdParams(id: id)) }
    }

    func refreshFeed(_ id: Int64) {
        change { let _: AddResult = try await Daemon.shared.callSlow("feeds.refresh", IdParams(id: id)) }
    }

    func markAllRead(feed: Int64? = nil, folder: Int64? = nil) {
        change { let _: Ok = try await Daemon.shared.call("entries.mark_all", MarkAllParams(feedId: feed, folderId: folder)) }
    }

    func toggleFolder(_ id: Int64) {
        if Prefs.shared.ui.collapsedFolders.contains(id) {
            Prefs.shared.ui.collapsedFolders.removeAll { $0 == id }
        } else {
            Prefs.shared.ui.collapsedFolders.append(id)
        }
    }
}

enum Links {
    /// Feed content chooses these addresses, so only the web is reachable.
    static func isSafe(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    static func open(_ text: String) {
        if let url = URL(string: text), isSafe(url) { NSWorkspace.shared.open(url) }
    }
}
