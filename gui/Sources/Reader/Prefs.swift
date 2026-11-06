// Every setting the app has lives under `ui` in config.json. The owner can edit that
// file by hand, so it is the only copy: the daemon writes it, and this object follows.
import AppKit
import Foundation
import Observation

/// One theme's colors. A value here replaces the same token from Tokens.swift.
struct ThemeTokens: Codable, Equatable, Sendable {
    var ground, surface, selected, selectedStrong, hairline, control: String?
    var ink, inkSoft, muted, unread, read, onAccent, scrim: String?
}

struct FontTokens: Codable, Equatable, Sendable {
    var reading, title, ui, code: String?

    var isEmpty: Bool { self == FontTokens() }
}

struct RadiusTokens: Codable, Equatable, Sendable {
    var control, panel, sheet: Double?
}

/// A theme the user made. `base` is always a built-in, and supplies whatever the
/// theme leaves out, so a reset goes back to it.
struct CustomTheme: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var base = "light"
    var tokens = ThemeTokens()
    var fonts = FontTokens()
    var radii = RadiusTokens()

    init(id: String, name: String, base: String) {
        self.id = id
        self.name = name
        self.base = base
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        base = try c.decodeIfPresent(String.self, forKey: .base) ?? "light"
        tokens = try c.decodeIfPresent(ThemeTokens.self, forKey: .tokens) ?? ThemeTokens()
        fonts = try c.decodeIfPresent(FontTokens.self, forKey: .fonts) ?? FontTokens()
        radii = try c.decodeIfPresent(RadiusTokens.self, forKey: .radii) ?? RadiusTokens()
    }

    @MainActor var changes: Int {
        Palette.tokenRows.count { tokens[keyPath: $0.override] != nil }
            + [fonts.reading, fonts.title, fonts.ui, fonts.code].compactMap { $0 }.count
            + [radii.control, radii.panel, radii.sheet].compactMap { $0 }.count
    }
}

struct UISettings: Codable, Equatable, Sendable {
    var theme = "light"
    var followSystem = true
    var dayTheme = "light"
    var nightTheme = "dark"
    var textSize = 19.0
    var lineSpacing = 1.6
    var columnWidth = 640.0
    var loadImages = false
    /// `app` or `browser`.
    var openLinks = "app"
    /// `scrolling`, `always` or `never`.
    var scrollbars = "scrolling"
    var agentTier = "read"
    var collapsedFolders: [Int64] = []
    /// Temporary fonts on top of the active theme. They last until the theme changes.
    var fonts = FontTokens()
    var themes: [CustomTheme] = []

    init() {}

    /// A hand-written file may hold any subset of these.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UISettings()
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        followSystem = try c.decodeIfPresent(Bool.self, forKey: .followSystem) ?? d.followSystem
        dayTheme = try c.decodeIfPresent(String.self, forKey: .dayTheme) ?? d.dayTheme
        nightTheme = try c.decodeIfPresent(String.self, forKey: .nightTheme) ?? d.nightTheme
        textSize = try c.decodeIfPresent(Double.self, forKey: .textSize) ?? d.textSize
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? d.lineSpacing
        columnWidth = try c.decodeIfPresent(Double.self, forKey: .columnWidth) ?? d.columnWidth
        loadImages = try c.decodeIfPresent(Bool.self, forKey: .loadImages) ?? d.loadImages
        openLinks = try c.decodeIfPresent(String.self, forKey: .openLinks) ?? d.openLinks
        scrollbars = try c.decodeIfPresent(String.self, forKey: .scrollbars) ?? d.scrollbars
        agentTier = try c.decodeIfPresent(String.self, forKey: .agentTier) ?? d.agentTier
        collapsedFolders = try c.decodeIfPresent([Int64].self, forKey: .collapsedFolders) ?? d.collapsedFolders
        fonts = try c.decodeIfPresent(FontTokens.self, forKey: .fonts) ?? d.fonts
        themes = try c.decodeIfPresent([CustomTheme].self, forKey: .themes) ?? d.themes
    }
}

private struct ConfigReply: Decodable, Sendable {
    let fullText: Bool
    let removeReadAfterDays: Int64
    let ui: UISettings?
    let configError: String?
}

private struct UIParams: Encodable, Sendable { let ui: UISettings }

@MainActor @Observable
final class Prefs {
    static let shared = Prefs()

    var ui = UISettings() {
        didSet {
            guard ui != oldValue, !applying else { return }
            clearFontsIfThemeChanged()
            scheduleSave()
        }
    }
    /// What the system appearance is, for following it. Set by `Themed`.
    var systemIsDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        didSet { if systemIsDark != oldValue { clearFontsIfThemeChanged() } }
    }
    /// The theme the Tokens pane shows, when something has just asked for one.
    var editingTheme: String?
    var fullText = true
    var removeReadAfterDays: Int64 = 0
    /// Set while config.json cannot be parsed. The last good settings stay in use.
    var fileProblem: String?

    private var applying = false
    private var lastTheme = "light"
    private var pendingSave: Task<Void, Never>?
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?

    /// Settings from before config.json held them, kept in the user's preferences.
    private static func fromUserDefaults() -> UISettings {
        let saved = UserDefaults.standard
        var ui = UISettings()
        if let value = saved.string(forKey: "theme") { ui.theme = value }
        if saved.object(forKey: "followSystem") != nil { ui.followSystem = saved.bool(forKey: "followSystem") }
        if let value = saved.string(forKey: "readingFont") { ui.fonts.reading = value }
        if saved.object(forKey: "textSize") != nil { ui.textSize = saved.double(forKey: "textSize") }
        if saved.object(forKey: "lineSpacing") != nil { ui.lineSpacing = saved.double(forKey: "lineSpacing") }
        if saved.object(forKey: "columnWidth") != nil { ui.columnWidth = saved.double(forKey: "columnWidth") }
        if saved.object(forKey: "loadImages") != nil { ui.loadImages = saved.bool(forKey: "loadImages") }
        if let value = saved.string(forKey: "agentTier") { ui.agentTier = value }
        return ui
    }

    /// `-theme dark -followSystem NO` on the command line applies to this run only,
    /// which rendering checks rely on.
    private func withLaunchArguments(_ settings: UISettings) -> UISettings {
        var ui = settings
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let value = arguments["theme"] as? String { ui.theme = value }
        if arguments["followSystem"] != nil { ui.followSystem = UserDefaults.standard.bool(forKey: "followSystem") }
        return ui
    }

    func start() async {
        await load()
        watch()
    }

    func load() async {
        do {
            let reply: ConfigReply = try await Daemon.shared.call("config.get")
            fullText = reply.fullText
            removeReadAfterDays = reply.removeReadAfterDays
            fileProblem = reply.configError
            guard reply.configError == nil else { return }
            if let settings = reply.ui {
                apply(withLaunchArguments(settings))
            } else {
                let settings = Self.fromUserDefaults()
                try await save(settings)
                apply(withLaunchArguments(settings))
            }
        } catch {
            fileProblem = error.localizedDescription
        }
    }

    private func apply(_ settings: UISettings) {
        applying = true
        ui = settings
        applying = false
        lastTheme = activeTheme
    }

    /// Every theme has its own fonts, so a temporary font belongs to the theme it was
    /// chosen on, and goes when that theme does. A restart keeps it.
    private func clearFontsIfThemeChanged() {
        let theme = activeTheme
        guard theme != lastTheme else { return }
        lastTheme = theme
        if !ui.fonts.isEmpty { ui.fonts = FontTokens() }
    }

    // MARK: Themes

    static let builtIns = ["light", "dark", "newsprint", "terminal"]

    var allThemes: [String] { Self.builtIns + ui.themes.map(\.id) }

    func custom(_ id: String) -> CustomTheme? { ui.themes.first { $0.id == id } }

    func themeName(_ id: String) -> String { custom(id)?.name ?? id.capitalized }

    /// A saved choice may name a theme since deleted.
    private func known(_ id: String) -> String { allThemes.contains(id) ? id : "light" }

    var activeTheme: String {
        known(ui.followSystem ? (systemIsDark ? ui.nightTheme : ui.dayTheme) : ui.theme)
    }

    /// Uses a theme, in the slot that is deciding right now.
    func activate(_ id: String) {
        if !ui.followSystem {
            ui.theme = id
        } else if systemIsDark {
            ui.nightTheme = id
        } else {
            ui.dayTheme = id
        }
    }

    private func builtInFonts(_ id: String) -> FontTokens {
        // Terminal's look is its typeface as much as its colors.
        let text = id == "terminal" ? Tokens.fontCode : Tokens.fontReading
        return FontTokens(reading: text, title: text, ui: Tokens.fontUi, code: Tokens.fontCode)
    }

    /// A theme's fonts with nothing left unset.
    func fonts(of id: String) -> FontTokens {
        let theme = custom(id)
        let base = builtInFonts(theme?.base ?? id)
        let own = theme?.fonts ?? FontTokens()
        return FontTokens(
            reading: own.reading ?? base.reading, title: own.title ?? base.title,
            ui: own.ui ?? base.ui, code: own.code ?? base.code)
    }

    /// What is on screen: the active theme's fonts, under any temporary change.
    var currentFonts: FontTokens {
        let theme = fonts(of: activeTheme)
        return FontTokens(
            reading: ui.fonts.reading ?? theme.reading, title: ui.fonts.title ?? theme.title,
            ui: ui.fonts.ui ?? theme.ui, code: ui.fonts.code ?? theme.code)
    }

    /// Sets a temporary font. Choosing what the theme already has clears it.
    func setFont(_ slot: WritableKeyPath<FontTokens, String?>, to family: String) {
        ui.fonts[keyPath: slot] = fonts(of: activeTheme)[keyPath: slot] == family ? nil : family
    }

    /// Finds an id for a new theme that collides with nothing, built-ins included.
    private func newId(for name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let start = slug.isEmpty ? "theme" : slug
        return ([start] + (2...999).map { "\(start)-\($0)" }).first { !allThemes.contains($0) } ?? UUID().uuidString
    }

    /// Makes a theme from another, keeping that theme's changes.
    @discardableResult
    func createTheme(name: String, from source: String) -> String {
        let original = custom(source)
        var theme = CustomTheme(id: newId(for: name), name: name, base: original?.base ?? source)
        if let original {
            theme.tokens = original.tokens
            theme.fonts = original.fonts
            theme.radii = original.radii
        }
        ui.themes.append(theme)
        return theme.id
    }

    /// Writes the temporary fonts into a custom theme.
    func saveFonts(to id: String) {
        guard let index = ui.themes.firstIndex(where: { $0.id == id }) else { return }
        let temporary = ui.fonts
        ui.themes[index].fonts = FontTokens(
            reading: temporary.reading ?? ui.themes[index].fonts.reading, title: temporary.title ?? ui.themes[index].fonts.title,
            ui: temporary.ui ?? ui.themes[index].fonts.ui, code: temporary.code ?? ui.themes[index].fonts.code)
        ui.fonts = FontTokens()
    }

    /// Turns what is on screen, built-in or not, into a new theme and uses it.
    func saveAsNewTheme(name: String) {
        let source = activeTheme
        let id = createTheme(name: name, from: source)
        saveFonts(to: id)
        activate(id)
    }

    /// Whatever used this theme goes to its base.
    func deleteTheme(_ id: String) {
        guard let theme = custom(id) else { return }
        ui.themes.removeAll { $0.id == id }
        if ui.theme == id { ui.theme = theme.base }
        if ui.dayTheme == id { ui.dayTheme = theme.base }
        if ui.nightTheme == id { ui.nightTheme = theme.base }
    }

    func edit(_ id: String, _ change: (inout CustomTheme) -> Void) {
        if let index = ui.themes.firstIndex(where: { $0.id == id }) { change(&ui.themes[index]) }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let settings = ui
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try await save(settings)
            } catch {
                fileProblem = error.localizedDescription
            }
        }
    }

    private func save(_ settings: UISettings) async throws {
        let _: Ok = try await Daemon.shared.call("config.set", UIParams(ui: settings))
    }

    /// The daemon and many editors replace config.json by rename, which only the
    /// folder shows. Others save in place, which only the file shows. So both are
    /// watched, and the file's watch is renewed after each change, since a rename
    /// leaves it on the old file.
    private func watch() {
        folderWatcher = source(for: Daemon.shared.home.path, events: .write)
        watchFile()
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = source(for: Daemon.shared.home.appending(path: "config.json").path, events: [.write, .extend, .delete, .rename])
    }

    private func source(for path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                await self?.load()
                self?.watchFile()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}

/// Radii of the active theme, for use wherever the token would be.
@MainActor enum Radii {
    private static var theme: RadiusTokens { Prefs.shared.custom(Prefs.shared.activeTheme)?.radii ?? RadiusTokens() }
    static var control: Double { theme.control ?? Tokens.radiusControl }
    static var panel: Double { theme.panel ?? Tokens.radiusPanel }
    static var sheet: Double { theme.sheet ?? Tokens.radiusSheet }
}
