// Palettes come from Tokens.swift, which is generated from the Paper file.
import AppKit
import SwiftUI

extension Color {
    init(rgba: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgba >> 24) & 0xFF) / 255,
            green: Double((rgba >> 16) & 0xFF) / 255,
            blue: Double((rgba >> 8) & 0xFF) / 255,
            opacity: Double(rgba & 0xFF) / 255
        )
    }
}

struct Palette: Equatable {
    var id: String
    var isDark: Bool
    var ground, surface, selected, selectedStrong, hairline, control: Color
    var ink, inkSoft, muted, unread, read, onAccent, scrim: Color

    static let light = Palette(
        id: "light", isDark: false,
        ground: Color(rgba: Tokens.colorLightGround), surface: Color(rgba: Tokens.colorLightSurface),
        selected: Color(rgba: Tokens.colorLightSelected), selectedStrong: Color(rgba: Tokens.colorLightSelectedStrong),
        hairline: Color(rgba: Tokens.colorLightHairline), control: Color(rgba: Tokens.colorLightControl),
        ink: Color(rgba: Tokens.colorLightInk), inkSoft: Color(rgba: Tokens.colorLightInkSoft),
        muted: Color(rgba: Tokens.colorLightMuted), unread: Color(rgba: Tokens.colorLightUnread),
        read: Color(rgba: Tokens.colorLightRead), onAccent: Color(rgba: Tokens.colorLightOnAccent),
        scrim: Color(rgba: Tokens.colorLightScrim)
    )

    static let dark = Palette(
        id: "dark", isDark: true,
        ground: Color(rgba: Tokens.colorDarkGround), surface: Color(rgba: Tokens.colorDarkSurface),
        selected: Color(rgba: Tokens.colorDarkSelected), selectedStrong: Color(rgba: Tokens.colorDarkSelectedStrong),
        hairline: Color(rgba: Tokens.colorDarkHairline), control: Color(rgba: Tokens.colorDarkControl),
        ink: Color(rgba: Tokens.colorDarkInk), inkSoft: Color(rgba: Tokens.colorDarkInkSoft),
        muted: Color(rgba: Tokens.colorDarkMuted), unread: Color(rgba: Tokens.colorDarkUnread),
        read: Color(rgba: Tokens.colorDarkRead), onAccent: Color(rgba: Tokens.colorDarkOnAccent),
        scrim: Color(rgba: Tokens.colorDarkScrim)
    )

    /// Paper defines only three colours for these two. The rest follow from them.
    static let newsprint: Palette = {
        var p = light
        p.id = "newsprint"
        p.ground = Color(rgba: Tokens.colorNewsprintGround)
        p.unread = Color(rgba: Tokens.colorNewsprintUnread)
        p.read = Color(rgba: Tokens.colorNewsprintRead)
        p.surface = p.ground.mix(with: .black, by: 0.04)
        p.selected = p.ground.mix(with: .black, by: 0.07)
        p.selectedStrong = p.ground.mix(with: .black, by: 0.11)
        p.hairline = p.ground.mix(with: .black, by: 0.11)
        p.muted = p.read
        p.onAccent = p.ground
        return p
    }()

    static let terminal: Palette = {
        var p = dark
        p.id = "terminal"
        p.ground = Color(rgba: Tokens.colorTerminalGround)
        p.unread = Color(rgba: Tokens.colorTerminalUnread)
        p.read = Color(rgba: Tokens.colorTerminalRead)
        p.ink = p.unread
        p.inkSoft = p.unread.mix(with: .black, by: 0.2)
        p.muted = p.read
        p.surface = p.unread.mix(with: .black, by: 0.93)
        p.selected = p.unread.mix(with: .black, by: 0.86)
        p.selectedStrong = p.unread.mix(with: .black, by: 0.8)
        p.hairline = p.unread.mix(with: .black, by: 0.8)
        p.control = p.read
        p.onAccent = p.ground
        return p
    }()

    static func named(_ id: String) -> Palette {
        switch id {
        case "dark": dark
        case "newsprint": newsprint
        case "terminal": terminal
        default: light
        }
    }
}

extension EnvironmentValues {
    @Entry var palette: Palette = .light
    @Entry var readingFamily: String = Tokens.fontReading
}

enum Keys {
    static let theme = "theme"
    static let followSystem = "followSystem"
    static let readingFont = "readingFont"
    static let textSize = "textSize"
    static let lineSpacing = "lineSpacing"
    static let columnWidth = "columnWidth"
    static let loadImages = "loadImages"
}

enum Fonts {
    /// Bundled, so the reader looks right on a Mac with none of these installed.
    static func registerBundled() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// A saved choice may have been uninstalled since.
    static func resolve(_ family: String) -> String {
        NSFontManager.shared.availableFontFamilies.contains(family) ? family : Tokens.fontReading
    }

    static let choices = [Tokens.fontReading, "Source Serif 4", "Inter", Tokens.fontCode]

    static func label(_ family: String) -> String { family == "Source Serif 4" ? "Source Serif" : family }
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func code(_ size: CGFloat) -> Font { .custom(Tokens.fontCode, fixedSize: size) }
}

/// Sets exact line height, as the design does, rather than the font's default.
extension View {
    func line(_ height: CGFloat, size: CGFloat) -> some View {
        lineSpacing(max(0, height - size * 1.2))
    }
}
