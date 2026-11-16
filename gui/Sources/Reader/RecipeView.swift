// A recipe, opened in place from the brief it wrote: Edit it, Try it on the same
// articles without saving a brief, or go back through its History. Every save is a
// new revision, and a brief keeps the revision it was written with.
import AppKit
import ReaderLogic
import SwiftUI

struct RecipeView: View {
    let recipeId: Int64
    let briefId: Int64?
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily

    enum Tab: Hashable { case edit, tryIt, history }

    @State private var tab = Tab.edit
    @State private var recipe: Recipe?
    @State private var draft = ""
    @State private var conflict: Recipe?
    @State private var saving = false
    @State private var problem: String?

    private var dirty: Bool { recipe.map { $0.text != draft } ?? false }
    private var brief: Artifact? { model.library.briefs.first { $0.id == briefId } }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let recipe {
                        Text(recipe.name).font(.custom(titleFamily, fixedSize: 34).weight(.semibold)).tracking(-0.5)
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle(recipe)).font(.ui(13)).foregroundStyle(p.muted).padding(.top, 8).padding(.bottom, 24)
                        switch tab {
                        case .edit: editor(recipe)
                        case .tryIt: RecipeTrial(recipe: recipe, text: draft, brief: brief)
                        case .history: RecipeHistory(recipe: recipe) { text in
                                draft = text
                                tab = .edit
                            }
                        }
                    } else if let problem {
                        InlineState(tone: .failed, label: "Recipe", title: "This recipe could not be opened", detail: "\(problem) The brief and its recipe are unchanged.",
                                    primary: ("Back to the brief", { model.detail = nil }))
                    } else {
                        Spinner(size: 16)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 48).padding(.top, 40).padding(.bottom, 96)
                .frame(maxWidth: .infinity)
            }
            .themedScrollbar()
        }
        .task(id: recipeId) { await load() }
        .onChange(of: model.saveRequests) {
            if tab == .edit && dirty && !saving { Task { await save() } }
        }
        .onChange(of: model.library.recipes) { _, _ in
            // Another client saved: take the new text unless this one has edits.
            if let fresh = model.library.recipe(recipeId), fresh.revision != recipe?.revision, !dirty {
                recipe = fresh
                draft = fresh.text
            }
        }
    }

    private func subtitle(_ recipe: Recipe) -> String {
        let users = model.library.routines.filter { $0.actions.contains { $0.kind == .brief && $0.recipeId == recipe.id } }.count
        var parts = ["Tells \(model.library.selectedWriter?.name ?? "the writer") how to write the brief"]
        if users > 0 { parts.append("used by \(Plural.count(users, "routine"))") }
        parts.append("revision \(recipe.revision)")
        if let date = recipe.updatedAt { parts.append("edited \(Dates.relative(date))") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            let fetched = try await model.library.fetchRecipe(recipeId) ?? model.library.recipe(recipeId)
            recipe = fetched
            draft = fetched?.text ?? ""
            if fetched == nil { problem = "It is no longer there." }
        } catch {
            problem = AppModel.words(for: error)
        }
    }

    private var bar: some View {
        HStack {
            BackBar(title: briefId == nil ? "Back" : "Brief", trailing: recipe.map { "\($0.name) recipe" }) { model.detail = nil }
                .padding(.top, -11).padding(.leading, -14)
            Spacer()
            Tabs(selection: $tab, items: [(.edit, "Edit"), (.tryIt, "Try it"), (.history, "History")])
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    @ViewBuilder private func editor(_ recipe: Recipe) -> some View {
        if let conflict {
            ConflictNote(theirs: conflict, keepMine: {
                Task { await save(over: conflict) }
            }, takeTheirs: {
                self.recipe = conflict
                draft = conflict.text
                self.conflict = nil
            })
            .padding(.bottom, 16)
        }
        RecipeEditor(text: $draft)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(p.muted)
            Text("Fyke adds the selected articles and its citation rules after your text. They are fixed, so a recipe cannot turn citations off.")
                .font(.ui(13)).foregroundStyle(p.inkSoft).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 14)
        HStack(spacing: 8) {
            if dirty {
                Circle().fill(p.unread).frame(width: 6, height: 6)
                Text("Unsaved changes").font(.ui(13)).foregroundStyle(p.muted)
            } else if let problem {
                Text(problem).font(.ui(13)).foregroundStyle(p.muted)
            }
            Spacer()
            if recipe.builtIn {
                Button("Reset to built-in") { Task { await reset(recipe) } }.buttonStyle(ActionStyle(kind: .quiet))
                    .disabled(saving)
            }
            Button("Revert") { draft = recipe.text }.buttonStyle(ActionStyle(kind: .secondary)).disabled(!dirty || saving)
            Button(briefId == nil ? "Save" : "Save and rewrite the brief") { Task { await save() } }
                .buttonStyle(ActionStyle(kind: .primary))
                .disabled(!dirty || saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Save (⌘S)")
        }
        .padding(.top, 24)
    }

    private func save(over theirs: Recipe? = nil) async {
        guard var base = recipe else { return }
        if let theirs { base.revision = theirs.revision }
        saving = true
        defer { saving = false }
        do {
            let saved = try await model.library.saveRecipe(base, text: draft)
            recipe = saved
            draft = saved.text
            conflict = nil
            problem = nil
            if let brief { model.runBrief(view: brief.viewId, recipe: saved.id) }
        } catch let failure as RPCFailure where failure.is("RevisionConflict") {
            // The current text arrives with the refusal, or is read again.
            if let current = failure.data?["current"], let theirs = Recipe(current) {
                conflict = theirs
            } else {
                conflict = try? await model.library.fetchRecipe(base.id)
            }
        } catch {
            problem = AppModel.words(for: error)
        }
    }

    private func reset(_ recipe: Recipe) async {
        let before = recipe
        do {
            let fresh = try await model.library.resetRecipe(recipe)
            self.recipe = fresh
            draft = fresh.text
            model.undo.push("Reset “\(recipe.name)” to the built-in text") {
                guard let now = model.library.recipe(before.id) else { return }
                _ = try? await model.library.saveRecipe(now, text: before.text, note: "Undo reset")
            }
        } catch {
            problem = AppModel.words(for: error)
        }
    }
}

/// Markdown in the code font, in a bordered box.
struct RecipeEditor: View {
    @Binding var text: String
    @Environment(\.palette) private var p
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.code(13))
            .scrollContentBackground(.hidden)
            .lineSpacing(6)
            .padding(16)
            .frame(minHeight: 300)
            .background(p.ground, in: RoundedRectangle(cornerRadius: Radii.panel))
            .overlay(RoundedRectangle(cornerRadius: Radii.panel).stroke(focused ? p.unread : p.hairline, lineWidth: focused ? 1.5 : 1))
            .focused($focused)
            .accessibilityLabel("Recipe text")
            .motion(focused, Motion.quick)
    }
}

/// The recipe changed elsewhere since it was opened. Nothing is lost either way.
private struct ConflictNote: View {
    let theirs: Recipe
    let keepMine: () -> Void
    let takeTheirs: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This recipe changed elsewhere (revision \(theirs.revision)).").font(.ui(14, .medium))
            Text("Your edits are still here and nothing is saved yet. Keeping yours makes it the newest revision; the other stays in History.")
                .font(.ui(13)).foregroundStyle(p.inkSoft).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keep mine", action: keepMine).buttonStyle(ActionStyle(kind: .primary, height: 28))
                Button("Use the newer one", action: takeTheirs).buttonStyle(ActionStyle(kind: .quiet, height: 28))
            }
            .padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.selected, in: RoundedRectangle(cornerRadius: Radii.panel))
    }
}

/// Writes with the unsaved text over the brief's articles. The result is not listed
/// as a brief, so trying costs nothing but the writer's time.
private struct RecipeTrial: View {
    let recipe: Recipe
    let text: String
    let brief: Artifact?
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var job: Job?
    @State private var result: Artifact?
    @State private var problem: String?
    @State private var focus: CitationFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(brief.map { "Writes over the \(Plural.count(Int($0.inputCount), "article")) of this brief with the text in Edit, saved or not." }
                    ?? "Writes over your newest unread articles with the text in Edit, saved or not.")
                    .font(.ui(13)).foregroundStyle(p.inkSoft).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(result == nil ? "Try it" : "Try again") { start() }
                    .buttonStyle(ActionStyle(kind: .primary))
                    .disabled(job?.isActive == true)
            }
            .padding(.bottom, 28)
            if let job, job.isActive {
                InlineState(tone: .working, label: "Trying the recipe", title: "Writing a trial brief",
                            detail: "Nothing is saved: the trial is not listed in Today, and the recipe keeps its text until you save it.",
                            primary: ("Cancel", { Task { await model.library.cancel(job.id) } }))
            } else if let problem {
                InlineState(tone: .failed, label: "Trial failed", title: "The trial did not finish", detail: "\(problem) The recipe and your briefs are unchanged.",
                            primary: ("Try again", start))
            } else if let result {
                GeneratedTag(text: "Trial · not saved").padding(.bottom, 14)
                Text(result.title).font(.custom(Fonts.resolve(Prefs.shared.currentFonts.title ?? Tokens.fontReading), fixedSize: 28).weight(.semibold)).padding(.bottom, 16)
                BriefBody(artifact: result, focus: nil)
            }
        }
    }

    private func start() {
        problem = nil
        result = nil
        Task {
            do {
                let queued = try await model.library.write("briefs.try", .init(viewId: brief?.viewId, rule: brief?.viewId == nil ? brief?.rule : nil, recipeId: recipe.id, text: text))
                job = queued
                guard let done = await model.library.finished(queued.id) else { return }
                job = done
                if done.state == .done {
                    if let id = done.artifactId { result = try await model.library.artifact("briefs.get", id) }
                    if result == nil { problem = "The writer finished but returned nothing to show." }
                } else if done.state == .failed {
                    problem = done.error ?? "The writer stopped."
                }
            } catch {
                problem = AppModel.words(for: error)
            }
        }
    }
}

private struct RecipeHistory: View {
    let recipe: Recipe
    let restore: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var revisions: [RecipeRevision] = []
    @State private var open: Int64?
    @State private var texts: [Int64: String] = [:]
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem {
                Text(problem).font(.ui(13)).foregroundStyle(p.muted)
            }
            ForEach(revisions) { revision in
                VStack(alignment: .leading, spacing: 0) {
                    Rule()
                    Button {
                        open = open == revision.revision ? nil : revision.revision
                        if texts[revision.revision] == nil {
                            Task {
                                if let text = revision.text { texts[revision.revision] = text; return }
                                texts[revision.revision] = try? await model.library.revisionText(recipe.id, revision.revision)
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text("Revision \(revision.revision)").font(.ui(14, .medium))
                            if revision.revision == recipe.revision { Text("current").font(.ui(12)).foregroundStyle(p.muted) }
                            Text(revision.note).font(.ui(13)).foregroundStyle(p.inkSoft).lineLimit(1)
                            Spacer()
                            Text(revision.createdAt.map { Dates.relative($0) } ?? "").font(.ui(12)).foregroundStyle(p.muted)
                            Image(systemName: open == revision.revision ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(p.muted)
                        }
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open == revision.revision {
                        Text(texts[revision.revision] ?? "…").font(.code(12)).foregroundStyle(p.inkSoft).lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14).background(p.surface, in: RoundedRectangle(cornerRadius: Radii.control))
                        if revision.revision != recipe.revision, let text = texts[revision.revision] {
                            Button("Put this text in Edit") { restore(text) }.buttonStyle(ActionStyle(kind: .secondary, height: 28)).padding(.vertical, 10)
                        }
                    }
                }
            }
            Rule()
        }
        .task(id: recipe.revision) {
            do { revisions = try await model.library.history(recipe.id) } catch { problem = AppModel.words(for: error) }
        }
    }
}
