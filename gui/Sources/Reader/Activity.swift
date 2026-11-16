// One place for background work: a line at the foot of the sidebar, and the Activity
// popover it opens. It speaks up only when something needs a person.
import ReaderLogic
import SwiftUI

extension AppModel {
    /// The status line's words, most urgent first.
    var statusWords: String {
        if let job = library.activeJobs.first {
            let more = library.activeJobs.count - 1
            return job.title + (job.total.map { t in job.progress.map { " \($0) of \(t)" } ?? "" } ?? "…") + (more > 0 ? " · \(more) more" : "")
        }
        let attention = library.needsYou.count + (failingFeeds.isEmpty ? 0 : 1)
        if attention > 0 { return attention == 1 ? "1 thing needs you" : "\(attention) things need you" }
        guard let date = updatedAt else { return " " }
        return "Updated " + date.formatted(.relative(presentation: .named))
    }

    var statusIsBusy: Bool { !library.activeJobs.isEmpty }
    var statusNeedsYou: Bool { !library.needsYou.isEmpty || !failingFeeds.isEmpty }
}

struct ActivityPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p

    private var earlier: [Job] {
        let start = Calendar.current.startOfDay(for: .now)
        return model.library.jobs.filter { !$0.isActive && ($0.finishedAt ?? $0.createdAt ?? .distantPast) >= start && !model.library.needsYou.contains($0) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.ui(14, .semibold))
                Spacer()
                Button("Refresh feeds") { model.refresh() }.buttonStyle(ActionStyle(kind: .quiet, height: Metrics.compactControl))
            }
            .padding(.leading, Metrics.panelEdge).padding(.trailing, 8).frame(height: Metrics.panelHeader)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    group("Now") {
                        if model.library.activeJobs.isEmpty {
                            line("Nothing running. Feeds refresh on their own.")
                        }
                        ForEach(model.library.activeJobs) { job in running(job) }
                    }
                    if !model.library.needsYou.isEmpty || !model.failingFeeds.isEmpty {
                        group("Needs you") {
                            ForEach(model.library.needsYou) { job in failed(job) }
                            if !model.failingFeeds.isEmpty { feeds }
                        }
                    }
                    if !earlier.isEmpty {
                        group("Earlier today") {
                            ForEach(earlier) { job in done(job) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .themedScrollbar()
            .frame(maxHeight: 420)
            Rule()
            HStack {
                Button("Routines") {
                    layer.close()
                    model.go(to: .routines)
                }
                .buttonStyle(ActionStyle(kind: .link, height: Metrics.compactControl))
                Spacer()
                if let next = model.library.nextRoutine, let at = next.nextRunAt {
                    Text("Next: \(next.name), \(at.formatted(.dateTime.hour().minute()))").font(.ui(12)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            .padding(.leading, 8).padding(.trailing, Metrics.panelEdge).frame(height: Metrics.panelHeader)
        }
        .frame(width: 360)
        .popoverPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity")
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: title).padding(.horizontal, Metrics.panelEdge).padding(.top, 12).padding(.bottom, 4)
            content()
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.ui(13)).foregroundStyle(p.muted).padding(.horizontal, Metrics.panelEdge).padding(.vertical, 4)
    }

    private func running(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Spinner(size: 12)
                Text(model.library.describe(job)).font(.ui(13)).lineLimit(1)
                Spacer()
                Text([job.writer?.capitalized, job.createdAt.map { "\(Int(Date.now.timeIntervalSince($0))) s" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(12)).foregroundStyle(p.muted)
                SymbolButton(symbol: "xmark", label: "Cancel \(job.title.lowercased())", size: 24) { Task { await model.library.cancel(job.id) } }
            }
            if let total = job.total, total > 0 {
                ProgressLine(fraction: Double(job.progress ?? 0) / Double(total)).padding(.leading, 20)
            }
        }
        .padding(.leading, Metrics.panelEdge).padding(.trailing, 12).padding(.vertical, 4)
    }

    /// What failed, what is safe, and the one thing to do.
    private func failed(_ job: Job) -> some View {
        let writerProblem = job.isWriting && (job.error ?? "").localizedCaseInsensitiveContains("sign")
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(p.unread).frame(width: Metrics.dot, height: Metrics.dot).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.library.describe(job)) did not finish").font(.ui(13, .medium))
                Text("\(job.error ?? "It stopped.") Your articles are untouched.").font(.ui(12)).foregroundStyle(p.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(writerProblem ? "Writers" : "Try again") {
                layer.close()
                if writerProblem { SettingsOpener.open(tab: .Agents, model: model) } else if job.isWriting { model.runBrief() } else { model.refresh() }
            }
            .buttonStyle(ActionStyle(kind: .inverse, height: Metrics.compactControl))
        }
        .padding(12)
        .background(p.selected, in: RoundedRectangle(cornerRadius: Radii.control))
        .padding(.horizontal, 8)
    }

    private var feeds: some View {
        let failing = model.failingFeeds
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(p.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text(failing.count == 1 ? "\(failing[0].name) is not loading" : "\(failing.count) feeds are not loading").font(.ui(13, .medium))
                Text("Their articles so far are kept. Fyke keeps trying on its own.").font(.ui(12)).foregroundStyle(p.inkSoft)
            }
            Spacer(minLength: 8)
            Button("Show") {
                layer.close()
                model.healthFeed = failing[0].id
            }
            .buttonStyle(ActionStyle(kind: .secondary, height: Metrics.compactControl))
        }
        .padding(12)
        .padding(.horizontal, 8)
    }

    private func done(_ job: Job) -> some View {
        HStack(spacing: 8) {
            Image(systemName: job.state == .done ? "checkmark" : job.state == .cancelled ? "minus" : "exclamationmark")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(job.state == .done ? p.inkSoft : p.muted).frame(width: 12)
            Text(model.library.describe(job) + (job.state == .cancelled ? " · cancelled" : "")).font(.ui(13)).lineLimit(1)
            Spacer()
            Text((job.finishedAt ?? job.createdAt).map { $0.formatted(.dateTime.hour().minute()) } ?? "").font(.ui(12)).foregroundStyle(p.muted)
        }
        .padding(.horizontal, Metrics.panelEdge).frame(height: Metrics.panelRow)
    }
}

/// A failing feed, with what happened, what is kept, and the one next action.
struct FeedHealthPanel: View {
    let feed: Feed
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(feed.isFailing ? "\(feed.name) is not loading" : feed.name).font(.ui(14, .semibold))
                Text(feed.errorCount == 0 ? "Its last fetch worked. Its \(Plural.count(Int(feed.entries), "article")) are here." : "It failed \(Plural.count(Int(feed.errorCount), "time")) in a row. Its \(Plural.count(Int(feed.entries), "article")) are kept, and Fyke keeps trying on its own.")
                    .font(.ui(13)).foregroundStyle(p.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metrics.panelEdge)
            if let error = feed.lastError {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Error").font(.ui(12)).foregroundStyle(p.muted)
                    Text(error).font(.code(12)).foregroundStyle(p.ink).lineLimit(3).textSelection(.enabled)
                }
                .padding(.horizontal, Metrics.panelEdge).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.surface)
            }
            HStack(spacing: 8) {
                if let site = feed.siteUrl, let url = URL(string: site) {
                    Button("Open site") {
                        layer.close()
                        model.openLink(url)
                    }
                    .buttonStyle(ActionStyle(kind: .quiet, height: Metrics.compactControl))
                }
                Spacer()
                Button(feed.isFailing ? "Try again now" : "Refresh now") {
                    layer.close()
                    model.refreshFeed(feed.id)
                }
                .buttonStyle(ActionStyle(kind: .primary, height: Metrics.compactControl))
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 380)
        .popoverPanel()
        .accessibilityElement(children: .contain)
    }
}
