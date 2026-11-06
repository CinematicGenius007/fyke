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

    /// The tokens of one theme, in the order the Tokens pane lists them.
    @MainActor static let tokenRows: [(label: String, palette: WritableKeyPath<Palette, Color>, override: WritableKeyPath<ThemeTokens, String?>)] = [
        ("Ground", \.ground, \.ground), ("Surface", \.surface, \.surface), ("Selected", \.selected, \.selected),
        ("Selected strong", \.selectedStrong, \.selectedStrong), ("Hairline", \.hairline, \.hairline), ("Control", \.control, \.control),
        ("Ink", \.ink, \.ink), ("Ink soft", \.inkSoft, \.inkSoft), ("Muted", \.muted, \.muted), ("Unread", \.unread, \.unread),
        ("Read", \.read, \.read), ("On accent", \.onAccent, \.onAccent), ("Scrim", \.scrim, \.scrim),
    ]

    /// A theme with the user's overrides on top.
    @MainActor func applying(_ overrides: ThemeTokens) -> Palette {
        var palette = self
        for row in Palette.tokenRows {
            if let text = overrides[keyPath: row.override], let color = Color(hex: text) { palette[keyPath: row.palette] = color }
        }
        return palette
    }

    /// Any theme, built-in or the user's.
    @MainActor static func resolved(_ id: String) -> Palette {
        guard let theme = Prefs.shared.custom(id) else { return named(id) }
        var palette = named(theme.base).applying(theme.tokens)
        palette.id = id
        return palette
    }
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`.
    init?(hex text: String) {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(rgba: digits.count == 6 ? value << 8 | 0xFF : value)
    }

    var hex: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        let parts = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        let alpha = Int((color.alphaComponent * 255).rounded())
        let text = String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
        return alpha == 255 ? text : text + String(format: "%02X", alpha)
    }

    /// WCAG relative luminance, for the contrast note in the color picker.
    var luminance: Double {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
    }

    func contrast(with other: Color) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension EnvironmentValues {
    @Entry var palette: Palette = .light
    @Entry var readingFamily: String = Tokens.fontReading
    @Entry var titleFamily: String = Tokens.fontReading
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
    @MainActor static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.resolve(Prefs.shared.currentFonts.ui ?? Tokens.fontUi), fixedSize: size).weight(weight)
    }

    @MainActor static func code(_ size: CGFloat) -> Font {
        .custom(Fonts.resolve(Prefs.shared.currentFonts.code ?? Tokens.fontCode), fixedSize: size)
    }
}

/// Sets exact line height, as the design does, rather than the font's default.
extension View {
    func line(_ height: CGFloat, size: CGFloat) -> some View {
        lineSpacing(max(0, height - size * 1.2))
    }
}
