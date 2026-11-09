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
    var dataMove: DataMove?
    var settingsTab = SettingsView.Tab(rawValue: ProcessInfo.processInfo.environment["FYKE_TAB"] ?? "") ?? .General

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
            await openRequestedMove()
            for await event in Daemon.shared.events(since: stats.lastEventSeq) {
                _ = event
                scheduleReload()
            }
        } catch {
            problem = error.localizedDescription
            hasLoaded = true
        }
    }

    /// `FYKE_SCREEN` opens one screen at launch, for rendering checks.
    private func openRequestedScreen() async {
        switch ProcessInfo.processInfo.environment["FYKE_SCREEN"] {
        case "feed":
            let index = Int(ProcessInfo.processInfo.environment["FYKE_FEED"] ?? "") ?? 0
            guard feeds.indices.contains(index) else { return }
            go(to: .feed(feeds[index].id))
            try? await Task.sleep(for: .milliseconds(300))
            if let row = entries.dropFirst().first { await open(row.id) }
        case "briefing": go(to: .briefing)
        case "shortcuts": showingShortcuts = true
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
                move.phase = .failed(moved ? "Your data moved, but Fyke could not restart. Opening Fyke again usually fixes this." : Self.moveFailure(result.errors))
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
