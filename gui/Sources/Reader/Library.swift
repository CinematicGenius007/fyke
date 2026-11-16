// Views, recipes, briefs, routines, writers and jobs, as the daemon holds them. This
// object only mirrors them: every change is an operation, and an event says when to
// read them again.
import Foundation
import Observation
import ReaderLogic

@MainActor @Observable
final class Library {
    var views: [SavedView] = []
    var recipes: [Recipe] = []
    var routines: [Routine] = []
    var writers: [Writer] = []
    var briefs: [Artifact] = []
    var jobs: [Job] = []
    /// False when the daemon predates these operations. Screens then say so in place.
    var available = true
    var hasLoaded = false

    private struct IdParams: Encodable, Sendable { let id: Int64 }
    private struct LimitParams: Encodable, Sendable { let limit: Int }

    func load() async {
        await loadViews()
        guard available else {
            hasLoaded = true
            return
        }
        async let recipes: Void = loadRecipes()
        async let routines: Void = loadRoutines()
        async let briefs: Void = loadBriefs()
        async let jobs: Void = loadJobs()
        async let writers: Void = loadWriters()
        _ = await (recipes, routines, briefs, jobs, writers)
        hasLoaded = true
    }

    /// Reads again only what an event names.
    func handle(_ type: String) async {
        switch type {
        case "view.changed": await loadViews()
        case "recipe.changed": await loadRecipes()
        case "routine.changed": await loadRoutines()
        case "job.changed": await loadJobs()
        case "artifact.new": await loadBriefs(); await loadJobs()
        case "entry.state", "entry.new", "entries.changed", "feed.changed": await loadViews()
        default: break
        }
    }

    private func attempt<T>(_ work: () async throws -> T) async -> T? {
        do {
            let value = try await work()
            available = true
            return value
        } catch {
            if error.rpc?.isUnknownMethod == true { available = false }
            return nil
        }
    }

    func loadViews() async {
        if let list = await attempt({ try await Daemon.shared.items("views.list", NoParams(), SavedView.init) }) {
            views = list.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
        }
    }

    func loadRecipes() async {
        if let list = await attempt({ try await Daemon.shared.items("recipes.list", NoParams(), Recipe.init) }) { recipes = list }
    }

    func loadRoutines() async {
        if let list = await attempt({ try await Daemon.shared.items("routines.list", NoParams(), Routine.init) }) { routines = list }
    }

    func loadBriefs() async {
        if let list = await attempt({ try await Daemon.shared.items("briefs.list", LimitParams(limit: 50), Artifact.init) }) {
            briefs = list.filter { $0.kind == "digest" }
        }
    }

    func loadJobs() async {
        if let list = await attempt({ try await Daemon.shared.items("jobs.list", LimitParams(limit: 50), Job.init) }) { jobs = list }
    }

    func loadWriters() async {
        if let list = await attempt({ try await Daemon.shared.items("writers.list", NoParams(), Writer.init) }) { writers = list }
    }

    func view(_ id: Int64?) -> SavedView? { views.first { $0.id == id } }
    func recipe(_ id: Int64?) -> Recipe? { recipes.first { $0.id == id } }
    func routine(_ id: Int64?) -> Routine? { routines.first { $0.id == id } }

    /// A job in words: "Morning databases" for a routine's run, otherwise its kind.
    func describe(_ job: Job) -> String {
        if let id = job.routineId, let routine = routine(id) { return routine.name }
        return job.title
    }

    var selectedWriter: Writer? { writers.first(where: \.selected) ?? writers.first(where: \.found) }
    var activeJobs: [Job] { jobs.filter(\.isActive) }

    /// Failed jobs from the last day that nothing has replaced since.
    var needsYou: [Job] {
        let day = Date.now.addingTimeInterval(-86400)
        return jobs.filter { job in
            guard job.state == .failed, (job.finishedAt ?? job.createdAt ?? .distantPast) > day else { return false }
            return !jobs.contains { $0.kind == job.kind && $0.routineId == job.routineId && $0.id > job.id && ($0.state == .done || $0.isActive) }
        }
    }

    var nextRoutine: Routine? {
        routines.filter { $0.enabled && $0.nextRunAt != nil }.min { $0.nextRunAt! < $1.nextRunAt! }
    }

    // MARK: Views

    struct ViewPut: Encodable, Sendable {
        var id: Int64?
        var name: String
        var rule: SelectionRule
        var expectedRevision: Int64?
    }

    func saveView(id: Int64? = nil, name: String, rule: SelectionRule, revision: Int64? = nil) async throws -> SavedView {
        let reply = try await Daemon.shared.json("views.put", ViewPut(id: id, name: name, rule: rule.normalized, expectedRevision: revision))
        await loadViews()
        guard let made = SavedView(reply["view"] ?? reply) ?? reply["id"]?.int.flatMap(view) else {
            throw RPCFailure(message: "The daemon did not return the view")
        }
        return made
    }

    private struct MoveParams: Encodable, Sendable { let id: Int64; let position: Int64 }

    func moveView(_ id: Int64, to position: Int) async throws {
        let _: JSON = try await Daemon.shared.call("views.move", MoveParams(id: id, position: Int64(position)))
        await loadViews()
    }

    private struct RemoveParams: Encodable, Sendable { let id: Int64; let detach: Bool }

    /// Fails with `in_use` while routines look in the view, unless they are detached.
    func removeView(_ id: Int64, detach: Bool) async throws {
        let _: JSON = try await Daemon.shared.call("views.remove", RemoveParams(id: id, detach: detach))
        await loadViews()
    }

    // MARK: Recipes

    struct RecipePut: Encodable, Sendable {
        var id: Int64?
        var name: String
        var text: String
        var note: String
        var expectedRevision: Int64?
    }

    func saveRecipe(_ recipe: Recipe, text: String, note: String = "") async throws -> Recipe {
        let reply = try await Daemon.shared.json("recipes.put", RecipePut(id: recipe.id, name: recipe.name, text: text, note: note, expectedRevision: recipe.revision))
        await loadRecipes()
        return Recipe(reply) ?? self.recipe(recipe.id) ?? recipe
    }

    private struct ResetParams: Encodable, Sendable { let id: Int64; let expectedRevision: Int64 }

    func resetRecipe(_ recipe: Recipe) async throws -> Recipe {
        let reply = try await Daemon.shared.json("recipes.reset", ResetParams(id: recipe.id, expectedRevision: recipe.revision))
        await loadRecipes()
        return Recipe(reply) ?? self.recipe(recipe.id) ?? recipe
    }

    func fetchRecipe(_ id: Int64) async throws -> Recipe? {
        Recipe(try await Daemon.shared.json("recipes.get", IdParams(id: id)))
    }

    func history(_ id: Int64) async throws -> [RecipeRevision] {
        try await Daemon.shared.items("recipes.history", IdParams(id: id), RecipeRevision.init).sorted { $0.revision > $1.revision }
    }

    private struct RevisionParams: Encodable, Sendable { let id: Int64; let revision: Int64 }

    func revisionText(_ id: Int64, _ revision: Int64) async throws -> String {
        try await Daemon.shared.json("recipes.get", RevisionParams(id: id, revision: revision))["text"]?.string ?? ""
    }

    // MARK: Writing

    struct WriteParams: Encodable, Sendable {
        var viewId: Int64?
        var rule: SelectionRule?
        var recipeId: Int64?
        var writer: String?
        var text: String?
        var question: String?
    }

    /// Queues a brief, a trial or an answer, and returns the job.
    func write(_ method: String, _ params: WriteParams) async throws -> Job {
        var params = params
        if params.viewId != nil { params.rule = nil }
        if params.viewId == nil && params.rule == nil { params.rule = SelectionRule() }
        let reply = try await Daemon.shared.json(method, params)
        await loadJobs()
        if let job = Job(reply["job"] ?? reply) { return job }
        if let id = reply["jobId"]?.int, let job = jobs.first(where: { $0.id == id }) { return job }
        throw RPCFailure(message: "The daemon did not return a job")
    }

    /// Waits for a job to finish. Events reload the list, so this only watches it.
    func finished(_ id: Int64) async -> Job? {
        for _ in 0..<1200 {
            if Task.isCancelled { return nil }
            if let job = jobs.first(where: { $0.id == id }), !job.isActive { return job }
            try? await Task.sleep(for: .milliseconds(500))
            await loadJobs()
        }
        return nil
    }

    func artifact(_ method: String, _ id: Int64) async throws -> Artifact? {
        Artifact(try await Daemon.shared.json(method, IdParams(id: id)))
    }

    func cancel(_ job: Int64) async {
        let _: JSON? = try? await Daemon.shared.call("jobs.cancel", IdParams(id: job))
        await loadJobs()
    }

    private struct WriterParams: Encodable, Sendable { let writer: String }

    func check(_ writer: String) async throws {
        let _: JSON = try await Daemon.shared.callSlow("writers.check", WriterParams(writer: writer))
        await loadWriters()
    }

    private struct AIParams: Encodable, Sendable {
        struct AI: Encodable, Sendable { let writer: String }
        let ai: AI
    }

    /// The writer is kept in config.json under `ai`, beside the interface settings.
    func choose(_ writer: String) async throws {
        let _: JSON = try await Daemon.shared.call("config.set", AIParams(ai: .init(writer: writer)))
        await loadWriters()
    }

    // MARK: Routines

    struct RoutinePut: Encodable, Sendable {
        var id: Int64?
        var name: String
        var viewId: Int64
        var schedule: Schedule
        var actions: [[String: AnyEncodable]]
        var enabled: Bool
        var expectedRevision: Int64?
    }

    func saveRoutine(_ routine: Routine) async throws -> Routine {
        guard let view = routine.viewId else { throw RPCFailure(message: "Choose a view to look in") }
        let reply = try await Daemon.shared.json("routines.put", RoutinePut(
            id: routine.id, name: routine.name, viewId: view, schedule: routine.schedule, actions: routine.actions.map(\.wire),
            enabled: routine.enabled, expectedRevision: routine.revision))
        await loadRoutines()
        return Routine(reply["routine"] ?? reply) ?? routine
    }

    func removeRoutine(_ id: Int64) async throws {
        let _: JSON = try await Daemon.shared.call("routines.remove", IdParams(id: id))
        await loadRoutines()
    }

    func dryRun(_ id: Int64) async throws -> DryRun {
        DryRun(try await Daemon.shared.json("routines.dry_run", IdParams(id: id)))
    }

    func runRoutine(_ id: Int64) async throws {
        let _: JSON = try await Daemon.shared.call("routines.run", IdParams(id: id))
        await loadJobs()
        await loadRoutines()
    }

    // MARK: Marks

    struct MarkMany: Encodable, Sendable {
        let ids: [Int64]
        var read: Bool?
        var starred: Bool?
        var later: Bool?
    }

    private struct PreviousList: Decodable, Sendable { let previous: [Previous] }

    /// Marks many articles and returns what they were, so the change can be undone.
    func mark(_ ids: [Int64], read: Bool? = nil, starred: Bool? = nil, later: Bool? = nil) async throws -> [Int64: Previous] {
        var out: [Int64: Previous] = [:]
        for start in stride(from: 0, to: ids.count, by: 1000) {
            let chunk = Array(ids[start..<min(start + 1000, ids.count)])
            let reply: PreviousList = try await Daemon.shared.call("entries.mark_many", MarkMany(ids: chunk, read: read, starred: starred, later: later))
            for (index, previous) in reply.previous.enumerated() { out[previous.id ?? chunk[min(index, chunk.count - 1)]] = previous }
        }
        return out
    }

    /// Puts every article back as it was before a mark, grouped by value so that it
    /// takes at most a few calls.
    func restore(_ previous: [Int64: Previous]) async throws {
        for (key, path) in [("read", \Previous.read), ("starred", \Previous.starred), ("later", \Previous.later)] as [(String, KeyPath<Previous, Bool?>)] {
            for value in [true, false] {
                let ids = previous.filter { $0.value[keyPath: path] == value }.map(\.key)
                guard !ids.isEmpty else { continue }
                var params = MarkMany(ids: ids)
                switch key {
                case "read": params.read = value
                case "starred": params.starred = value
                default: params.later = value
                }
                let _: PreviousList = try await Daemon.shared.call("entries.mark_many", params)
            }
        }
    }
}
