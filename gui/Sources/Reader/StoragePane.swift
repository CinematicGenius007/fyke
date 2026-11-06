import AppKit
import SwiftUI

private struct FreeParams: Encodable, Sendable {
    var trimOlderThanDays: Int64?
    var feedCopies = false
}

private struct RetentionParams: Encodable, Sendable { let removeReadAfterDays: Int64 }

private struct Segment: Identifiable {
    let label: String
    let bytes: Int64
    let color: Color
    var id: String { label }
}

private func size(_ bytes: Int64) -> String {
    bytes == 0 ? "0 KB" : bytes.formatted(.byteCount(style: .file))
}

/// What uses space, and how to get it back. Sizes come from the daemon, which is the
/// only process that may touch the database.
struct StoragePane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var use: StorageUse?
    @State private var checkedAt: Date?
    @State private var working = false
    @State private var open: Set<String> = ["articles"]
    @State private var confirming: String?

    private var settingsBytes: Int64 { (use?.logBytes ?? 0) + (use?.settingsBytes ?? 0) }
    private var total: Int64 { (use?.databaseBytes ?? 0) + (use?.rawBytes ?? 0) + settingsBytes }

    private var retention: Binding<Int64> {
        Binding {
            Prefs.shared.removeReadAfterDays
        } set: { days in
            Prefs.shared.removeReadAfterDays = days
            Task { let _: Ok? = try? await Daemon.shared.call("config.set", RetentionParams(removeReadAfterDays: days)) }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            PaneScroll {
                VStack(alignment: .leading, spacing: 0) {
                    PaneTitle(text: "Storage").padding(.bottom, -16)
                    HStack(spacing: 4) {
                        Text("Space rss_ uses in").font(.ui(13)).foregroundStyle(p.muted)
                        Text(Daemon.shared.home.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.code(13)).foregroundStyle(p.inkSoft)
                    }
                    .padding(.bottom, 18)
                    if let use { content(use) } else { Text("Measuring…").font(.ui(14)).foregroundStyle(p.muted) }
                }
                .padding(.bottom, 56)
            }
            footer
        }
        .task { await measure() }
    }

    @ViewBuilder private func content(_ use: StorageUse) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Disk space used").font(.ui(14))
                Text(checkedText).font(.ui(13)).foregroundStyle(p.muted)
            }
            Spacer()
            Text(size(total)).font(.ui(14, .semibold))
        }
        .padding(.bottom, 10)
        bar([
            Segment(label: "Articles and search", bytes: use.databaseBytes, color: p.ink),
            Segment(label: "Feed copies", bytes: use.rawBytes, color: p.unread),
            Segment(label: "Logs and settings", bytes: settingsBytes, color: p.control),
        ], height: 6, legendSquare: true)
        .padding(.bottom, 14)
        articles(use)
        copies(use)
        section("logs", title: "Logs and settings", bytes: settingsBytes, detail: "The log is replaced each time the service starts.", details: nil)
    }

    private func articles(_ use: StorageUse) -> some View {
        let a = use.articles
        let detail = "\(a.entries.formatted()) articles in \(a.feeds.formatted()) feeds."
            + (a.removable > 0 ? " \(a.removable.formatted()) were read over 90 days ago (\(size(a.removableBytes)))." : "")
        return section("articles", title: "Articles and search", bytes: use.databaseBytes, detail: detail) {
            AnyView(VStack(alignment: .leading, spacing: 8) {
                bar([
                    Segment(label: "Article text", bytes: a.textBytes, color: p.ink),
                    Segment(label: "Search index", bytes: a.searchBytes, color: p.inkSoft),
                    Segment(label: "Other", bytes: a.otherBytes, color: p.control),
                ], height: 4, legendSquare: false)
                HStack {
                    Button("Free up space…") { confirming = "articles" }.buttonStyle(Plain()).disabled(working)
                    Spacer()
                    Text("Remove read articles after").font(.ui(13)).foregroundStyle(p.muted)
                    SelectBox(selection: retention, options: [
                        SelectOption(value: 0, label: "Never"),
                        SelectOption(value: 30, label: "30 days"),
                        SelectOption(value: 90, label: "90 days"),
                        SelectOption(value: 365, label: "1 year"),
                    ])
                }
                if confirming == "articles" {
                    confirm("Removes the text of \(a.removable.formatted()) articles read over 90 days ago. Titles, links and starred articles stay.") {
                        await free(FreeParams(trimOlderThanDays: 90))
                    }
                }
            })
        }
    }

    private func copies(_ use: StorageUse) -> some View {
        section("copies", title: "Feed copies", bytes: use.rawBytes, detail: "Up to 20 per feed, kept so a parser fix can replay them.") {
            AnyView(VStack(alignment: .leading, spacing: 8) {
                Text("\(use.rawFiles.formatted()) copies").font(.ui(13)).foregroundStyle(p.muted)
                Button("Free up space…") { confirming = "copies" }.buttonStyle(Plain()).disabled(working)
                if confirming == "copies" {
                    confirm("Keeps the newest copy of each feed and removes the rest.") {
                        await free(FreeParams(feedCopies: true))
                    }
                }
            })
        }
    }

    private func confirm(_ text: String, run: @escaping () async -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.ui(13)).foregroundStyle(p.inkSoft).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel") { confirming = nil }.buttonStyle(Plain())
            Button("Free up space") {
                confirming = nil
                Task { await run() }
            }
            .buttonStyle(Solid())
        }
        .padding(10)
        .background(p.surface, in: RoundedRectangle(cornerRadius: Radii.control))
    }

    private func section(_ id: String, title: String, bytes: Int64, detail: String, details: (() -> AnyView)?) -> some View {
        let expanded = open.contains(id)
        let toggle = Binding(get: { expanded }, set: { on in
            if on { open.insert(id) } else { open.remove(id) }
        })
        return VStack(alignment: .leading, spacing: 6) {
            Rule().padding(.bottom, 6)
            HStack {
                Text(title).font(.ui(14))
                Spacer()
                Text(size(bytes)).font(.ui(14))
            }
            Text(detail).font(.ui(13)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            if let details {
                DetailsToggle(open: toggle)
                if expanded { details() }
            }
        }
        .padding(.bottom, 6)
    }

    private func bar(_ segments: [Segment], height: CGFloat, legendSquare: Bool) -> some View {
        let sum = max(segments.reduce(0) { $0 + $1.bytes }, 1)
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        Capsule().fill(segment.color)
                            .frame(width: max(2, (proxy.size.width - 4) * Double(segment.bytes) / Double(sum)))
                    }
                }
            }
            .frame(height: height)
            HStack(spacing: 18) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        if legendSquare { RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 9, height: 9) }
                        Text("\(segment.label)  \(size(segment.bytes))").font(.ui(13)).foregroundStyle(p.muted)
                    }
                }
            }
        }
    }

    private var checkedText: String {
        guard let checkedAt else { return " " }
        return Date.now.timeIntervalSince(checkedAt) < 60 ? "Checked just now" : "Checked " + checkedAt.formatted(.relative(presentation: .named))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 8) {
                Spacer()
                Button { NSWorkspace.shared.open(Daemon.shared.home) } label: {
                    HStack(spacing: 6) {
                        Icon(glyph: .folder)
                        Text("Open folder").font(.ui(14))
                    }
                    .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { Task { await measure() } } label: {
                    HStack(spacing: 6) {
                        Icon(glyph: .reload)
                        Text("Refresh").font(.ui(14))
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: Radii.control).stroke(p.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 40).padding(.vertical, 12)
            .background(p.ground)
        }
    }

    private func measure() async {
        do {
            use = try await Daemon.shared.callSlow("storage.get", NoParams())
            checkedAt = .now
        } catch {
            model.problem = error.localizedDescription
        }
    }

    private func free(_ params: FreeParams) async {
        working = true
        defer { working = false }
        do {
            let _: FreeResult = try await Daemon.shared.callSlow("storage.free", params)
            await measure()
        } catch {
            model.problem = error.localizedDescription
        }
    }
}
