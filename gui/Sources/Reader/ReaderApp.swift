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
                Button("Briefing") { model.go(to: .briefing) }.keyboardShortcut("1")
                Button("All") { model.go(to: .all) }.keyboardShortcut("2")
                Button("Starred") { model.go(to: .starred) }.keyboardShortcut("3")
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

/// Applies the chosen theme and reading font to everything inside.
struct Themed<Content: View>: View {
    @ViewBuilder var content: Content
    @AppStorage(Keys.theme) private var theme = "light"
    @AppStorage(Keys.followSystem) private var followSystem = true
    @AppStorage(Keys.readingFont) private var readingFont = Tokens.fontReading
    @Environment(\.colorScheme) private var systemScheme

    private var palette: Palette {
        followSystem ? (systemScheme == .dark ? .dark : .light) : .named(theme)
    }

    var body: some View {
        content
            .environment(\.palette, palette)
            .environment(\.readingFamily, Fonts.resolve(readingFont))
            .background(palette.ground)
            .foregroundStyle(palette.ink)
            .tint(palette.unread)
            // With no override, colorScheme above keeps reporting the system's.
            .preferredColorScheme(followSystem ? nil : (palette.isDark ? .dark : .light))
    }
}

/// `RSS_SNAPSHOT=file.png` draws the window once it settles, saves it, and quits.
/// It gives checks a real rendering with no screen recording permission.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = ProcessInfo.processInfo.environment["RSS_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["RSS_SNAPSHOT_DELAY"] ?? "") ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            exit(0)
        }
    }
}
