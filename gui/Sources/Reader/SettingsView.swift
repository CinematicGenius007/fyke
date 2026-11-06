import AppKit
import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable { case General, Appearance, Shortcuts, Agents }

    @State private var tab = Tab(rawValue: ProcessInfo.processInfo.environment["RSS_TAB"] ?? "") ?? .General
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item.rawValue)
                            .font(.ui(14, tab == item ? .semibold : .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(tab == item ? p.selectedStrong : .clear, in: RoundedRectangle(cornerRadius: Tokens.radiusControl))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 48)
            .frame(width: 187)
            .background(p.surface)
            Rule(vertical: true)
            Group {
                switch tab {
                case .General: GeneralPane()
                case .Appearance: AppearancePane()
                case .Shortcuts: ShortcutsPane()
                case .Agents: AgentsPane()
                }
            }
            .padding(.horizontal, 40).padding(.top, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
    }
}

private struct PaneTitle: View {
    let text: String
    @Environment(\.readingFamily) private var family
    var body: some View {
        Text(text).font(.custom(family, fixedSize: 32).weight(.semibold)).tracking(-0.32).padding(.bottom, 20)
    }
}

private struct Label2: View {
    let text: String
    @Environment(\.palette) private var p
    var body: some View {
        Text(text).font(.ui(11, .semibold)).tracking(0.66).foregroundStyle(p.muted)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    var last = false
    @ViewBuilder var control: Control
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            Rule()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(14))
                    Text(detail).font(.ui(13)).foregroundStyle(p.muted)
                }
                Spacer(minLength: 16)
                control
            }
            .padding(.vertical, 14)
            if last { Rule() }
        }
    }
}

struct Switch: View {
    @Binding var on: Bool
    @Environment(\.palette) private var p

    var body: some View {
        Button { on.toggle() } label: {
            Capsule().fill(on ? p.unread : p.control)
                .frame(width: 36, height: 22)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(p.onAccent).frame(width: 18, height: 18).padding(2)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct FullTextParams: Encodable, Sendable { let fullText: Bool }
private struct Config: Decodable, Sendable { let fullText: Bool }

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @AppStorage(Keys.loadImages) private var loadImages = false
    @State private var fullText = true
    @State private var background = LoginAgent.isInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(text: "General")
            SettingRow(title: "Check for new articles", detail: "Automatic follows how often each feed posts") {
                Text("Automatic").font(.ui(14)).foregroundStyle(p.muted)
            }
            SettingRow(title: "Fetch full articles", detail: "Replaces short summaries, and respects each site's robots.txt") {
                Switch(on: $fullText)
            }
            SettingRow(title: "Load images automatically", detail: "Off means publishers cannot see when you read") {
                Switch(on: $loadImages)
            }
            SettingRow(title: "Keep updating in the background", detail: "Starts when you log in, even with this window closed") {
                Switch(on: $background)
            }
            SettingRow(title: "Your subscriptions", detail: "Stored in " + Daemon.shared.home.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), last: true) {
                HStack(spacing: 8) {
                    Button("Import OPML") { OPML.importFile(model) }.buttonStyle(Plain())
                    Button("Export") { OPML.export(model) }.buttonStyle(Plain())
                }
            }
        }
        .task {
            if let config: Config = try? await Daemon.shared.call("config.get") { fullText = config.fullText }
        }
        .onChange(of: fullText) { _, on in
            Task { let _: Ok? = try? await Daemon.shared.call("config.set", FullTextParams(fullText: on)) }
        }
        .onChange(of: background) { _, on in LoginAgent.set(on) }
    }
}

/// A launchd agent, so polling continues after logging in with the app closed.
enum LoginAgent {
    private static let label = "local.rss_.daemon"
    private static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func set(_ on: Bool) {
        guard on else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let binary = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "rss").path
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [binary, "daemon"], "RunAtLoad": true]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
    }
}

private struct Slider2: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.ui(14))
                Spacer()
                Text(String(format: format, value)).font(.ui(14)).foregroundStyle(p.muted)
            }
            GeometryReader { geometry in
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = fraction * (geometry.size.width - 16)
                ZStack(alignment: .leading) {
                    Capsule().fill(p.hairline).frame(height: 4)
                    Capsule().fill(p.ink).frame(width: x + 8, height: 4)
                    Circle().fill(p.ground).overlay(Circle().stroke(p.muted)).frame(width: 16, height: 16).offset(x: x)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let raw = range.lowerBound + (drag.location.x - 8) / (geometry.size.width - 16) * (range.upperBound - range.lowerBound)
                    value = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
                })
            }
            .frame(height: 16)
        }
    }
}

private struct AppearancePane: View {
    @Environment(\.palette) private var p
    @AppStorage(Keys.theme) private var theme = "light"
    @AppStorage(Keys.followSystem) private var followSystem = true
    @AppStorage(Keys.readingFont) private var readingFont = Tokens.fontReading
    @AppStorage(Keys.textSize) private var textSize = 19.0
    @AppStorage(Keys.lineSpacing) private var spacing = 1.6
    @AppStorage(Keys.columnWidth) private var columnWidth = 640.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(text: "Appearance").padding(.bottom, 4)
            Label2(text: "THEME").padding(.bottom, 10)
            HStack(spacing: 12) {
                ForEach(["light", "dark", "newsprint", "terminal"], id: \.self) { tile($0) }
            }
            .padding(.bottom, 28)
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 2) {
                    Label2(text: "READING FONT").padding(.bottom, 8)
                    ForEach(Fonts.choices, id: \.self) { family in
                        Button { readingFont = family } label: {
                            HStack {
                                Text(Fonts.label(family)).font(.custom(Fonts.resolve(family), fixedSize: 16))
                                Spacer()
                                if readingFont == family { Text("✓").font(.ui(13, .semibold)).foregroundStyle(p.unread) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(readingFont == family ? p.selected : .clear, in: RoundedRectangle(cornerRadius: Tokens.radiusControl))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Any installed font…", action: chooseFont)
                        .buttonStyle(.plain).font(.ui(14)).foregroundStyle(p.inkSoft)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .frame(width: 250)
                VStack(alignment: .leading, spacing: 14) {
                    Label2(text: "TEXT")
                    Slider2(title: "Size", value: $textSize, range: 14...28, step: 1, format: "%.0f")
                    Slider2(title: "Line spacing", value: $spacing, range: 1.2...2, step: 0.1, format: "%.1f")
                    Slider2(title: "Column width", value: $columnWidth, range: 480...800, step: 20, format: "%.0f")
                }
            }
            .padding(.bottom, 20)
            SettingRow(title: "Follow system appearance", detail: "Light by day, Dark at night") {
                Switch(on: $followSystem)
            }
        }
    }

    private func tile(_ id: String) -> some View {
        let tile = Palette.named(id)
        let selected = p.id == id
        return Button { theme = id; followSystem = false } label: {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unread").foregroundStyle(tile.unread)
                    Text("Read").foregroundStyle(tile.read)
                }
                .font(id == "terminal" ? .code(14) : .custom(Fonts.resolve(readingFont), fixedSize: 16).weight(.medium))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 76)
                .background(tile.ground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? p.unread : p.hairline, lineWidth: selected ? 2 : 1))
                Text(id.capitalized).font(.ui(13, selected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }

    private func chooseFont() {
        let alert = NSAlert()
        alert.messageText = "Reading font"
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        menu.addItems(withTitles: NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") })
        menu.selectItem(withTitle: readingFont)
        alert.accessoryView = menu
        alert.addButton(withTitle: "Use Font")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let family = menu.titleOfSelectedItem { readingFont = family }
    }
}

/// Fixed for now. Rebinding keys is not built, so this list does not offer it.
private struct ShortcutsPane: View {
    @Environment(\.palette) private var p
    private let move = [("Next, previous", "j  k"), ("Open", "Return"), ("Back", "Esc"), ("Next unread", "n"), ("Search", "/"), ("Briefing", "⌘1"), ("All", "⌘2"), ("Starred", "⌘3")]
    private let act = [("Star", "s"), ("Read or unread", "m"), ("Unread only", "u"), ("Open page", "o"), ("Fetch full article", "f"), ("Refresh", "r"), ("Add feed", "a"), ("Text and theme", "t")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(text: "Shortcuts")
            HStack(alignment: .top, spacing: 40) {
                column("MOVE", move)
                column("ACT", act)
            }
            Text("Press ? anywhere to see this list. Keys shared with the terminal app work the same.")
                .font(.ui(13)).foregroundStyle(p.muted).padding(.top, 20)
        }
    }

    private func column(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label2(text: title).padding(.bottom, 8)
            ForEach(rows, id: \.0) { row in
                Rule()
                HStack {
                    Text(row.0).font(.ui(14))
                    Spacer()
                    Text(row.1).font(.code(13))
                }
                .padding(.vertical, 7)
            }
        }
    }
}

private struct AgentsPane: View {
    @Environment(\.palette) private var p
    @AppStorage("agentTier") private var tier = "read"

    private var snippet: String {
        let binary = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "rss").path
        let args = tier == "read" ? "[\"mcp\"]" : "[\"mcp\", \"--tier\", \"\(tier)\"]"
        return "{ \"mcpServers\": { \"rss\": {\n    \"command\": \"\(binary)\",\n    \"args\": \(args) } } }"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(text: "Agents")
            SettingRow(title: "What agents can do", detail: "Article text can try to mislead an agent, so start low") {
                HStack(spacing: 0) {
                    ForEach(["read", "annotate", "manage"], id: \.self) { item in
                        Button { tier = item } label: {
                            Text(item.capitalized).font(.ui(14))
                                .foregroundStyle(tier == item ? p.ground : p.ink)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(tier == item ? p.ink : .clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl))
                .overlay(RoundedRectangle(cornerRadius: Tokens.radiusControl).stroke(p.control))
            }
            VStack(alignment: .leading, spacing: 10) {
                Rule()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect an agent").font(.ui(14))
                        Text("Add this to Claude Code, Codex or any MCP client").font(.ui(13)).foregroundStyle(p.muted)
                    }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                    }
                    .buttonStyle(Plain())
                }
                .padding(.top, 4)
                Text(snippet).font(.code(13)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
            }
            SettingRow(title: "Briefing is written by", detail: "Arrives with the aggregator", last: true) {
                Text("Not set up").font(.ui(14)).foregroundStyle(p.muted)
            }
        }
    }
}
