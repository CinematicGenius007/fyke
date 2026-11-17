// Catch up: unread articles one at a time. Skip (←) marks read, Later (↓) saves for
// later, Read now (→) opens it. Every mark returns the state before it, so ⌘Z puts
// the article back exactly as it was and shows it again.
import Observation
import ReaderLogic
import SwiftUI

@MainActor @Observable
final class CatchUpModel {
    let title: String
    private let params: AppModel.ListParams
    private weak var model: AppModel?
    private(set) var session = CatchUpSession<Int64>([])
    private(set) var rows: [Int64: EntrySummary] = [:]
    private var previous: [Int64: Previous] = [:]
    var loaded = false
    var problem: String?

    init(title: String, params: AppModel.ListParams, model: AppModel) {
        self.title = title
        self.params = params
        self.model = model
    }

    var current: EntrySummary? { session.current.flatMap { rows[$0] } }

    func load() async {
        var params = params
        params.limit = 500
        do {
            let page: EntryPage = try await Daemon.shared.call("entries.list", params)
            let unread = page.items.filter { !$0.read }
            rows = Dictionary(unread.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            session = CatchUpSession(unread.map(\.id))
        } catch {
            problem = AppModel.words(for: error)
        }
        loaded = true
    }

    func decide(_ decision: CatchUpSession<Int64>.Decision) {
        guard let model, let id = session.decide(decision) else { return }
        Task {
            do {
                let before = try await model.library.mark([id], read: decision == .later ? nil : true, later: decision == .later ? true : nil)
                previous[id] = before[id]
            } catch {
                problem = AppModel.words(for: error)
            }
            if decision == .read {
                model.catchUp = nil
                if !model.listsEntries || model.place == .routines { model.go(to: .all) }
                await model.open(id)
            }
        }
    }

    /// Takes back the last decision and shows that article again.
    func undo() {
        guard let model, let last = session.undo() else { return }
        let before = previous.removeValue(forKey: last.id)
        Task {
            if let before { try? await model.library.restore([last.id: before]) }
            else { _ = try? await model.library.mark([last.id], read: false, later: false) }
        }
    }

    func close() {
        model?.catchUp = nil
        Task { await model?.reload() }
    }
}

struct CatchUpView: View {
    let catchUp: CatchUpModel
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily
    @Environment(\.readingFamily) private var family
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 24)
            main
            footer.padding(.top, 32)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.surface)
        // The screen takes keys for the arrows; it is not a control, so it draws no
        // ring. Its buttons keep the system ring for Tab with Full Keyboard Access.
        .focusable(true)
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down, action: key)
        .motion(catchUp.session.index)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Catching up on \(catchUp.title)")
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .leftArrow: catchUp.decide(.skip)
        case .downArrow: catchUp.decide(.later)
        case .rightArrow, .return: catchUp.decide(.read)
        case .escape: catchUp.close()
        default: return .ignored
        }
        return .handled
    }

    @ViewBuilder private var main: some View {
        if let problem = catchUp.problem {
            InlineState(tone: .failed, label: "Could not load", title: "Catch up could not start", detail: "\(problem) Nothing was marked.", primary: ("Close", { catchUp.close() }))
        } else if !catchUp.loaded {
            Spinner(size: 18)
        } else if let row = catchUp.current {
            card(row).id(row.id).transition(.opacity)
            buttons.padding(.top, 52)
        } else {
            finished
        }
    }

    private var finished: InlineState {
        let empty = catchUp.session.queue.isEmpty
        let catchUp = catchUp
        let done: (String, () -> Void) = ("Done", { catchUp.close() })
        var undo: (String, () -> Void)?
        if !catchUp.session.history.isEmpty { undo = ("Undo last", { catchUp.undo() }) }
        let title = empty ? "Nothing unread here" : "You’re caught up"
        let detail = empty ? "Every article in \(catchUp.title) is read." : summary + ". Articles saved for Later wait in their feeds."
        return InlineState(tone: .empty, label: catchUp.title, title: title, detail: detail, primary: done, secondary: undo)
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 8) {
                Text("Catching up on \(catchUp.title)").font(.ui(13, .semibold))
                ProgressLine(fraction: catchUp.session.progress).frame(width: 200)
            }
            HStack {
                Spacer()
                Button { catchUp.close() } label: {
                    HStack(spacing: 8) { Text("Done"); Text("esc").foregroundStyle(p.muted) }
                }
                .buttonStyle(ActionStyle(kind: .secondary, height: Metrics.compactControl))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.trailing, Metrics.barEdge)
        }
        .padding(.top, Metrics.barControlTop)
    }

    private func card(_ row: EntrySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text([row.feedTitle, Dates.relative(row.date)].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(12)).foregroundStyle(p.muted).padding(.bottom, 16)
            Text(row.title ?? "Untitled")
                .font(.custom(titleFamily, fixedSize: 32).weight(.semibold)).tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)
            if let text = row.preview {
                Text(text).font(.custom(family, fixedSize: 17)).foregroundStyle(p.inkSoft).line(28, size: 17).lineLimit(5)
            }
            Spacer(minLength: 0)
        }
        .padding(48)
        .frame(width: 680, height: 396, alignment: .topLeading)
        .background(p.ground, in: RoundedRectangle(cornerRadius: Radii.sheet))
        .overlay(RoundedRectangle(cornerRadius: Radii.sheet).stroke(p.hairline))
        .shadow(color: .black.opacity(0x14 / 255), radius: 3, y: 2)
        .background(alignment: .bottom) {
            // The edges of the next articles, so the stack reads as a stack.
            ZStack {
                RoundedRectangle(cornerRadius: Radii.sheet).fill(p.ground).overlay(RoundedRectangle(cornerRadius: Radii.sheet).stroke(p.hairline))
                    .frame(width: 616, height: 40).offset(y: 24)
                RoundedRectangle(cornerRadius: Radii.sheet).fill(p.ground).overlay(RoundedRectangle(cornerRadius: Radii.sheet).stroke(p.hairline))
                    .frame(width: 648, height: 40).offset(y: 12)
            }
            .opacity(catchUp.session.queue.count - catchUp.session.index > 1 ? 1 : 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            triage("Skip", symbol: "xmark", key: "←", kind: .secondary) { catchUp.decide(.skip) }
            triage("Later", symbol: "clock", key: "↓", kind: .secondary) { catchUp.decide(.later) }
            triage("Read now", symbol: "checkmark", key: "→", kind: .primary) { catchUp.decide(.read) }
        }
        .frame(width: 680)
    }

    private func triage(_ title: String, symbol: String, key: String, kind: ActionStyle.Kind, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(.ui(16, .medium))
                KeyHint(text: key, onDark: kind == .primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionStyle(kind: kind, height: 56))
        .accessibilityLabel(title)
        .accessibilityHint("Shortcut \(key)")
    }

    private var summary: String {
        "Skipped \(catchUp.session.count(.skip)) · Later \(catchUp.session.count(.later)) · Read \(catchUp.session.count(.read))"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !catchUp.session.queue.isEmpty {
                Text("\(min(catchUp.session.index + 1, catchUp.session.queue.count)) of \(catchUp.session.queue.count)")
                Text("·")
                Text(summary)
                if !catchUp.session.history.isEmpty {
                    Text("·")
                    Button("Undo last ⌘Z") { catchUp.undo() }.buttonStyle(.bare).foregroundStyle(p.unread)
                }
            }
        }
        .font(.ui(13)).foregroundStyle(p.muted)
        .frame(height: 20)
    }
}
