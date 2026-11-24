// What the reader features do when a person acts: save a search, run a brief, start
// catching up. Each is one operation or a short sequence of them.
import AppKit
import Foundation
import ReaderLogic
@preconcurrency import UserNotifications

extension AppModel {
    // MARK: Views

    /// Keeps the current search as a view and puts its name up for editing, so naming
    /// it is the next keystroke and Return keeps the suggestion.
    func saveSearchAsView() {
        let rule = SelectionRule.fromSearch(search.query, unreadOnly: search.unreadOnly)
        saveAsView(rule)
        search.close()
    }

    func saveAsView(_ rule: SelectionRule, name: String? = nil) {
        let taken = Set(library.views.map(\.name))
        let name = ViewName.unique(name ?? ViewName.suggest(for: rule), taken: taken)
        Task {
            do {
                let view = try await library.saveView(name: name, rule: rule)
                go(to: .view(view.id))
                renaming = .view(view.id)
                undo.push("Saved “\(view.name)” as a view") { [self] in
                    try? await self.library.removeView(view.id, detach: true)
                    if self.place == .view(view.id) { self.go(to: .all) }
                }
            } catch {
                problem = Self.words(for: error)
            }
        }
    }

    func renameView(_ id: Int64, to name: String) {
        renaming = nil
        guard let view = library.view(id), !name.trimmingCharacters(in: .whitespaces).isEmpty, name != view.name else { return }
        Task {
            do { _ = try await library.saveView(id: id, name: name, rule: view.rule, revision: view.revision) }
            catch { problem = Self.words(for: error) }
        }
    }

    /// Changes a view's rule from its sentence. The list follows at once, and Undo
    /// puts the old rule back.
    func setRule(_ rule: SelectionRule, of id: Int64) {
        guard let view = library.view(id), rule.normalized != view.rule.normalized else { return }
        let old = view.rule
        Task {
            do {
                _ = try await library.saveView(id: id, name: view.name, rule: rule, revision: view.revision)
                try? await reloadEntries()
                undo.push("Changed “\(view.name)”") { [self] in
                    guard let now = library.view(id) else { return }
                    _ = try? await library.saveView(id: id, name: now.name, rule: old, revision: now.revision)
                    try? await reloadEntries()
                }
            } catch let failure as RPCFailure where failure.is("RevisionConflict") {
                await library.loadViews()
                problem = "This view changed elsewhere. It now shows the newer rule."
            } catch {
                problem = Self.words(for: error)
            }
        }
    }

    func moveView(_ id: Int64, by offset: Int) {
        guard let index = library.views.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), library.views.count - 1)
        guard target != index else { return }
        Task {
            do { try await library.moveView(id, to: target) } catch { problem = Self.words(for: error) }
        }
    }

    /// Removes at once. Routines that look in the view are detached, and Undo makes
    /// the view again and points them back at it.
    func removeView(_ id: Int64) {
        guard let view = library.view(id) else { return }
        let users = library.routines.filter { $0.viewId == id }
        if place == .view(id) { go(to: .all) }
        Task {
            do {
                try await library.removeView(id, detach: true)
                undo.push("Removed “\(view.name)”") { [self] in
                    guard let made = try? await library.saveView(name: view.name, rule: view.rule) else { return }
                    try? await library.moveView(made.id, to: Int(view.position))
                    for var routine in users {
                        routine.viewId = made.id
                        routine.revision = library.routine(routine.id)?.revision ?? routine.revision
                        _ = try? await library.saveRoutine(routine)
                    }
                }
            } catch {
                problem = Self.words(for: error)
            }
        }
    }

    // MARK: Briefs

    /// The brief being written now, if any.
    var briefJob: Job? { library.activeJobs.first { $0.isWriting && $0.kind != "answer" && $0.kind != "ask" && $0.kind != "try" && $0.kind != "brief_try" } }

    /// The last brief that failed, when nothing has been written since.
    var failedBrief: Job? {
        library.needsYou.first { $0.isWriting && ["brief", "digest", "synthesize"].contains($0.kind) }
    }

    /// Writes a brief for a view, or for the unread articles when there is none. The
    /// daemon reads at most the newest 60 of them.
    func runBrief(view: Int64? = nil, recipe: Int64? = nil) {
        let brief = library.briefs.first { $0.id == selectedBrief }
        let view = view ?? brief?.viewId ?? (place.viewId)
        let rule: SelectionRule? = view == nil ? (brief?.rule ?? SelectionRule(state: .unread)) : nil
        Task {
            do {
                _ = try await library.write("briefs.run", .init(viewId: view, rule: rule, recipeId: recipe ?? brief?.recipeId ?? library.recipes.first?.id, writer: nil))
                if place != .today { go(to: .today) }
                selectedBrief = nil
                article = nil
            } catch {
                problem = Self.words(for: error)
            }
        }
    }

    func openRecipe(_ id: Int64?, from brief: Int64? = nil) {
        guard let id = id ?? library.recipes.first?.id else { return }
        web = nil
        detail = .recipe(id, brief: brief)
    }

    // MARK: Catch up

    /// Starts triage over what the current place shows, unread only.
    func startCatchUp() {
        var params = listParams
        if params.viewId == nil { params.unreadOnly = true }
        let title: String = switch place {
        case .today, .routines: "All"
        default: placeTitle
        }
        let session = CatchUpModel(title: title, params: params, model: self)
        catchUp = session
        Task { await session.load() }
    }

    // MARK: Routines

    /// A new routine starts from a view, so that nothing begins at an empty form.
    func newRoutine(view: Int64? = nil, name: String? = nil, actions: [RoutineAction]? = nil) {
        let view = view ?? place.viewId ?? library.views.first?.id
        var routine = Routine(name: name ?? library.view(view).map { "Morning \($0.name.lowercased())" } ?? "New routine", viewId: view)
        if let actions { routine.actions = actions }
        if let recipe = library.recipes.first?.id {
            routine.actions = routine.actions.map { action in
                var action = action
                if action.kind == .brief && action.recipeId == nil { action.recipeId = recipe }
                return action
            }
        }
        routineDraft = routine
        go(to: .routines)
        routineDraft = routine
    }

    // MARK: Feeds

    var failingFeeds: [Feed] { feeds.filter(\.isFailing) }

    // MARK: Words

    /// The daemon names its refusals. These are the ones a person can act on.
    static func words(for error: Error) -> String {
        guard let failure = error.rpc else { return error.localizedDescription }
        let known: [(String, String)] = [
            ("UnknownMethod", "This needs a newer Fyke service. Quit and open Fyke again."),
            ("InvalidRule", "That rule has a word the reader cannot use."),
            ("InvalidName", "Give it a name."),
            ("RevisionConflict", "This changed elsewhere since you opened it."),
            ("TierDenied", "Fyke's service refused the change."),
            ("WriterNotFound", "No writer is installed. Choose one in Settings · Agents."),
            ("ConflictingFilters", "A view cannot be combined with other filters."),
        ]
        return known.first { failure.is($0.0) }?.1 ?? failure.message
    }

    // MARK: Screens for checks

    /// More `FYKE_SCREEN` values, for the feature screens. Returns true when handled.
    func openFeatureScreen(_ name: String, _ environment: [String: String]) async -> Bool {
        switch name {
        case "view":
            if let view = library.views.first {
                go(to: .view(view.id))
                try? await Task.sleep(for: .milliseconds(300))
                if let row = entries.first { await open(row.id) }
            }
        case "all":
            go(to: .all)
            try? await Task.sleep(for: .milliseconds(300))
            if let row = entries.first { await open(row.id) }
        case "starred":
            go(to: .starred)
            try? await Task.sleep(for: .milliseconds(300))
            if let row = entries.first { await open(row.id) }
        case "folder":
            if let folder = folders.first {
                go(to: .folder(folder.id))
                try? await Task.sleep(for: .milliseconds(300))
                if let row = entries.first { await open(row.id) }
            }
        case "view-empty":
            // The newest view, which the check makes to match nothing.
            if let view = library.views.last { go(to: .view(view.id)) }
        case "routines":
            go(to: .routines)
            if library.routines.isEmpty { newRoutine() }
        case "catchup": startCatchUp()
        case "palette":
            commands.show()
            commands.query = environment["FYKE_QUERY"] ?? ""
            commands.searchArticles()
        case "recipe":
            go(to: .today)
            openRecipe(library.briefs.first?.recipeId, from: library.briefs.first?.id)
        case "ask":
            if let view = library.views.first { go(to: .view(view.id)) }
            ask.start(question: environment["FYKE_QUERY"] ?? "", view: place.viewId, model: self)
        case "activity":
            showingActivity = true
        case "shortcuts":
            showingShortcuts = true
        case "health":
            if let feed = failingFeeds.first ?? feeds.first { healthFeed = feed.id }
        case "toast":
            undo.push("Marked 12 articles in Databases as read") {}
        default:
            return false
        }
        return true
    }
}

extension Place {
    var viewId: Int64? {
        if case .view(let id) = self { return id }
        return nil
    }
}

extension Feed {
    /// A feed that failed its last fetches. It keeps its articles; only new ones stop.
    var isFailing: Bool { errorCount > 0 && lastError != nil }
}

/// System notifications for routines that ask to notify. A running app posts them as
/// the events arrive. With the app closed, the daemon opens a hidden copy with
/// `--notify`, which posts one and quits (`src/notify.zig`). Clicking it opens Fyke.
enum Notifier {
    static let title = "Fyke"
    static let body = "A routine has something for you"

    static func post(title: String = title, body: String = body, then done: @escaping @Sendable () -> Void = {}) {
        // A headless check must not reach the notification center of the person at this Mac.
        guard Bundle.main.bundleIdentifier != nil, !TestMode.headless else { return done() }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return done() }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in done() }
        }
    }

    /// The `--notify` launch: posts, then quits before any window opens. The callbacks
    /// arrive on other queues, so the main thread can wait for them.
    static func postAndQuitIfAsked() {
        guard CommandLine.arguments.contains("--notify") else { return }
        let posted = DispatchSemaphore(value: 0)
        post { posted.signal() }
        _ = posted.wait(timeout: .now() + 30)
        exit(0)
    }
}
