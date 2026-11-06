import AppKit
import SwiftUI

@main
struct ReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        Fonts.registerBundled()
    }

    var body: some Scene {
        Window("rss_", id: "main") {
            Themed { RootView() }
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Feed…") { model.showingAddFeed = true }.keyboardShortcut("n")
            }
            CommandMenu("Go") {
                Button("Search…") { model.search.show() }.keyboardShortcut("f")
                Divider()
                Button("Briefing") { model.go(to: .briefing) }.keyboardShortcut("1")
                Button("All") { model.go(to: .all) }.keyboardShortcut("2")
                Button("Starred") { model.go(to: .starred) }.keyboardShortcut("3")
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.showingShortcuts = true }
            }
        }

        Settings {
            Themed { SettingsView() }
                .environment(model)
                .frame(width: 880, height: 600)
                .background(BorderlessTitle())
        }
    }
}

/// SwiftUI's hidden title bar style does not reach the Settings window.
struct BorderlessTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Applies the active theme to everything inside.
struct Themed<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var systemScheme

    private var prefs: Prefs { .shared }

    var body: some View {
        let palette = Palette.resolved(prefs.activeTheme)
        let fonts = prefs.currentFonts
        FloatHost { content }
            .environment(\.palette, palette)
            .environment(\.readingFamily, Fonts.resolve(fonts.reading ?? Tokens.fontReading))
            .environment(\.titleFamily, Fonts.resolve(fonts.title ?? Tokens.fontReading))
            .background(palette.ground)
            .foregroundStyle(palette.ink)
            .tint(palette.unread)
            // With no override, colorScheme above keeps reporting the system's.
            .preferredColorScheme(prefs.ui.followSystem ? nil : (palette.isDark ? .dark : .light))
            .onChange(of: systemScheme, initial: true) { _, scheme in
                if prefs.ui.followSystem { prefs.systemIsDark = scheme == .dark }
            }
            // While a theme is forced, colorScheme reports that theme, not the system.
            .onChange(of: prefs.ui.followSystem) { _, following in
                if following { prefs.systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
            }
    }
}

/// `RSS_SNAPSHOT=file.png` draws the window once it settles, saves it, and quits.
/// It gives checks a real rendering with no screen recording permission.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyReplay.startIfRequested()
        guard let path = ProcessInfo.processInfo.environment["RSS_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["RSS_SNAPSHOT_DELAY"] ?? "") ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Settings is the smaller window, and it may not have become key.
            let wanted = ProcessInfo.processInfo.environment["RSS_SCREEN"] == "settings" ? NSApp.windows.first { $0.isVisible && $0.frame.width < 1000 } : nil
            // RSS_SNAPSHOT_CHROME takes the frame around the content too, which holds the window buttons.
            let chrome = ProcessInfo.processInfo.environment["RSS_SNAPSHOT_CHROME"] != nil
            guard let window = wanted ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
                let view = chrome ? window.contentView?.superview : window.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            exit(0)
        }
    }
}

/// `RSS_KEYS` plays key presses into the window once it settles, then quits, for
/// tools/e2e_gui.py. Steps are separated by spaces: `cmd+f`, `up`, `down`, `return`,
/// `esc`, `wait`, `click:X,Y`, `rclick:X,Y`, `drag:X1,Y1,X2,Y2`, or text to type. Coordinates count from the
/// window's top left. The events take the same path as real ones from there on.
@MainActor private enum KeyReplay {
    private static let settleSeconds = 2.5
    private static let stepSeconds = 0.5

    static func startIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["RSS_KEYS"] else { return }
        let steps = script.split(separator: " ").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
            play(steps[...])
        }
    }

    private static func play(_ steps: ArraySlice<String>) {
        // With a snapshot requested, that is what ends the run.
        guard let step = steps.first else {
            if ProcessInfo.processInfo.environment["RSS_SNAPSHOT"] == nil { exit(0) }
            return
        }
        send(step)
        DispatchQueue.main.asyncAfter(deadline: .now() + stepSeconds) { play(steps.dropFirst()) }
    }

    private static func send(_ step: String) {
        switch step {
        case "cmd+f": press("f", code: 3, flags: .command)
        case "up": press(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        case "down": press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        case "return": press("\r", code: 36)
        case "esc": press("\u{1B}", code: 53)
        case "wait": break
        case _ where step.hasPrefix("click:"): mouse(step.dropFirst(6), down: .leftMouseDown, up: .leftMouseUp)
        case _ where step.hasPrefix("drag:"): drag(step.dropFirst(5))
        case _ where step.hasPrefix("rclick:"): mouse(step.dropFirst(7), down: .rightMouseDown, up: .rightMouseUp)
        default: step.forEach { press(String($0), code: 0) }
        }
    }

    /// Posted, not sent, so that they pass through the event queue and become
    /// `NSApp.currentEvent`, as real clicks do.
    private static func mouse(_ point: Substring, down: NSEvent.EventType, up: NSEvent.EventType) {
        let parts = point.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.keyWindow, let height = window.contentView?.bounds.height else { return }
        for type in [down, up] {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: parts[0], y: height - parts[1]), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            if let event { NSApp.postEvent(event, atStart: false) }
        }
    }

    /// `drag:x1,y1,x2,y2` presses at the first point and releases at the second.
    private static func drag(_ spec: Substring) {
        let p = spec.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4, let window = NSApp.keyWindow, let height = window.contentView?.bounds.height else { return }
        let steps = 8
        let moves: [(NSEvent.EventType, Double, Double)] =
            [(.leftMouseDown, p[0], p[1])]
            + (1...steps).map { n in (.leftMouseDragged, p[0] + (p[2] - p[0]) * Double(n) / Double(steps), p[1] + (p[3] - p[1]) * Double(n) / Double(steps)) }
            + [(.leftMouseUp, p[2], p[3])]
        for (type, x, y) in moves {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            if let event { NSApp.postEvent(event, atStart: false) }
        }
    }

    private static func press(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
            if let event { NSApp.sendEvent(event) }
        }
    }
}
