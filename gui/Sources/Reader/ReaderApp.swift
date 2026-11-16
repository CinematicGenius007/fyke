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
        Window("Fyke", id: "main") {
            Themed { RootView() }
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Feed…") { model.showingAddFeed = true }.keyboardShortcut("n")
                Button("New Folder") { model.newFolder(in: nil) }
                Button("New Routine") { model.newRoutine() }.disabled(model.library.views.isEmpty)
            }
            CommandGroup(replacing: .saveItem) {
                // Saves what is in front: the search as a view, or an open recipe or routine.
                Button(model.search.isShowing ? "Save Search as View" : "Save") { model.saveCommand() }.keyboardShortcut("s")
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.undo.canUndo ? "Undo \(model.undo.stack.last?.message ?? "")" : "Undo") { Self.undo(model) }.keyboardShortcut("z")
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Everything…") { model.commands.show() }.keyboardShortcut("k")
                Button("Search…") { model.search.show() }.keyboardShortcut("f")
                Divider()
                Button("Today") { model.go(to: .today) }.keyboardShortcut("1")
                Button("All") { model.go(to: .all) }.keyboardShortcut("2")
                Button("Starred") { model.go(to: .starred) }.keyboardShortcut("3")
                Button("Routines") { model.go(to: .routines) }.keyboardShortcut("4")
                Divider()
                Button("Catch Up") { model.startCatchUp() }.keyboardShortcut("j")
                Button("Activity") { model.showingActivity.toggle() }.keyboardShortcut("0")
            }
            CommandMenu("Write") {
                Button("Write a Brief") { model.runBrief() }.keyboardShortcut("r").disabled(model.briefJob != nil)
                Button("Ask Your Feeds…") { model.ask.start(question: "", view: model.place.viewId, model: model) }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Edit Recipe") {
                    if model.place != .today { model.go(to: .today) }
                    model.openRecipe(model.library.briefs.first { $0.id == model.selectedBrief }?.recipeId)
                }
                .disabled(model.library.recipes.isEmpty)
                Divider()
                Button("Mark All Read") { Self.markAll(model) }.keyboardShortcut("k", modifiers: [.command, .shift])
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

extension ReaderApp {
    /// Text being edited takes ⌘Z first, while it has typing to take back. Then
    /// catch-up's own stack, then the app's.
    @MainActor static func undo(_ model: AppModel) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else if let catchUp = model.catchUp {
            catchUp.undo()
        } else {
            model.undo.undoLast()
        }
    }

    @MainActor static func markAll(_ model: AppModel) {
        switch model.place {
        case .feed(let id): model.markAllRead(feed: id)
        case .folder(let id): model.markAllRead(folder: id)
        case .view(let id): model.markAllRead(view: id)
        default: model.markAllRead()
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

/// `FYKE_SNAPSHOT=file.png` draws the window once it settles, saves it, and quits.
/// It gives checks a real rendering with no screen recording permission.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Checks click at window coordinates and compare pictures, so they need the
        // default size, not the frame the window last had on this Mac.
        let environment = ProcessInfo.processInfo.environment
        if environment["FYKE_KEYS"] != nil || environment["FYKE_SNAPSHOT"] != nil {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.isVisible && window.frame.width >= 960 {
                    window.setContentSize(NSSize(width: 1440, height: 900))
                }
            }
        }
        KeyReplay.startIfRequested()
        guard let path = ProcessInfo.processInfo.environment["FYKE_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["FYKE_SNAPSHOT_DELAY"] ?? "") ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Settings is the smaller window, and it may not have become key.
            let wanted = ProcessInfo.processInfo.environment["FYKE_SCREEN"] == "settings" ? NSApp.windows.first { $0.isVisible && $0.frame.width < 1000 } : nil
            // FYKE_SNAPSHOT_CHROME takes the frame around the content too, which holds the window buttons.
            let chrome = ProcessInfo.processInfo.environment["FYKE_SNAPSHOT_CHROME"] != nil
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

/// `FYKE_KEYS` plays key presses into the window once it settles, then quits, for
/// tools/e2e_gui.py. Steps are separated by spaces: `cmd+K` or `shift+cmd+K` for any
/// letter or digit K, `up`, `down`, `left`, `right`, `tab`, `space`, `return`, `esc`, `wait`,
/// `click:X,Y`, `rclick:X,Y`, `drag:X1,Y1,X2,Y2`, or text to type. Coordinates count from the
/// window's top left. The events take the same path as real ones from there on.
@MainActor private enum KeyReplay {
    private static let settleSeconds = 2.5
    private static let stepSeconds = 0.5

    static func startIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["FYKE_KEYS"] else { return }
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
            if ProcessInfo.processInfo.environment["FYKE_SNAPSHOT"] == nil { exit(0) }
            return
        }
        send(step)
        DispatchQueue.main.asyncAfter(deadline: .now() + stepSeconds) { play(steps.dropFirst()) }
    }

    private static func send(_ step: String) {
        switch step {
        case _ where step.hasPrefix("cmd+") || step.hasPrefix("shift+cmd+"):
            let key = String(step.split(separator: "+").last ?? "")
            press(key, code: keyCodes[key] ?? 0, flags: step.hasPrefix("shift") ? [.command, .shift] : .command)
        case "up": press(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        case "down": press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        case "left": press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
        case "right": press(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
        case "tab": press("\t", code: 48)
        case "space": press(" ", code: 49)
        case "return": press("\r", code: 36)
        case "esc": press("\u{1B}", code: 53)
        case "wait": break
        case _ where step.hasPrefix("click:"): mouse(step.dropFirst(6), down: .leftMouseDown, up: .leftMouseUp)
        case _ where step.hasPrefix("drag:"): drag(step.dropFirst(5))
        case _ where step.hasPrefix("rclick:"): mouse(step.dropFirst(7), down: .rightMouseDown, up: .rightMouseUp)
        default: step.forEach { press(String($0), code: 0) }
        }
    }

    /// ANSI key codes, which menus match key equivalents against with the characters.
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

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
