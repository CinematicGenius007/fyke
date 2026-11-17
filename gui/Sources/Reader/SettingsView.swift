import AppKit
import SwiftUI

/// Settings, as a destination of the main window: it fills the list and reader panes
/// while the sidebar stays, so the reader is one Esc away. The header names it and holds
/// the tabs; each tab's rows sit in the reading column below. Tokens has no tab of its
/// own; it opens from Reading, which stays selected while it shows.
struct SettingsView: View {
    enum Tab: String, CaseIterable { case General, Reading, Tokens, Agents, Data }
    /// The tabs in the header, in order.
    static let bar: [Tab] = [.General, .Reading, .Agents, .Data]

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    private var tab: Tab { model.settingsTab }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            Group {
                switch tab {
                case .General: GeneralPane()
                case .Reading: ReadingPane()
                case .Tokens: TokensPane()
                case .Agents: AgentsPane()
                case .Data: StoragePane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(p.ground)
        .overlay { if let move = model.dataMove { MoveDialog(move: move) } }
    }

    /// The title and the tabs, on the reading column's edges, at the height of the list
    /// pane's header so the two line up across a switch.
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(tab == .Tokens ? "Theme tokens" : "Settings").font(.ui(20, .semibold)).tracking(-0.2).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 16)
            Tabs(selection: Binding(get: { tab == .Tokens ? .Reading : tab }, set: { model.settingsTab = $0 }),
                 items: Self.bar.map { ($0, $0.rawValue) })
            SymbolButton(symbol: "xmark", label: "Close Settings (Esc)") { model.showingSettings = false }
        }
        .settingsColumn()
        .padding(.top, Metrics.barHeight).padding(.bottom, 16)
    }
}

extension View {
    /// Sets Settings content in the reading column, centered in the space it has, with
    /// the page gutter on both sides when that space is narrow.
    func settingsColumn() -> some View {
        frame(maxWidth: Metrics.readingColumn, alignment: .leading)
            .padding(.horizontal, Metrics.pageGutter)
            .frame(maxWidth: .infinity)
    }
}

/// Holds a pane's sections in the reading column, and scrolls them when they are taller
/// than the window.
struct PaneScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) { content }
                .settingsColumn()
                .padding(.top, 32).padding(.bottom, Metrics.pageGutter)
        }
        .themedScrollbar()
    }
}

/// A group of settings: a caps label, a muted line saying what the group is for when it
/// needs one, then its rows on the ground color with a hairline between each. There is
/// no box around a group; the label and the rules are enough to hold it together.
struct SettingsSection<Content: View>: View {
    let title: String
    var detail: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                SectionLabel(text: title)
                Spacer(minLength: 16)
                if let trailing { trailing }
            }
            .frame(minHeight: 20)
            if let detail {
                Text(detail).font(.ui(13)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Rule().padding(.top, 8)
            VStack(alignment: .leading, spacing: 0) { content }
        }
    }
}

/// A row in a section: the title on the left and its control on the right, 48 high,
/// with a muted line under the title only when the title alone would not say enough.
/// Every row but the last draws the hairline under itself.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var last = false
    @ViewBuilder var control: Control
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(14)).foregroundStyle(p.ink)
                    if let detail {
                        Text(detail).font(.ui(12)).foregroundStyle(p.muted).lineLimit(2).truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                control
            }
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            if !last { Rule() }
        }
    }
}

struct Switch: View {
    @Binding var on: Bool
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    private var track: Color {
        if on { return hovering && enabled ? p.unread.mix(with: .black, by: 0.08) : p.unread }
        return hovering && enabled ? p.muted : p.control
    }

    var body: some View {
        Button { on.toggle() } label: {
            Capsule().fill(track)
                .frame(width: 28, height: 16)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(p.onAccent).frame(width: 12, height: 12).padding(2)
                }
                .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.bare)
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
        .motion(on, Motion.quick)
        .accessibilityValue(on ? "On" : "Off")
    }
}

private struct FullTextParams: Encodable, Sendable { let fullText: Bool }

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var background = LoginAgent.isInstalled

    var body: some View {
        @Bindable var prefs = Prefs.shared
        PaneScroll {
            SettingsSection(title: "Updates") {
                SettingRow(title: "Check for new articles", detail: "Automatic follows how often each feed posts") {
                    Text("Automatic").font(.ui(13)).foregroundStyle(p.muted)
                }
                SettingRow(title: "Fetch full articles", detail: "Replaces short summaries, and respects each site's robots.txt") {
                    Switch(on: $prefs.fullText)
                }
                SettingRow(title: "Keep updating in the background", detail: "Starts when you log in, even with this window closed", last: true) {
                    Switch(on: $background)
                }
            }
            SettingsSection(title: "Privacy", detail: "What publishers can learn from your reading.") {
                SettingRow(title: "Load images automatically", detail: "Off means publishers cannot see when you read") {
                    Switch(on: $prefs.ui.loadImages)
                }
                SettingRow(title: "Open links", detail: "⌘-click always uses your browser", last: true) {
                    SelectBox(selection: $prefs.ui.openLinks, options: [
                        SelectOption(value: "app", label: "In the app"),
                        SelectOption(value: "browser", label: "In your browser"),
                    ], width: 160, height: Metrics.control)
                }
            }
            SettingsSection(title: "Subscriptions and keys") {
                SettingRow(title: "Your subscriptions", detail: "Import or export as OPML") {
                    HStack(spacing: 8) {
                        Button("Import OPML") { OPML.importFile(model) }.buttonStyle(ActionStyle(kind: .secondary))
                        Button("Export") { OPML.export(model) }.buttonStyle(ActionStyle(kind: .secondary))
                    }
                }
                SettingRow(title: "Keyboard shortcuts", detail: "Press ? anywhere in the reader to see them", last: true) {
                    Button("Show") { model.showingShortcuts = true }.buttonStyle(ActionStyle(kind: .secondary))
                }
            }
            if let problem = prefs.fileProblem {
                Text("config.json has a mistake, so the last good settings stay in use: \(problem)")
                    .font(.ui(12)).foregroundStyle(p.inkSoft).fixedSize(horizontal: false, vertical: true)
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

/// `fyke service`, so polling continues after logging in with the app closed.
enum LoginAgent {
    private static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/local.fyke.daemon.plist")
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

/// A slider row: the title, a track, and the value in code type.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var last = false
    @Environment(\.palette) private var p

    var body: some View {
        SettingRow(title: title, last: last) {
            HStack(spacing: 12) {
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
                    .interactiveCursor()
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        let raw = range.lowerBound + (drag.location.x - 8) / (geometry.size.width - 16) * (range.upperBound - range.lowerBound)
                        value = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
                    })
                }
                .frame(width: 200, height: 16)
                Text(String(format: format, value)).font(.code(12)).foregroundStyle(p.muted).frame(width: 32, alignment: .trailing)
            }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue(String(format: format, value))
            .accessibilityAdjustableAction { direction in
                let next = direction == .increment ? value + step : value - step
                value = min(max(next, range.lowerBound), range.upperBound)
            }
        }
    }
}

/// Themes, fonts and the shape of the reading column.
private struct ReadingPane: View {
    @Environment(AppModel.self) private var model
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @State private var newFrame = CGRect.zero

    private var themeOptions: [SelectOption<String>] {
        Prefs.shared.allThemes.map { SelectOption(value: $0, label: Prefs.shared.themeName($0)) }
    }

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 12)]

    var body: some View {
        @Bindable var prefs = Prefs.shared
        PaneScroll {
            SettingsSection(title: "Theme", detail: "Colors for the whole app. Blue marks unread, purple marks read.") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(prefs.allThemes, id: \.self) { tile($0) }
                    newTile
                }
                .padding(.top, 16)
            }
            SettingsSection(title: "Day and night") {
                SettingRow(title: "Follow system appearance", detail: "Uses your day theme by day, your night theme at night", last: !prefs.ui.followSystem) {
                    Switch(on: $prefs.ui.followSystem)
                }
                if prefs.ui.followSystem {
                    SettingRow(title: "Day") { SelectBox(selection: $prefs.ui.dayTheme, options: themeOptions, width: 180, height: Metrics.control) }
                    SettingRow(title: "Night", last: true) { SelectBox(selection: $prefs.ui.nightTheme, options: themeOptions, width: 180, height: Metrics.control) }
                }
            }
            SettingsSection(title: "Fonts", detail: "Each theme keeps its own. A change here applies to the theme in use.") {
                fontRow("Reading", \.reading)
                fontRow("Titles", \.title)
                fontRow("App", \.ui)
                fontRow("Code", \.code)
                SettingRow(title: "Colors, fonts and corners", detail: "Every token of every theme", last: true) {
                    Button("Edit Tokens…") { model.settingsTab = .Tokens }.buttonStyle(ActionStyle(kind: .secondary))
                }
            }
            FontChangeStrip(short: false)
            SettingsSection(title: "Text") {
                SliderRow(title: "Size", value: $prefs.ui.textSize, range: 14...28, step: 1, format: "%.0f")
                SliderRow(title: "Line spacing", value: $prefs.ui.lineSpacing, range: 1.2...2, step: 0.1, format: "%.1f")
                SliderRow(title: "Column width", value: $prefs.ui.columnWidth, range: 480...800, step: 20, format: "%.0f")
                SettingRow(title: "Show scrollbars", detail: "Web pages keep their own", last: true) {
                    SelectBox(selection: $prefs.ui.scrollbars, options: [
                        SelectOption(value: "scrolling", label: "While scrolling"),
                        SelectOption(value: "always", label: "Always"),
                        SelectOption(value: "never", label: "Never"),
                    ], width: 160, height: Metrics.control)
                }
            }
        }
    }

    private func fontRow(_ label: String, _ slot: WritableKeyPath<FontTokens, String?>) -> some View {
        SettingRow(title: label) { FontField(slot: slot) }
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
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 60)
                .background(tile.ground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? p.unread : p.hairline, lineWidth: selected ? 2 : 1))
                Text(Prefs.shared.themeName(id)).font(.ui(12, selected ? .semibold : .regular)).foregroundStyle(selected ? p.ink : p.inkSoft).lineLimit(1)
            }
        }
        .buttonStyle(.bare)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.control, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                Text("New theme").font(.ui(12)).foregroundStyle(p.inkSoft).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bare)
        .floatFrame($newFrame)
    }
}

/// The way back from Tokens to the tab it opened from.
struct BackToReading: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.settingsTab = .Reading } label: {
            HStack(spacing: 4) {
                Icon(glyph: .left, size: 14)
                Text("Reading")
            }
        }
        .buttonStyle(ActionStyle(kind: .quiet))
        .padding(.leading, -10)
    }
}

/// Who writes briefs, and what agents connected over MCP may do.
private struct AgentsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var checking: String?
    @State private var problem: String?
    @State private var copied = false
    private var tier: String { Prefs.shared.ui.agentTier }

    private var snippet: String {
        let binary = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "fyke").path
        let args = tier == "read" ? "[\"mcp\"]" : "[\"mcp\", \"--tier\", \"\(tier)\"]"
        return "{ \"mcpServers\": { \"rss\": {\n    \"command\": \"\(binary)\",\n    \"args\": \(args) } } }"
    }

    var body: some View {
        PaneScroll { content }
            .task { await model.library.loadWriters() }
    }

    @ViewBuilder private var content: some View {
        SettingsSection(title: "Who writes your briefs",
                        detail: "Fyke hands the selected articles and your recipe to an agent already on this Mac. Fyke itself sends nothing anywhere else.") {
            if model.library.writers.isEmpty {
                Text(model.library.available ? "Looking for Codex and Claude Code…" : "Writers need a newer Fyke service. Quit and open Fyke again.")
                    .font(.ui(13)).foregroundStyle(p.muted).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.library.writers.enumerated()), id: \.element.id) { index, writer in
                if index > 0 { Rule() }
                writerRow(writer)
            }
        }
        if let problem { Text(problem).font(.ui(12)).foregroundStyle(p.ink).padding(.top, -32) }
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection(title: "Let agents use Fyke",
                            detail: "Agents connected over MCP can search and read your articles. Article text can try to mislead an agent, so changes start off.") {
                SettingRow(title: "Read articles, views and briefs") {
                    Text("Always on").font(.ui(13)).foregroundStyle(p.muted)
                }
                SettingRow(title: "Make changes", detail: "Mark read and star; or also edit views, recipes and routines", last: true) {
                    SelectBox(selection: Binding(get: { tier }, set: { Prefs.shared.ui.agentTier = $0 }), options: [
                        SelectOption(value: "read", label: "Never"),
                        SelectOption(value: "annotate", label: "Reading state only"),
                        SelectOption(value: "manage", label: "Everything"),
                    ], width: 180, height: Metrics.control)
                    .accessibilityLabel("What agents may change")
                }
            }
            HStack {
                Text("Add Fyke to another agent with this configuration.").font(.ui(12)).foregroundStyle(p.muted)
                Spacer()
                Button(copied ? "Copied" : "Copy MCP config") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .buttonStyle(ActionStyle(kind: .secondary))
            }
            .padding(.top, 4)
            Text(snippet).font(.code(12)).lineSpacing(3).textSelection(.enabled)
                .foregroundStyle(p.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12).padding(.horizontal, 16)
                .background(p.surface, in: RoundedRectangle(cornerRadius: Radii.control))
        }
    }

    private func writerRow(_ writer: Writer) -> some View {
        HStack(spacing: 12) {
            Text(writer.id == "codex" ? "Cx" : String(writer.name.prefix(1)))
                .font(.ui(12, .semibold)).foregroundStyle(p.ground)
                .frame(width: Metrics.compactControl, height: Metrics.compactControl)
                .background(writer.found ? (writer.selected ? p.ink : p.inkSoft) : p.control, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 0) {
                Text(writer.name).font(.ui(13, .medium))
                Text(status(writer)).font(.ui(12)).foregroundStyle(writer.problem != nil ? p.ink : p.muted).lineLimit(2)
            }
            Spacer()
            if checking == writer.id {
                Spinner(size: 12)
            } else {
                Button("Check") { check(writer) }.buttonStyle(ActionStyle(kind: .quiet))
                    .help("Run \(writer.name)'s version check again")
            }
            if writer.selected {
                Text("Default").font(.ui(11)).foregroundStyle(p.muted).padding(.horizontal, 8).frame(height: 22)
                    .background(p.selected, in: RoundedRectangle(cornerRadius: Radii.control))
            } else {
                Button("Make default") { choose(writer) }.buttonStyle(ActionStyle(kind: .secondary))
                    .disabled(!writer.found)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
    }

    private func status(_ writer: Writer) -> String {
        if let problem = writer.problem { return problem }
        guard writer.found else { return "Not found on this Mac" }
        let path = writer.path.map { " · found at " + $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? ""
        return "Ready" + (writer.version.map { " · \($0)" } ?? "") + path
    }

    private func check(_ writer: Writer) {
        checking = writer.id
        problem = nil
        Task {
            do { try await model.library.check(writer.id) } catch { problem = AppModel.words(for: error) }
            checking = nil
        }
    }

    private func choose(_ writer: Writer) {
        problem = nil
        Task {
            do { try await model.library.choose(writer.id) } catch { problem = "Could not make \(writer.name) the default: \(AppModel.words(for: error))" }
        }
    }
}
