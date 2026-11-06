import AppKit
import SwiftUI

struct SettingsView: View {
    enum Tab: String, CaseIterable { case General, Appearance, Tokens, Shortcuts, Storage, Agents }

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    private var tab: Tab { model.settingsTab }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button { model.settingsTab = item } label: {
                        Text(item.rawValue)
                            .font(.ui(14, tab == item ? .semibold : .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(tab == item ? p.selectedStrong : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
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
                case .Tokens: TokensPane()
                case .Shortcuts: ShortcutsPane()
                case .Storage: StoragePane()
                case .Agents: AgentsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .background(WindowButtons())
        .overlay { if let move = model.dataMove { MoveDialog(move: move) } }
    }
}

/// Holds a pane's content at the margins every pane shares, and scrolls it when it
/// is taller than the window.
struct PaneScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .themedScrollbar()
    }
}

struct PaneTitle: View {
    let text: String
    @Environment(\.titleFamily) private var family
    var body: some View {
        Text(text).font(.custom(family, fixedSize: 32).weight(.semibold)).tracking(-0.32).padding(.bottom, 20)
    }
}

struct Label2: View {
    let text: String
    @Environment(\.palette) private var p
    var body: some View {
        Text(text).font(.ui(11, .semibold)).tracking(0.66).foregroundStyle(p.muted)
    }
}

struct SettingRow<Control: View>: View {
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

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var background = LoginAgent.isInstalled

    private var settingsFile: URL { Daemon.shared.home.appending(path: "config.json") }
    private func tilde(_ url: URL) -> String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        @Bindable var prefs = Prefs.shared
        PaneScroll {
            VStack(alignment: .leading, spacing: 0) {
                PaneTitle(text: "General")
                SettingRow(title: "Check for new articles", detail: "Automatic follows how often each feed posts") {
                    Text("Automatic").font(.ui(14)).foregroundStyle(p.muted)
                }
                SettingRow(title: "Fetch full articles", detail: "Replaces short summaries, and respects each site's robots.txt") {
                    Switch(on: $prefs.fullText)
                }
                SettingRow(title: "Load images automatically", detail: "Off means publishers cannot see when you read") {
                    Switch(on: $prefs.ui.loadImages)
                }
                SettingRow(title: "Keep updating in the background", detail: "Starts when you log in, even with this window closed") {
                    Switch(on: $background)
                }
                SettingRow(title: "Your subscriptions", detail: "Import or export as OPML") {
                    HStack(spacing: 8) {
                        Button("Import OPML") { OPML.importFile(model) }.buttonStyle(Plain())
                        Button("Export") { OPML.export(model) }.buttonStyle(Plain())
                    }
                }
                SettingRow(title: "Open links", detail: "⌘-click always uses your browser") {
                    SelectBox(selection: $prefs.ui.openLinks, options: [
                        SelectOption(value: "app", label: "In the app"),
                        SelectOption(value: "browser", label: "In your browser"),
                    ])
                }
                SettingRow(title: "Settings file", detail: tilde(settingsFile)) {
                    Button("Open") { NSWorkspace.shared.open(settingsFile) }.buttonStyle(Plain())
                }
                SettingRow(title: "Data folder", detail: tilde(Daemon.shared.home.resolvingSymlinksInPath()), last: true) {
                    Button { model.chooseDataFolder() } label: {
                        HStack(spacing: 6) {
                            Icon(glyph: .folder)
                            Text("Change…")
                        }
                    }
                    .buttonStyle(Plain())
                    // RSS_HOME names the folder for this run, so there is no default to repoint.
                    .disabled(ProcessInfo.processInfo.environment["RSS_HOME"] != nil)
                }
                if let problem = prefs.fileProblem {
                    Text("config.json has a mistake, so the last good settings stay in use: \(problem)")
                        .font(.ui(13)).foregroundStyle(p.inkSoft).padding(.top, 12)
                }
            }
        }
        .onChange(of: prefs.fullText) { _, on in
            Task { let _: Ok? = try? await Daemon.shared.call("config.set", FullTextParams(fullText: on)) }
        }
        .onChange(of: background) { _, on in
            guard on != LoginAgent.isInstalled else { return }
            Task {
                do {
                    try await LoginAgent.set(on)
                } catch {
                    model.problem = error.localizedDescription
                }
                background = LoginAgent.isInstalled
            }
        }
    }
}

/// `rss service`, so polling continues after logging in with the app closed.
enum LoginAgent {
    private static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/local.rss_.daemon.plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func set(_ on: Bool) async throws {
        let program = Daemon.shared.programPath
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: program)
            process.arguments = ["service", on ? "install" : "uninstall"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RPCFailure(message: "Could not change the login item") }
        }.value
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
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @State private var newFrame = CGRect.zero

    private var themeOptions: [SelectOption<String>] {
        Prefs.shared.allThemes.map { SelectOption(value: $0, label: Prefs.shared.themeName($0)) }
    }

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 10)]

    var body: some View {
        @Bindable var prefs = Prefs.shared
        PaneScroll {
            VStack(alignment: .leading, spacing: 0) {
                PaneTitle(text: "Appearance").padding(.bottom, -4)
                Label2(text: "THEME").padding(.bottom, 10)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(prefs.allThemes, id: \.self) { tile($0) }
                    newTile
                }
                .padding(.bottom, 20)
                SettingRow(title: "Follow system appearance", detail: "Uses your day theme by day, your night theme at night") {
                    Switch(on: $prefs.ui.followSystem)
                }
                if prefs.ui.followSystem {
                    HStack(spacing: 24) {
                        pick("Day", $prefs.ui.dayTheme)
                        pick("Night", $prefs.ui.nightTheme)
                    }
                    .padding(.bottom, 14)
                }
                Rule()
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label2(text: "FONTS").padding(.bottom, 4)
                        fontRow("Reading", \.reading)
                        fontRow("Titles", \.title)
                        fontRow("App", \.ui)
                        fontRow("Code", \.code)
                        FontChangeStrip(short: false).padding(.top, 2)
                    }
                    .frame(width: 290)
                    VStack(alignment: .leading, spacing: 14) {
                        Label2(text: "TEXT")
                        Slider2(title: "Size", value: $prefs.ui.textSize, range: 14...28, step: 1, format: "%.0f")
                        Slider2(title: "Line spacing", value: $prefs.ui.lineSpacing, range: 1.2...2, step: 0.1, format: "%.1f")
                        Slider2(title: "Column width", value: $prefs.ui.columnWidth, range: 480...800, step: 20, format: "%.0f")
                    }
                }
                .padding(.vertical, 16)
                SettingRow(title: "Show scrollbars", detail: "Web pages keep their own", last: true) {
                    SelectBox(selection: $prefs.ui.scrollbars, options: [
                        SelectOption(value: "scrolling", label: "While scrolling"),
                        SelectOption(value: "always", label: "Always"),
                        SelectOption(value: "never", label: "Never"),
                    ])
                }
            }
        }
    }

    private func pick(_ label: String, _ selection: Binding<String>) -> some View {
        HStack {
            Text(label).font(.ui(14))
            Spacer()
            SelectBox(selection: selection, options: themeOptions, width: 190)
        }
    }

    private func fontRow(_ label: String, _ slot: WritableKeyPath<FontTokens, String?>) -> some View {
        HStack {
            Text(label).font(.ui(14))
            Spacer()
            FontField(slot: slot)
        }
    }

    private func tile(_ id: String) -> some View {
        let tile = Palette.resolved(id)
        let selected = p.id == id
        let family = Fonts.resolve(Prefs.shared.fonts(of: id).reading ?? Tokens.fontReading)
        return Button {
            Prefs.shared.ui.theme = id
            Prefs.shared.ui.followSystem = false
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Unread").foregroundStyle(tile.unread)
                    Text("Read").foregroundStyle(tile.read)
                }
                .font(.custom(family, fixedSize: id == "terminal" ? 13 : 15).weight(.medium))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 62)
                .background(tile.ground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? p.unread : p.hairline, lineWidth: selected ? 2 : 1))
                Text(Prefs.shared.themeName(id)).font(.ui(13, selected ? .semibold : .regular)).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var newTile: some View {
        Button {
            layer.show(at: newFrame) {
                NewThemePanel(start: Prefs.shared.activeTheme) { id in
                    Prefs.shared.editingTheme = id
                    model.settingsTab = .Tokens
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Icon(glyph: .plus)
                    .frame(maxWidth: .infinity).frame(height: 62)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.control, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                Text("New theme").font(.ui(13)).foregroundStyle(p.inkSoft).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .floatFrame($newFrame)
    }
}

/// Keys are fixed, so this list only shows them.
private struct ShortcutsPane: View {
    @Environment(\.palette) private var p

    var body: some View {
        PaneScroll {
            VStack(alignment: .leading, spacing: 0) {
                PaneTitle(text: "Shortcuts")
                HStack(alignment: .top, spacing: 40) {
                    column("MOVE", ShortcutList.move)
                    column("ACT", ShortcutList.act)
                }
                Text("Press ? anywhere to see this list. Keys shared with the terminal app work the same.")
                    .font(.ui(13)).foregroundStyle(p.muted).padding(.top, 20)
            }
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
                    Text(row.1).font(.code(13)).foregroundStyle(p.inkSoft)
                }
                .padding(.vertical, 7)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AgentsPane: View {
    @Environment(\.palette) private var p
    private var tier: String { Prefs.shared.ui.agentTier }

    private var snippet: String {
        let binary = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "rss").path
        let args = tier == "read" ? "[\"mcp\"]" : "[\"mcp\", \"--tier\", \"\(tier)\"]"
        return "{ \"mcpServers\": { \"rss\": {\n    \"command\": \"\(binary)\",\n    \"args\": \(args) } } }"
    }

    var body: some View {
        PaneScroll { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(text: "Agents")
            SettingRow(title: "What agents can do", detail: "Article text can try to mislead an agent, so start low") {
                HStack(spacing: 0) {
                    ForEach(["read", "annotate", "manage"], id: \.self) { item in
                        Button { Prefs.shared.ui.agentTier = item } label: {
                            Text(item.capitalized).font(.ui(14))
                                .foregroundStyle(tier == item ? p.ground : p.ink)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(tier == item ? p.ink : .clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radii.control))
                .overlay(RoundedRectangle(cornerRadius: Radii.control).stroke(p.control))
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
