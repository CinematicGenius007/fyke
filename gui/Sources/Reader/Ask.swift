// Ask your feeds: a question over a view or over everything, answered only from your
// articles, with each claim cited. An answer can become a routine.
import AppKit
import Observation
import ReaderLogic
import SwiftUI

@MainActor @Observable
final class AskModel {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var job: Job?
        var answer: Artifact?
        var problem: String?
    }

    var turns: [Turn] = []
    var view: Int64?
    var draft = ""

    var latest: Turn? { turns.last }
    var isAsking: Bool { latest?.job?.isActive == true }

    func start(question: String, view: Int64?, model: AppModel) {
        turns = []
        self.view = view
        draft = question
        model.web = nil
        model.detail = .ask
        if !question.trimmingCharacters(in: .whitespaces).isEmpty { submit(model) }
    }

    /// A follow-up names the question before it, so the writer answers in context.
    func submit(_ model: AppModel) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking else { return }
        draft = ""
        let question = latest.map { "Earlier question: \($0.question)\nFollow-up: \(text)" } ?? text
        turns.append(Turn(question: text))
        let index = turns.count - 1
        Task {
            do {
                let job = try await model.library.write("ask.run", .init(viewId: view, question: question))
                turns[index].job = job
                guard let done = await model.library.finished(job.id) else { return }
                turns[index].job = done
                switch done.state {
                case .done:
                    if let id = done.artifactId { turns[index].answer = try await model.library.artifact("answers.get", id) }
                    if turns[index].answer == nil { turns[index].problem = "The writer finished without an answer." }
                case .failed: turns[index].problem = done.error ?? "The writer stopped."
                case .cancelled: turns[index].problem = "You cancelled it."
                default: break
                }
            } catch {
                turns[index].problem = AppModel.words(for: error)
            }
        }
    }
}

struct AskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily

    private var ask: AskModel { model.ask }
    private var scope: String { ask.view.flatMap { model.library.view($0)?.name }.map { "in \($0)" } ?? "in all your feeds" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BackBar(title: model.article == nil ? "Back" : "Back to article") { model.detail = nil }
                Spacer()
                if let answer = ask.latest?.answer {
                    Button("Copy") { copy(answer) }.buttonStyle(ActionStyle(kind: .quiet, height: Metrics.compactControl))
                    Button("Make it a routine") { makeRoutine() }.buttonStyle(ActionStyle(kind: .quiet, height: Metrics.compactControl))
                        .disabled(model.library.views.isEmpty)
                }
            }
            .padding(.horizontal, Metrics.barEdge).frame(height: Metrics.barHeight)
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let turn = ask.latest, let answer = turn.answer {
            ArtifactColumn(artifact: answer, open: { id in
                model.detail = nil
                Task { await model.open(id) }
            }) {
                header(turn)
            } footer: {
                followUp
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let turn = ask.latest {
                        header(turn)
                        if let problem = turn.problem {
                            InlineState(tone: .failed, label: "No answer", title: "This question was not answered", detail: "\(problem) Nothing changed in your feeds.",
                                        primary: ("Ask again", { ask.draft = turn.question; ask.turns.removeLast(); ask.submit(model) }))
                        } else {
                            InlineState(tone: .working, label: "Answering", title: "Reading your articles \(scope)",
                                        detail: "\(model.library.selectedWriter?.name ?? "The writer") answers only from your articles and cites each one it uses. Nothing is changed while it reads.",
                                        primary: turn.job.map { job in ("Cancel", { Task { await model.library.cancel(job.id) } }) })
                        }
                    } else {
                        Text("Ask your feeds").font(.title(titleFamily, 34, .semibold)).tracking(-0.5).padding(.bottom, 8)
                        Text("Answers come only from your articles \(scope), with every claim cited.").font(.ui(14)).foregroundStyle(p.inkSoft).padding(.bottom, 24)
                        questionField(placeholder: "Which posts disagree about…", autofocus: true)
                        if !model.library.available {
                            Text("This needs a newer Fyke service.").font(.ui(13)).foregroundStyle(p.muted).padding(.top, 12)
                        }
                    }
                }
                .frame(maxWidth: Metrics.readingColumn, alignment: .leading)
                .padding(.horizontal, Metrics.pageGutter).padding(.top, 48).padding(.bottom, 96)
                .frame(maxWidth: .infinity)
            }
            .themedScrollbar()
        }
    }

    private func header(_ turn: AskModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if ask.turns.count > 1 {
                ForEach(ask.turns.dropLast()) { earlier in
                    Text("Earlier: \(earlier.question)").font(.ui(13)).foregroundStyle(p.muted).lineLimit(1)
                }
                .padding(.bottom, 12)
            }
            HStack(spacing: 8) {
                GeneratedTag(text: "Asked")
                Text([scope, turn.answer.map { "\(Plural.count(Int(max($0.inputCount, Int64($0.citations.count))), "article")) read" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(13)).foregroundStyle(p.muted)
            }
            .padding(.bottom, 12)
            Text(turn.question).font(.title(titleFamily, 32, .semibold)).tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 24)
                .textSelection(.enabled)
        }
    }

    private var followUp: some View {
        questionField(placeholder: "Ask a follow-up", autofocus: false)
    }

    private func questionField(placeholder: String, autofocus: Bool) -> some View {
        QuestionField(ask: ask, placeholder: placeholder, autofocus: autofocus) { ask.submit(model) }
    }

    private func copy(_ answer: Artifact) {
        let text = answer.sections.map { section in
            ([section.heading].compactMap { $0 } + [section.claims.map { $0.text + $0.sources.map { " [\($0)]" }.joined() }.joined(separator: " ")]).joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n\n" + answer.citations.map { "[\($0.number)] \($0.title)" + ($0.url.map { " <\($0)>" } ?? "") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The question becomes a routine that briefs the same view on a schedule.
    private func makeRoutine() {
        guard let question = ask.latest?.question else { return }
        model.newRoutine(view: ask.view, name: String(question.prefix(60)), actions: [RoutineAction(kind: .brief), RoutineAction(kind: .notify)])
    }
}

private struct QuestionField: View {
    @Bindable var ask: AskModel
    let placeholder: String
    let autofocus: Bool
    let submit: () -> Void
    @Environment(\.palette) private var p
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(p.muted)
            TextField("", text: $ask.draft, prompt: Text(placeholder).foregroundStyle(p.muted))
                .textFieldStyle(.plain).font(.ui(15))
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel(placeholder)
            Text("Answers only from your feeds").font(.ui(12)).foregroundStyle(p.muted)
            Button(action: submit) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: Metrics.compactControl, height: Metrics.compactControl) }
                .buttonStyle(SymbolStyle(selected: !ask.draft.isEmpty))
                .disabled(ask.draft.trimmingCharacters(in: .whitespaces).isEmpty || ask.isAsking)
                .accessibilityLabel("Ask")
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 48)
        .background(p.ground, in: RoundedRectangle(cornerRadius: Radii.panel))
        .overlay(RoundedRectangle(cornerRadius: Radii.panel).stroke(focused ? p.unread : p.control, lineWidth: focused ? 1.5 : 1))
        .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
        .motion(focused, Motion.quick)
    }
}
