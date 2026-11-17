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
            // Settings is a destination of the main window, not a window of its own.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
            }
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


final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { TestMode.prepare() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { TestMode.start() }
    }
}
