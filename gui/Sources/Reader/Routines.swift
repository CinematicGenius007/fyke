// Routines: When / Look in / Then, as three lines of words. A dry run over last week
// shows what one would have done before it runs.
import ReaderLogic
import SwiftUI

struct RoutineList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Routines").font(.ui(20, .semibold)).tracking(-0.2)
                Spacer()
                SymbolButton(symbol: "plus", label: "New routine") { model.newRoutine() }
                    .disabled(model.library.views.isEmpty)
            }
            .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 16)
            Rule().meetsDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let draft = model.routineDraft, draft.id == nil {
                        RoutineRow(routine: draft)
                    }
                    ForEach(model.library.routines) { routine in RoutineRow(routine: routine) }
                    if model.library.routines.isEmpty && model.routineDraft == nil {
                        Text(model.library.views.isEmpty
                             ? "A routine looks in a view. Save a search as a view first (⌘F, then ⌘S)."
                             : "A routine runs on a schedule over one of your views.")
                            .font(.ui(13)).foregroundStyle(p.muted).padding(12)
                    }
                }
                .padding(.horizontal, Metrics.listEdge).padding(.top, Metrics.listTop).padding(.bottom, Metrics.listEdge)
            }
            .themedScrollbar()
        }
        .background(p.ground)
    }
}

private struct RoutineRow: View {
    let routine: Routine
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var hovering = false

    private var selected: Bool { model.routineDraft?.id == routine.id && (routine.id != nil || model.routineDraft?.name == routine.name) }
    private var failed: Job? { model.library.needsYou.first { $0.routineId == routine.id } }

    var body: some View {
        Button { model.routineDraft = routine } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(routine.id == nil ? "\(routine.name) (not saved)" : routine.name).font(.ui(14, .semibold))
                        .foregroundStyle(routine.enabled ? p.ink : p.muted)
                    Text(([routine.schedule.summary] + routine.actions.map(\.kind.short)).joined(separator: " · "))
                        .font(.ui(13)).foregroundStyle(p.inkSoft)
                    if let failed {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                            Text(failed.error ?? "Last run failed").lineLimit(1)
                        }
                        .font(.ui(12)).foregroundStyle(p.ink)
                    } else {
                        Text(routine.enabled ? routine.lastRunAt.map { "Last run \(Dates.relative($0))" + (routine.lastMatches.map { " · \(Plural.count(Int($0), "match", "matches"))" } ?? "") } ?? "Not run yet" : "Paused")
                            .font(.ui(12)).foregroundStyle(p.muted)
                    }
                }
                Spacer(minLength: 48)
            }
            .padding(12)
            .background(selected ? p.selected : hovering ? p.selected.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // Outside the row's button, so that it toggles without selecting.
            if routine.id != nil {
                Switch(on: Binding(get: { routine.enabled }, set: { on in
                    var changed = routine
                    changed.enabled = on
                    Task { _ = try? await model.library.saveRoutine(changed) }
                }))
                .accessibilityLabel(routine.enabled ? "Pause \(routine.name)" : "Resume \(routine.name)")
                .padding(12)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension RoutineAction.Kind {
    var short: String {
        switch self {
        case .brief: "brief"
        case .notify: "notify"
        case .markRead: "mark read"
        case .star: "star"
        case .tag: "tag"
        }
    }

    var symbol: String {
        switch self {
        case .brief: "doc.text"
        case .notify: "bell"
        case .markRead: "checkmark.circle"
        case .star: "star"
        case .tag: "tag"
        }
    }
}

struct RoutineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily
    @Environment(\.readingFamily) private var family
    @State private var routine = Routine(name: "", viewId: nil)
    @State private var dryRun: DryRun?
    @State private var dryRunProblem: String?
    @State private var problem: String?
    @State private var saving = false
    @State private var renaming = false
    @State private var frames: [String: CGRect] = [:]

    private var saved: Routine? { model.library.routine(routine.id) }
    private var dirty: Bool { routine.id == nil || saved.map { $0 != routine } ?? true }

    var body: some View {
        Group {
            if model.routineDraft == nil {
                InlineState(tone: .empty, label: "Routines", title: model.library.views.isEmpty ? "Routines start from a view" : "No routine chosen",
                            detail: model.library.views.isEmpty ? "Search for what you follow, keep it with ⌘S, and a routine can brief it every morning." : "Pick one on the left, or make one from a view.",
                            primary: model.library.views.isEmpty ? ("Search", { model.search.show() }) : ("New routine", { model.newRoutine() }))
                    .padding(.horizontal, Metrics.pageGutter).padding(.top, 96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                editor
            }
        }
        .onChange(of: model.routineDraft, initial: true) { _, draft in
            if let draft, draft.id != routine.id || routine.name.isEmpty || draft.id == nil {
                routine = draft
                dryRun = nil
            }
        }
        .task(id: routine.id) { await refreshDryRun() }
        .onChange(of: model.saveRequests) {
            if model.routineDraft != nil && dirty && !saving && routine.viewId != nil && !routine.actions.isEmpty { Task { await save() } }
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if renaming {
                    Field(placeholder: "Routine name", text: $routine.name, height: 44, font: .custom(titleFamily, fixedSize: 30).weight(.semibold), submit: { renaming = false }, autofocus: true)
                } else {
                    Button { renaming = true } label: {
                        Text(routine.name).font(.custom(titleFamily, fixedSize: 34).weight(.semibold)).tracking(-0.5)
                    }
                    .buttonStyle(.plain)
                    .help("Rename")
                    .accessibilityHint("Rename the routine")
                }
                Text("Runs in the background while Fyke’s service runs, even with this window closed.")
                    .font(.ui(13)).foregroundStyle(p.muted).padding(.top, 8).padding(.bottom, 24)
                lines
                dryRunSection.padding(.top, 36)
                Rule().padding(.top, 24)
                footer.padding(.top, 16)
            }
            .frame(maxWidth: Metrics.readingColumn, alignment: .leading)
            .padding(.horizontal, Metrics.pageGutter).padding(.top, 64).padding(.bottom, 96)
            .frame(maxWidth: .infinity)
        }
        .themedScrollbar()
        .overlay(alignment: .topTrailing) {
            if routine.id != nil {
                Button("Remove") { remove() }.buttonStyle(ActionStyle(kind: .quiet, height: Metrics.compactControl))
                    .padding(.top, Metrics.barControlTop).padding(.trailing, Metrics.barEdge)
            }
        }
    }

    // MARK: When / Look in / Then

    private var lines: some View {
        VStack(alignment: .leading, spacing: 0) {
            line("When") {
                HStack(spacing: 4) {
                    menuChip("repeat", routine.schedule.repeatWords) { repeatMenu }
                    if routine.schedule.kind != .manual {
                        Text("at").font(.ui(13)).foregroundStyle(p.muted)
                        menuChip("time", routine.schedule.time ?? "07:30") { timeMenu }
                    }
                }
            }
            Rule()
            line("Look in") {
                HStack(spacing: 4) {
                    menuChip("view", model.library.view(routine.viewId)?.name ?? "Choose a view") { viewMenu }
                    Text("for articles new since the last run").font(.ui(13)).foregroundStyle(p.muted)
                }
            }
            Rule()
            line("Then") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(routine.actions.enumerated()), id: \.offset) { index, action in
                        actionRow(action, index: index)
                    }
                    Button { show("add") { addMenu } } label: {
                        HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)); Text("Add action") }
                            .foregroundStyle(p.unread)
                    }
                    .buttonStyle(ActionStyle(kind: .quiet, height: Metrics.compactControl))
                    .floatFrame(binding("add"))
                    .padding(.leading, -10)
                }
            }
        }
        .background(p.ground, in: RoundedRectangle(cornerRadius: Radii.panel))
        .overlay(RoundedRectangle(cornerRadius: Radii.panel).stroke(p.hairline))
    }

    private func line<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).font(.ui(13, .medium)).foregroundStyle(p.inkSoft).frame(width: 84, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func actionRow(_ action: RoutineAction, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: action.kind.symbol).font(.system(size: 12)).foregroundStyle(p.inkSoft).frame(width: 14)
            actionWords(action, index: index)
            Spacer()
            if action.kind == .brief {
                Text(model.library.selectedWriter?.name ?? "No writer").font(.ui(12)).foregroundStyle(p.muted)
            }
            SymbolButton(symbol: "xmark", label: "Remove this action", size: 24) { routine.actions.remove(at: index) }
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: Metrics.panelRow)
        .background(p.surface, in: RoundedRectangle(cornerRadius: Radii.control))
    }

    @ViewBuilder private func actionWords(_ action: RoutineAction, index: Int) -> some View {
        switch action.kind {
        case .brief:
            HStack(spacing: 4) {
                Text("Write a brief with").font(.ui(14))
                menuChip("recipe\(index)", model.library.recipe(action.recipeId)?.name ?? "a recipe") {
                    MenuList(rows: model.library.recipes.count) {
                        ForEach(model.library.recipes) { recipe in
                            MenuRow(title: recipe.name, checked: recipe.id == action.recipeId) {
                                routine.actions[index].recipeId = recipe.id
                                layer.close()
                            }
                        }
                    }
                }
            }
        case .notify: Text("Notify me").font(.ui(14))
        case .markRead: Text("Mark them read").font(.ui(14))
        case .star: Text("Star them").font(.ui(14))
        case .tag:
            HStack(spacing: 4) {
                Text("Tag them").font(.ui(14))
                Field(placeholder: "tag", text: Binding(get: { routine.actions[index].tag ?? "" }, set: { routine.actions[index].tag = $0 }), height: 24, font: .ui(13))
                    .frame(width: 120)
                    .accessibilityLabel("Tag")
            }
        }
    }

    // MARK: Menus

    private func binding(_ key: String) -> Binding<CGRect> {
        Binding(get: { frames[key] ?? .zero }, set: { frames[key] = $0 })
    }

    private func show<Content: View>(_ key: String, @ViewBuilder _ content: () -> Content) {
        let frame = frames[key] ?? .zero
        layer.show(at: frame) { content().frame(minWidth: 200, alignment: .leading).floatPanel() }
    }

    private func menuChip<Content: View>(_ key: String, _ text: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        Chip(text: text, selected: layer.item != nil && frames["open"] == frames[key], height: 28) {
            frames["open"] = frames[key]
            show(key, content)
        }
        .floatFrame(binding(key))
    }

    private var repeatMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([Schedule(kind: .weekdays), Schedule(kind: .daily), Schedule(kind: .weekly, days: [1]), Schedule(kind: .weekly, days: [5]), Schedule(kind: .manual)], id: \.self) { option in
                MenuRow(title: option.repeatWords, checked: option.kind == routine.schedule.kind && (option.days == nil || option.days == routine.schedule.days)) {
                    routine.schedule = Schedule(kind: option.kind, time: option.kind == .manual ? nil : routine.schedule.time ?? "07:30", days: option.days)
                    layer.close()
                }
            }
        }
    }

    private var timeMenu: some View {
        MenuList(rows: 48) {
            ForEach(Schedule.halfHours, id: \.self) { time in
                MenuRow(title: time, checked: time == routine.schedule.time) {
                    routine.schedule.time = time
                    layer.close()
                }
            }
        }
    }

    private var viewMenu: some View {
        MenuList(rows: model.library.views.count) {
            ForEach(model.library.views) { view in
                MenuRow(title: view.name, detail: view.sentence, checked: view.id == routine.viewId) {
                    routine.viewId = view.id
                    layer.close()
                    Task { await refreshDryRun() }
                }
            }
        }
    }

    private var addMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RoutineAction.Kind.allCases, id: \.self) { kind in
                let title = switch kind {
                case .brief: "Write a brief"
                case .notify: "Notify me"
                case .markRead: "Mark them read"
                case .star: "Star them"
                case .tag: "Tag them"
                }
                MenuRow(title: title) {
                    routine.actions.append(RoutineAction(kind: kind, recipeId: kind == .brief ? model.library.recipes.first?.id : nil))
                    layer.close()
                }
            }
        }
    }

    // MARK: Dry run

    @ViewBuilder private var dryRunSection: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Dry run · last week")
                if routine.id == nil {
                    Text("Save to see what this routine would have caught last week.")
                        .font(.custom(family, fixedSize: 17)).foregroundStyle(p.inkSoft)
                } else if let dryRun {
                    Text(DryRunWords.summary(counts: dryRun.days.map(\.count)))
                        .font(.custom(family, fixedSize: 19)).fixedSize(horizontal: false, vertical: true)
                    ForEach(dryRun.actions, id: \.self) { line in
                        Text(line).font(.ui(13)).foregroundStyle(p.muted)
                    }
                } else if let dryRunProblem {
                    Text(dryRunProblem).font(.ui(13)).foregroundStyle(p.muted)
                } else {
                    Spinner(size: 12)
                }
            }
            Spacer()
            if let dryRun, !dryRun.days.isEmpty { bars(dryRun) }
        }
    }

    private func bars(_ dryRun: DryRun) -> some View {
        let heights = DryRunWords.bars(dryRun.days.map(\.count))
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(dryRun.days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: Radii.mark).fill(day.count == 0 ? p.hairline : p.unread)
                        .frame(width: 20, height: max(3, 40 * heights[index]))
                    Text(day.label).font(.ui(11)).foregroundStyle(p.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.label): \(Plural.count(day.count, "article"))")
            }
        }
        .frame(height: 60, alignment: .bottom)
    }

    private func refreshDryRun() async {
        dryRunProblem = nil
        guard let id = routine.id else { return }
        do { dryRun = try await model.library.dryRun(id) } catch { dryRunProblem = AppModel.words(for: error) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(problem ?? nextWords).font(.ui(13)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Run now") { runNow() }.buttonStyle(ActionStyle(kind: .secondary))
                .disabled(routine.id == nil || saving)
            Button("Save") { Task { await save() } }.buttonStyle(ActionStyle(kind: .primary))
                .disabled(!dirty || saving || routine.viewId == nil || routine.actions.isEmpty)
                .help("Save (⌘S)")
        }
    }

    private var nextWords: String {
        if routine.schedule.kind == .manual { return "Runs only when you press Run now." }
        if let next = saved?.nextRunAt, !dirty {
            return "Next run \(next.formatted(.dateTime.weekday(.wide).hour().minute())). Missed while asleep? It runs once on wake."
        }
        return "Missed while asleep? It runs once on wake, never twice."
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let made = try await model.library.saveRoutine(routine)
            routine = made
            model.routineDraft = made
            problem = nil
            await refreshDryRun()
        } catch {
            problem = AppModel.words(for: error)
        }
    }

    private func runNow() {
        guard let id = routine.id else { return }
        Task {
            do {
                try await model.library.runRoutine(id)
                model.showingActivity = true
            } catch {
                problem = AppModel.words(for: error)
            }
        }
    }

    private func remove() {
        guard let id = routine.id else { return }
        let copy = routine
        Task {
            do {
                try await model.library.removeRoutine(id)
                model.routineDraft = model.library.routines.first
                model.undo.push("Removed “\(copy.name)”") {
                    var again = copy
                    again.id = nil
                    again.revision = nil
                    _ = try? await model.library.saveRoutine(again)
                }
            } catch {
                problem = AppModel.words(for: error)
            }
        }
    }
}
