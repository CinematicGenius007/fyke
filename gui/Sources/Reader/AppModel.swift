// View state only. Everything durable lives behind the daemon, and this object
// reloads from it when an event says something changed.
import AppKit
import Observation
import ReaderLogic
import SwiftUI

enum Place: Hashable {
    case today, all, starred
    case feed(Int64)
    case folder(Int64)
    case view(Int64)
    case routines
}

/// What the sidebar is renaming in place.
enum Renaming: Equatable {
    case feed(Int64)
    case folder(Int64)
    case view(Int64)
}

/// What the reader pane shows in place of an article.
enum Detail: Equatable {
    /// A recipe, opened from the brief it wrote, so that "Back" returns there.
    case recipe(Int64, brief: Int64?)
    /// A question and its answer.
    case ask
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

/// A value shared with a callback on another thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// A move of the data folder, from the question to the result.
@MainActor @Observable
final class DataMove {
    enum Warning {
        case external, noSpace

        var text: String {
            switch self {
            case .external: "This is an external drive. If it is not connected, Fyke cannot start."
            case .noSpace: "There is not enough free space there."
            }
        }
    }

    enum Phase: Equatable {
        case asking
        case moving(String)
        case failed(String)
    }

    let target: URL
    let bytes: Int64
    let warning: Warning?
    var phase = Phase.asking

    init(target: URL, bytes: Int64, warning: Warning?) {
        self.target = target
        self.bytes = bytes
        self.warning = warning
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
    /// True once the first load and any screen asked for at launch are done, or the
    /// load failed. Key replay and snapshots for checks wait for it, so a slow cold
    /// start cannot swallow their first keys.
    @ObservationIgnored static var launched = false
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
    /// The open article's comments.
    var discussion: DiscussionLoad = .idle
    /// Changes when the reader should scroll to the comments.
    var discussionRequest = 0
    var dataMove: DataMove?
    var settingsTab = SettingsView.Tab(rawValue: ProcessInfo.processInfo.environment["FYKE_TAB"] ?? "") ?? .General
    /// Settings fills the list and reader panes while this is set. The place behind it
    /// keeps its article and selection, so closing Settings returns to them.
    var showingSettings = false

    let library = Library()
    let undo = UndoCenter()
    let commands = CommandModel()
    let ask = AskModel()
    var detail: Detail?
    var catchUp: CatchUpModel?
    var showingActivity = false
    /// The brief Today shows.
    var selectedBrief: Int64?
    /// The routine the editor shows: one that exists, or a new one not yet saved.
    var routineDraft: Routine?
    /// The feed whose failure is open beside the sidebar.
    var healthFeed: Int64?
    /// Counts ⌘S presses that are not a search to keep. The open recipe or routine saves.
    var saveRequests = 0

    func saveCommand() {
        if search.isShowing {
            if !search.isBlank { saveSearchAsView() }
        } else {
            saveRequests += 1
        }
    }

    private var pendingReload: Task<Void, Never>?

    var totalUnread: Int64 { feeds.reduce(0) { $0 + $1.unread } }
    var isEmpty: Bool { hasLoaded && feeds.isEmpty }

    var placeTitle: String {
        switch place {
        case .today: "Today"
        case .all: "All"
        case .starred: "Starred"
        case .feed(let id): feeds.first { $0.id == id }?.name ?? "Feed"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "Folder"
        case .view(let id): library.view(id)?.name ?? "View"
        case .routines: "Routines"
        }
    }

    var placeUnread: Int64 {
        switch place {
        case .feed(let id): feeds.first { $0.id == id }?.unread ?? 0
        case .folder(let id): feedsInside(id).reduce(0) { $0 + $1.unread }
        case .view(let id): library.view(id)?.unread ?? 0
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
            await library.load()
            hasLoaded = true
            await openRequestedScreen()
            await openRequestedMove()
            Self.launched = true
            for await event in Daemon.shared.events(since: stats.lastEventSeq) {
                await handle(event)
            }
        } catch {
            problem = error.localizedDescription
            hasLoaded = true
            Self.launched = true
        }
    }

    /// Events about features reload only what they name. Notifications from routines
    /// reach the system while the app runs.
    private func handle(_ event: Event) async {
        switch event.type {
        case "view.changed", "recipe.changed", "routine.changed", "job.changed", "artifact.new":
            await library.handle(event.type)
            if event.type == "view.changed", case .view = place { try? await reloadEntries() }
            if event.type == "artifact.new", place == .today, selectedBrief == nil { selectedBrief = library.briefs.first?.id }
        case "routine.notify":
            Notifier.post(title: "Fyke", body: "A routine has something for you")
        default:
            scheduleReload()
        }
    }

    /// `FYKE_SCREEN` opens one screen at launch, for rendering checks.
    private func openRequestedScreen() async {
        let environment = ProcessInfo.processInfo.environment
        if await openFeatureScreen(environment["FYKE_SCREEN"] ?? "", environment) { return }
        switch environment["FYKE_SCREEN"] {
        case "feed":
            let index = Int(ProcessInfo.processInfo.environment["FYKE_FEED"] ?? "") ?? 0
            guard feeds.indices.contains(index) else { return }
            go(to: .feed(feeds[index].id))
            try? await Task.sleep(for: .milliseconds(300))
            if let row = entries.dropFirst().first { await open(row.id) }
        case "briefing", "today": go(to: .today)
        case "shortcuts": showingShortcuts = true
        case "settings": openSettings()
        case "web":
            if let url = URL(string: ProcessInfo.processInfo.environment["FYKE_ADDRESS"] ?? "") { web = WebState(address: url) }
        case "delete-folder":
            if let folder = folders.first { confirmation = .deleteFolder(folder) }
        case "search":
            search.show()
            search.query = ProcessInfo.processInfo.environment["FYKE_QUERY"] ?? ""
            search.run()
        case "add":
            AddFeedDraft.shared.address = ProcessInfo.processInfo.environment["FYKE_ADDRESS"] ?? ""
            showingAddFeed = true
        default: break
        }
    }

    /// `FYKE_MOVE` asks about moving the data folder at launch, and `FYKE_MOVE_RUN` agrees,
    /// for checks that cannot click a file panel.
    private func openRequestedMove() async {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["FYKE_MOVE"] else { return }
        await proposeMove(to: URL(filePath: path))
        if environment["FYKE_MOVE_RUN"] != nil { startMove() }
    }

    /// A poll can produce hundreds of events at once. One reload covers them.
    private func scheduleReload() {
        if Daemon.shared.paused { return }
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { await reload() }
        }
    }

    func reload() async {
        if Daemon.shared.paused { return }
        do {
            let feedList: Items<Feed> = try await Daemon.shared.call("feeds.list")
            let folderList: Items<Folder> = try await Daemon.shared.call("folders.list")
            feeds = feedList.items
            folders = folderList.items
            try await reloadEntries()
            await library.loadViews()
            updatedAt = Date()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    struct ListParams: Encodable, Sendable {
        var feedId: Int64?
        var folderId: Int64?
        var viewId: Int64?
        var rule: SelectionRule?
        var unreadOnly: Bool?
        var starredOnly: Bool?
        var limit: Int
        var before: String?
        var withSummary = true
    }

    /// A view's rule replaces every other filter, which the daemon refuses to mix.
    var listParams: ListParams {
        if case .view(let id) = place { return ListParams(viewId: id, limit: 100) }
        var params = ListParams(unreadOnly: unreadOnly, starredOnly: place == .starred, limit: 100)
        if case .feed(let id) = place { params.feedId = id }
        if case .folder(let id) = place { params.folderId = id }
        return params
    }

    /// Today and Routines list briefs and routines, not articles.
    var listsEntries: Bool { place != .today && place != .routines }

    func reloadEntries() async throws {
        guard listsEntries else {
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
        // Choosing the place Settings covers only uncovers it, with nothing reset.
        if showingSettings {
            showingSettings = false
            if place == self.place { return }
        }
        self.place = place
        web = nil
        article = nil
        selectedId = nil
        detail = nil
        entries = []
        if place == .today { selectedBrief = selectedBrief ?? library.briefs.first?.id }
        if place == .routines, routineDraft == nil, let first = library.routines.first { routineDraft = first }
        Task { try? await reloadEntries() }
    }

    /// Opens a search result where the reader can show it.
    func openResult(_ id: Int64) {
        search.close()
        showingSettings = false
        if !listsEntries { go(to: .all) }
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
        discussion = .idle
        web = nil
        detail = nil
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
    /// Whether the sidebar marks `place` as the one showing. None is while Settings is.
    func isShowing(_ place: Place) -> Bool { !showingSettings && self.place == place }

    /// Shows Settings in the main window, at `tab` when one is named.
    func openSettings(_ tab: SettingsView.Tab? = nil) {
        if let tab { settingsTab = tab }
        showingSettings = true
    }

    var usesPanes: Bool {
        switch place {
        case .feed, .folder, .view, .today, .routines: true
        default: false
        }
    }

    func openSelected() {
        if let id = selectedId { Task { await open(id) } }
    }

    func back() {
        if web != nil {
            closeWeb()
        } else if detail != nil {
            detail = nil
        } else if place == .today && article != nil {
            article = nil
            selectedId = nil
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

    /// The page open in the reader if there is one, or else the article's page.
    func openInBrowser() {
        if let web {
            NSWorkspace.shared.open(web.browserAddress)
        } else if let text = pageAddress {
            Links.open(text)
        }
    }

    /// The open article's comments: read here for Hacker News, as a page otherwise.
    func openDiscussion() {
        guard web == nil, let text = article?.entry.discussionUrl, let url = URL(string: text) else { return }
        if Discussions.hackerNewsId(url) != nil { showDiscussion() } else { openLink(url) }
    }

    /// Scrolls to the open article's comments, loading them the first time.
    func showDiscussion() {
        if case .idle = discussion { loadDiscussion() }
        if case .failed = discussion { loadDiscussion() }
        discussionRequest += 1
    }

    func loadDiscussion() {
        guard let id = article?.entry.id else { return }
        discussion = .loading
        Task {
            do {
                let thread: Discussion = try await Daemon.shared.callSlow("entries.discussion", IdParams(id: id))
                if article?.entry.id == id { discussion = .loaded(thread) }
            } catch {
                guard article?.entry.id == id else { return }
                let text = error.localizedDescription
                discussion = .failed(text.contains("DiscussionUnavailable") ? "Hacker News did not answer." : text)
            }
        }
    }

    /// Command-click always means the browser. Feed content chooses these addresses,
    /// and the check in `Links` applies on both routes.
    func openLink(_ url: URL) {
        guard Links.isSafe(url) else { return }
        let toBrowser = Prefs.shared.ui.openLinks == "browser" || NSEvent.modifierFlags.contains(.command)
        // The article's own Hacker News thread reads better under it than as a page.
        if !toBrowser, web == nil, let thread = Discussions.hackerNewsId(url),
           thread == Discussions.hackerNewsId(article?.entry.discussionUrl) {
            showDiscussion()
            return
        }
        if toBrowser {
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

    // MARK: Data folder

    /// Asks the person to choose a folder, then asks whether to go ahead.
    func chooseDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        Task { await proposeMove(to: chosen) }
    }

    /// A folder that already holds something gets a folder of its own inside it, so
    /// that data never mixes with someone else's files.
    private func proposeMove(to chosen: URL) async {
        let manager = FileManager.default
        func isEmpty(_ url: URL) -> Bool { ((try? manager.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty }
        var target = chosen
        if !isEmpty(chosen) {
            target = chosen.appending(path: "fyke_data")
            if manager.fileExists(atPath: target.path) && !isEmpty(target) {
                problem = "That folder already holds a fyke_data folder"
                return
            }
        }
        let use: StorageUse? = try? await Daemon.shared.call("storage.get", NoParams())
        let bytes = (use?.databaseBytes ?? 0) + (use?.rawBytes ?? 0) + (use?.logBytes ?? 0) + (use?.settingsBytes ?? 0)
        let keys: Set<URLResourceKey> = [
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIdentifierKey,
        ]
        var warning: DataMove.Warning?
        let here = try? Daemon.shared.home.resolvingSymlinksInPath().resourceValues(forKeys: keys)
        if let values = try? chosen.resourceValues(forKeys: keys) {
            // Inside one volume a move is a rename, which needs no room and unplugs nothing.
            let sameVolume = values.volumeIdentifier?.isEqual(here?.volumeIdentifier) ?? false
            if sameVolume {
                warning = nil
            } else if let free = values.volumeAvailableCapacityForImportantUsage, free < bytes * 12 / 10 {
                warning = .noSpace
            } else if values.volumeIsInternal != true || values.volumeIsLocal == false || values.volumeIsRemovable == true {
                // A disk image reports no answer for internal, so only a yes counts.
                warning = .external
            }
        }
        dataMove = DataMove(target: target, bytes: bytes, warning: warning)
    }

    /// Runs `fyke data move`, so that the work of stopping the daemon, moving files and
    /// restarting is in one place that the terminal uses too.
    func startMove() {
        guard let move = dataMove, move.phase == .asking, move.warning != .noSpace else { return }
        move.phase = .moving("Stopping…")
        Daemon.shared.paused = true
        let program = Daemon.shared.programPath
        let target = move.target.path
        Task {
            let result = await Self.runMove(program: program, target: target) { stage in
                Task { @MainActor in move.phase = .moving(stage) }
            }
            Daemon.shared.paused = false
            if result.status == 0 {
                dataMove = nil
                await Prefs.shared.load()
                await reload()
            } else {
                // Past "starting" the data and the link are in place, and only the restart failed.
                let moved = result.output.contains("starting")
                move.phase = .failed(moved ? Self.movedButNotRestarted : Self.moveFailure(result.errors))
                await reload()
            }
        }
    }

    private nonisolated static let stageNames = [
        "stopping": "Stopping", "moving": "Moving", "verifying": "Checking the copy", "linking": "Linking", "starting": "Restarting",
    ]

    /// Runs the command and reports each stage as it prints it, since a copy can take minutes.
    private nonisolated static func runMove(program: String, target: String, stage: @escaping @Sendable (String) -> Void) async -> (status: Int32, output: String, errors: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: program)
            process.arguments = ["data", "move", target]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let seen = Locked("")
            out.fileHandleForReading.readabilityHandler = { handle in
                let text = String(decoding: handle.availableData, as: UTF8.self)
                seen.update { $0 += text }
                for line in text.split(separator: "\n") { if let name = stageNames[String(line)] { stage(name + "…") } }
            }
            do { try process.run() } catch { return (1, "", error.localizedDescription) }
            process.waitUntilExit()
            out.fileHandleForReading.readabilityHandler = nil
            let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, seen.value, errors)
        }.value
    }

    static let movedButNotRestarted = "Your data moved, but Fyke could not restart. Opening Fyke again usually fixes this."

    /// A failed move says what happened, not what was asked: the data stayed, or only the restart failed.
    static func moveFailureHeading(_ reason: String) -> String {
        reason == movedButNotRestarted ? "Fyke didn\u{2019}t restart" : "Your data wasn\u{2019}t moved"
    }

    /// The command names what stopped it, and only a few of these a person can cause.
    private static func moveFailure(_ text: String) -> String {
        let reasons = [
            ("TargetNotEmpty", "That folder is not empty."),
            ("InsideCurrentFolder", "That folder is inside the one in use."),
            ("ParentMissing", "That folder's location does not exist."),
            ("NoSpaceLeft", "There was not enough free space."),
            ("DaemonStillRunning", "Fyke could not stop its background service."),
            ("VerifyFailed", "The copy did not match, so nothing was changed."),
        ]
        let reason = reasons.first { text.contains($0.0) }?.1 ?? "Something went wrong."
        return reason + " Your data is where it was."
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

    /// Marks a feed, a folder or a view read at once, and offers Undo. The unread
    /// articles are read first so that exactly those can be put back.
    func markAllRead(feed: Int64? = nil, folder: Int64? = nil, view: Int64? = nil) {
        Task {
            var params = ListParams(feedId: feed, folderId: folder, viewId: view, unreadOnly: view == nil ? true : nil, limit: 1000)
            if view != nil { params.rule = nil }
            do {
                var ids: [Int64] = []
                var cursor: String?
                repeat {
                    params.before = cursor
                    let page: EntryPage = try await Daemon.shared.call("entries.list", params)
                    ids += page.items.filter { !$0.read }.map(\.id)
                    cursor = page.nextCursor
                } while cursor != nil && ids.count < 20000
                guard !ids.isEmpty else { return }
                let previous = try await library.mark(ids, read: true)
                let name = view.flatMap { library.view($0)?.name } ?? feed.flatMap { id in feeds.first { $0.id == id }?.name } ?? folder.flatMap { id in folders.first { $0.id == id }?.name } ?? "All"
                undo.push("Marked \(Plural.count(ids.count, "article")) in \(name) as read") { [self] in
                    try? await self.library.restore(previous)
                    await self.reload()
                }
            } catch let failure as RPCFailure where failure.isUnknownMethod && view == nil {
                // A daemon without mark_many still marks; it cannot offer Undo.
                let _: Ok? = try? await Daemon.shared.call("entries.mark_all", MarkAllParams(feedId: feed, folderId: folder))
            } catch {
                problem = error.localizedDescription
            }
            await reload()
        }
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
