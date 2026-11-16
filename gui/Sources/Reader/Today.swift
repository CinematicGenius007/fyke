// Today: the newest brief, read like an article. The list holds the briefs; the
// reader holds the one chosen, its sources and what made it.
import ReaderLogic
import SwiftUI

struct BriefList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListHeader(title: "Today", trailing: Date.now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Briefs").padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 8)
                    if let job = model.briefJob {
                        WritingRow(job: job)
                    }
                    ForEach(model.library.briefs) { brief in
                        BriefRow(brief: brief)
                    }
                    if model.library.briefs.isEmpty && model.briefJob == nil {
                        Text("Briefs you write appear here, newest first.").font(.ui(13)).foregroundStyle(p.muted)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .themedScrollbar()
        }
        .background(p.ground)
    }
}

/// The title row every list pane starts with.
struct ListHeader: View {
    let title: String
    var trailing: String?
    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.ui(20, .semibold)).tracking(-0.2).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing { Text(trailing).font(.ui(13)).foregroundStyle(p.muted) }
        }
        .padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 20)
    }
}

private struct WritingRow: View {
    let job: Job
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 8) {
            Spinner(size: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text("Writing a brief…").font(.ui(14, .medium))
                Text(job.writer.map { "\($0.capitalized) · started \(job.createdAt.map { Dates.relative($0) } ?? "now")" } ?? "Started just now")
                    .font(.ui(12)).foregroundStyle(p.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BriefRow: View {
    let brief: Artifact
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily
    @State private var hovering = false

    private var selected: Bool { model.selectedBrief == brief.id && model.article == nil && model.detail == nil }

    var body: some View {
        Button {
            model.article = nil
            model.selectedId = nil
            model.detail = nil
            model.selectedBrief = brief.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text([brief.viewName ?? (brief.viewId.flatMap { model.library.view($0)?.name }) ?? "All feeds", brief.createdAt.map { $0.formatted(.dateTime.hour().minute()) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(12)).foregroundStyle(p.muted)
                Text(brief.title).font(.custom(titleFamily, fixedSize: 18).weight(.medium))
                    .foregroundStyle(brief.id == model.library.briefs.first?.id ? p.unread : p.read).lineLimit(2)
                Text("From \(Plural.count(Int(max(brief.inputCount, Int64(brief.citations.count))), "article"))")
                    .font(.ui(13)).foregroundStyle(p.inkSoft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(selected ? p.selected : hovering ? p.selected.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The reader pane for Today: a recipe, an article from the sources, or the brief.
struct TodayReader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var brief: Artifact?
    @State private var loadError: String?

    private var selected: Artifact? { model.library.briefs.first { $0.id == model.selectedBrief } ?? model.library.briefs.first }

    var body: some View {
        Group {
            if model.article != nil || model.web != nil {
                ReaderPane().overlay(alignment: .topLeading) {
                    BackBar(title: "Brief") { model.back() }
                        .padding(.top, Metrics.barControlTop).padding(.leading, Metrics.barEdge)
                }
            } else {
                content
            }
        }
        .task(id: selected?.id) { await load() }
    }

    private func load() async {
        guard let id = selected?.id else {
            brief = nil
            return
        }
        do { brief = try await model.library.artifact("briefs.get", id) ?? selected }
        catch { brief = selected; loadError = AppModel.words(for: error) }
    }

    @ViewBuilder private var content: some View {
        let state = stateView
        if let state {
            ScrollView {
                state.padding(.horizontal, Metrics.pageGutter).padding(.top, 96).frame(maxWidth: Metrics.readingColumn + 2 * Metrics.pageGutter, alignment: .leading).frame(maxWidth: .infinity)
            }
            .overlay(alignment: .topTrailing) { toolbar }
        } else if let brief {
            ArtifactColumn(artifact: brief, open: openSource) {
                HStack(spacing: 8) {
                    GeneratedTag(text: "AI brief")
                    Text([brief.viewName ?? brief.viewId.flatMap { model.library.view($0)?.name } ?? "All feeds", brief.createdAt.map { Dates.long($0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.ui(13)).foregroundStyle(p.muted)
                }
                .padding(.bottom, 16)
                Text(brief.title).font(.custom(Fonts.resolve(Prefs.shared.currentFonts.title ?? Tokens.fontReading), fixedSize: 40).weight(.semibold))
                    .tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                MadeWith(artifact: brief, recipeName: model.library.recipe(brief.recipeId)?.name) {
                    model.openRecipe(brief.recipeId, from: brief.id)
                }
            }
            .overlay(alignment: .topTrailing) { toolbar }
        } else {
            Spinner(size: 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openSource(_ id: Int64) {
        Task { await model.open(id) }
    }

    /// Writing, failed and empty are said in place of the brief.
    private var stateView: InlineState? {
        if !model.library.available {
            return InlineState(tone: .empty, label: "Today", title: "Briefs need a newer Fyke service",
                               detail: "The background service running now does not write briefs. Your feeds and articles work as before.",
                               primary: ("Restart the service", { Task { let _: Ok? = try? await Daemon.shared.call("daemon.stop"); await model.start() } }))
        }
        if let job = model.briefJob, selected == nil || (job.createdAt ?? .distantPast) > (selected?.createdAt ?? .distantPast) {
            let seconds = Int(Date.now.timeIntervalSince(job.createdAt ?? .now))
            return InlineState(tone: .working, label: "Writing your brief",
                               title: "Reading your articles with the \(model.library.recipes.first?.name ?? "recipe") recipe",
                               detail: "\(job.writer?.capitalized ?? "The writer") · \(seconds) s so far, usually under a minute. Nothing changes in your articles while it writes; keep reading.",
                               primary: ("Cancel", { Task { await model.library.cancel(job.id) } }),
                               secondary: ("Read the articles instead", { model.go(to: .all) }))
        }
        if let job = model.failedBrief, (job.finishedAt ?? .distantPast) > (selected?.createdAt ?? .distantPast) {
            return InlineState(tone: .failed, label: "Brief not written",
                               title: "\(job.writer?.capitalized ?? "The writer") could not write the brief",
                               detail: "\(job.error ?? "It stopped before it finished.") Nothing was lost: your articles and earlier briefs are as they were.",
                               primary: ("Try again", { model.runBrief() }),
                               secondary: ("Choose a writer", { SettingsOpener.open(tab: .Agents, model: model) }))
        }
        if selected == nil {
            return InlineState(tone: .empty, label: "Today", title: "No brief yet",
                               detail: "A brief reads your newest unread articles and cites each one it uses. Opening Today never runs a writer; it writes when you ask.",
                               primary: ("Write a brief", { model.runBrief() }))
        }
        return nil
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            SymbolButton(symbol: "arrow.clockwise", label: "Write a new brief (⌘R)") { model.runBrief() }
                .disabled(model.briefJob != nil || !model.library.available)
            Button { model.openRecipe(selected?.recipeId, from: selected?.id) } label: {
                HStack(spacing: 4) { Image(systemName: "doc.text").font(.system(size: 12)); Text("Recipe") }
            }
            .buttonStyle(ActionStyle(kind: .secondary, height: Metrics.compactControl))
            .disabled(model.library.recipes.isEmpty)
        }
        .padding(.top, Metrics.barControlTop).padding(.trailing, Metrics.barEdge)
    }
}

/// "‹ Brief" at the top left of the reader, back to where the reader came from.
struct BackBar: View {
    let title: String
    var trailing: String?
    let run: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 8) {
            Button(action: run) {
                HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)); Text(title) }
                    .foregroundStyle(p.unread)
            }
            .buttonStyle(ActionStyle(kind: .quiet, height: Metrics.compactControl))
            .accessibilityLabel("Back to \(title)")
            if let trailing {
                Text("/").foregroundStyle(p.control)
                Text(trailing).font(.ui(13, .semibold))
            }
        }
        .font(.ui(13))
    }
}
