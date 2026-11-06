// View state only. Everything durable lives behind the daemon, and this object
// reloads from it when an event says something changed.
import AppKit
import Observation
import SwiftUI

enum Place: Hashable {
    case briefing, all, starred
    case feed(Int64)
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
        }
    }

    var placeUnread: Int64 {
        if case .feed(let id) = place { return feeds.first { $0.id == id }?.unread ?? 0 }
        return totalUnread
    }

    func start() async {
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
        var unreadOnly: Bool
        var starredOnly: Bool
        var limit: Int
        var before: String?
        var withSummary = true
    }

    private var listParams: ListParams {
        var params = ListParams(unreadOnly: unreadOnly, starredOnly: place == .starred, limit: 100)
        if case .feed(let id) = place { params.feedId = id }
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
        guard let id = currentId, let row = entries.first(where: { $0.id == id }) else { return }
        Task { await setRead(id, !row.read) }
    }

    func toggleStar() {
        guard let id = currentId else { return }
        let starred = !(article?.entry.starred ?? entries.first { $0.id == id }?.starred ?? false)
        applyStar(id, starred)
        Task {
            do {
                let _: Ok = try await Daemon.shared.call("entries.mark", MarkParams(id: id, starred: starred))
            } catch {
                applyStar(id, !starred)
                problem = error.localizedDescription
            }
        }
    }

    func moveSelection(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selectedId } ?? (offset > 0 ? -1 : entries.count)
        let next = min(max(index + offset, 0), entries.count - 1)
        selectedId = entries[next].id
        if article != nil || usesPanes { Task { await open(entries[next].id) } }
    }

    /// Feeds show list and reader side by side. All and Starred replace the
    /// timeline with the reader.
    var usesPanes: Bool {
        if case .feed = place { return true }
        return false
    }

    func openSelected() {
        if let id = selectedId { Task { await open(id) } }
    }

    func back() {
        if !usesPanes { article = nil }
    }

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
                fullTextStatus = result.status == "done" ? nil : "No fuller article found on the page"
                await open(id)
            } catch {
                fullTextStatus = error.localizedDescription
            }
        }
    }

    func openPage() {
        guard let text = article?.entry.url ?? entries.first(where: { $0.id == selectedId })?.url else { return }
        Links.open(text)
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
