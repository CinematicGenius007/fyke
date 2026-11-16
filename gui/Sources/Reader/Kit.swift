// Controls shared by the reader features. Every one draws rest, hover, pressed,
// selected and disabled from tokens. Focus is the system's keyboard ring, drawn in
// the action color that the theme sets as tint, around each control's own shape and
// only on the control that has keyboard focus. Motion is 120 to 200 ms, ease out, and
// none under Reduce Motion.
import AppKit
import SwiftUI

// MARK: Metrics

/// Measurements that more than one view shares, on the 4 pt grid of the design rules.
/// A view that needs one of these uses the name, so a change lands everywhere at once.
enum Metrics {
    /// The reading column: articles, briefs, answers, recipes and routines all set
    /// their text in it.
    static let readingColumn: CGFloat = 640
    /// Space between the reader pane's edge and the reading column.
    static let pageGutter: CGFloat = 48
    /// The band at the top of the reader pane that holds back links and actions.
    static let barHeight: CGFloat = 48
    /// Inset of a bar's controls from the pane's edge.
    static let barEdge: CGFloat = 16
    /// Top inset that centers a compact control in the bar: (48 - 28) / 2.
    static let barControlTop: CGFloat = (barHeight - compactControl) / 2
    /// A button where a full 32 pt one would crowd its row: popovers, bars and lists.
    static let compactControl: CGFloat = 28
    /// A popover's header row.
    static let panelHeader: CGFloat = 44
    /// A one-line row inside a popover or list.
    static let panelRow: CGFloat = 32
    /// Inset of a popover's rows from its edge.
    static let panelEdge: CGFloat = 16
    /// The unread dot, and every status dot drawn like it.
    static let dot: CGFloat = 6
}

extension Radii {
    /// Marks 20 pt high or less: citation numbers inside a line of text, key hints,
    /// generated-text tags and dry-run bars. The control radius of 6 would round
    /// them into pills, so these use 3.
    static let mark: Double = 3
}

// MARK: Motion

enum Motion {
    static let quick = 0.12
    static let standard = 0.16
    static let slow = 0.2

    /// The animation to use, or none when the person asked for less motion.
    static func ease(_ duration: Double = standard, reduce: Bool) -> Animation? {
        reduce ? nil : .easeOut(duration: duration)
    }
}

extension View {
    /// Animates a value change with the house curve, unless motion is reduced.
    func motion<V: Equatable>(_ value: V, _ duration: Double = Motion.standard) -> some View {
        modifier(MotionModifier(value: value, duration: duration))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let value: V
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.animation(Motion.ease(duration, reduce: reduce), value: value)
    }
}

// MARK: Buttons

/// The one button shape: 32 high, radius 6. `primary` is the one action a view is
/// about, and a view has at most one.
struct ActionStyle: ButtonStyle {
    /// `link` is quiet with the action color, for a second action written as words.
    enum Kind { case primary, secondary, quiet, link, inverse }
    var kind: Kind = .secondary
    var selected = false
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, kind: kind, selected: selected, height: height)
    }
}

private struct ActionBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: ActionStyle.Kind
    let selected: Bool
    let height: CGFloat
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    private var fill: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .primary: return enabled ? (pressed ? p.unread.mix(with: .black, by: 0.18) : hovering ? p.unread.mix(with: .black, by: 0.08) : p.unread) : p.selectedStrong
        case .inverse: return pressed ? p.ink.opacity(0.75) : hovering ? p.ink.opacity(0.88) : p.ink
        case .secondary: return selected ? p.selectedStrong : pressed ? p.selectedStrong : hovering ? p.selected : p.ground
        case .quiet, .link: return selected ? p.selectedStrong : pressed ? p.selectedStrong : hovering ? p.selected : .clear
        }
    }

    private var ink: Color {
        guard enabled else { return p.muted }
        switch kind {
        case .primary: return p.onAccent
        case .inverse: return p.ground
        case .secondary, .quiet: return p.ink
        case .link: return p.unread
        }
    }

    var body: some View {
        configuration.label
            .font(.ui(14, .medium))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, kind == .quiet || kind == .link ? 10 : 14)
            .frame(height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: Radii.control))
            .overlay {
                if kind == .secondary { RoundedRectangle(cornerRadius: Radii.control).stroke(enabled ? p.control : p.hairline) }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radii.control))
            .onHover { hovering = $0 }
            .motion(hovering, Motion.quick)
            .motion(configuration.isPressed, Motion.quick)
    }
}

/// A square icon button with the same states as `ActionStyle`.
struct SymbolButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 28
    var selected = false
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular)).frame(width: size, height: size)
        }
        .buttonStyle(SymbolStyle(selected: selected))
        .help(label)
        .accessibilityLabel(label)
    }
}

struct SymbolStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View { SymbolBody(configuration: configuration, selected: selected) }
}

private struct SymbolBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(enabled ? (selected ? p.ink : p.inkSoft) : p.control)
            .background(configuration.isPressed || selected ? p.selectedStrong : hovering && enabled ? p.selected : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .motion(hovering, Motion.quick)
    }
}

/// A word in a sentence that can be tapped. 24 high, radius 6, filled, never bordered.
/// Selected, it fills with the action color.
struct Chip: View {
    let text: String
    var selected = false
    var height: CGFloat = 24
    var muted = false
    let run: () -> Void

    var body: some View {
        Button(action: run) { Text(text) }
            .buttonStyle(ChipStyle(selected: selected, height: height, muted: muted))
    }
}

struct ChipStyle: ButtonStyle {
    var selected = false
    var height: CGFloat = 24
    var muted = false
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, selected: selected, height: height, muted: muted)
    }
}

private struct ChipBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let height: CGFloat
    let muted: Bool
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.ui(13, selected ? .medium : .regular))
            .foregroundStyle(!enabled ? p.muted : selected ? p.onAccent : muted ? p.muted : p.ink)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: Radii.control))
            .contentShape(RoundedRectangle(cornerRadius: Radii.control))
            .onHover { hovering = $0 }
            .motion(hovering, Motion.quick)
            .motion(selected, Motion.quick)
    }

    private var background: Color {
        if selected { return configuration.isPressed ? p.unread.mix(with: .black, by: 0.15) : p.unread }
        if !enabled { return p.selected.opacity(0.5) }
        if configuration.isPressed { return p.control.opacity(0.6) }
        return hovering ? p.selectedStrong : p.selected
    }
}

/// Edit / Try it / History: a row of tabs sharing one track.
struct Tabs<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(Value, String)]
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                Button { selection = item.0 } label: { Text(item.1) }
                    .buttonStyle(TabStyle(selected: selection == item.0))
                    .accessibilityAddTraits(selection == item.0 ? .isSelected : [])
            }
        }
        .padding(4)
        .background(p.selected, in: RoundedRectangle(cornerRadius: Radii.panel))
    }
}

private struct TabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { TabBody(configuration: configuration, selected: selected) }
}

private struct TabBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.ui(13, selected ? .medium : .regular))
            .foregroundStyle(selected || hovering ? p.ink : p.inkSoft)
            .padding(.horizontal, 10).frame(height: 24)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Radii.control).fill(p.ground).shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                } else if configuration.isPressed {
                    RoundedRectangle(cornerRadius: Radii.control).fill(p.selectedStrong)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .motion(selected, Motion.quick)
    }
}

// MARK: Popover

extension View {
    /// The popover look from the rules: radius 10, a hairline, and two shadows.
    func popoverPanel(padding: CGFloat = 0) -> some View {
        modifier(PopoverPanel(padding: padding))
    }
}

struct PopoverPanel: ViewModifier {
    let padding: CGFloat
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        // The content is clipped to the shape before the shadows are drawn, so that the
        // clip cannot cut them off. A CSS blur of 32 is a SwiftUI radius of about 16.
        content
            .padding(padding)
            .background(p.isDark ? p.surface : p.ground)
            .clipShape(RoundedRectangle(cornerRadius: Radii.panel))
            .overlay(RoundedRectangle(cornerRadius: Radii.panel).strokeBorder(p.hairline))
            .background {
                RoundedRectangle(cornerRadius: Radii.panel).fill(p.isDark ? p.surface : p.ground)
                    .shadow(color: .black.opacity(p.isDark ? 0.45 : 0x1F / 255), radius: 16, y: 12)
                    .shadow(color: .black.opacity(p.isDark ? 0.3 : 0x14 / 255), radius: 3, y: 2)
            }
    }
}

// MARK: States

/// An empty, failed or in-progress state: what happened, what is safe, and the one
/// thing to do next. It sits where the content would.
struct InlineState: View {
    enum Tone { case working, failed, empty }

    let tone: Tone
    let label: String
    let title: String
    let detail: String
    var primary: (String, () -> Void)?
    var secondary: (String, () -> Void)?
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily
    @Environment(\.readingFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                switch tone {
                case .working: Spinner(size: 12)
                case .failed: Circle().fill(p.unread).frame(width: Metrics.dot, height: Metrics.dot)
                case .empty: EmptyView()
                }
                Text(label.uppercased()).font(.ui(11, .semibold)).tracking(0.66)
                    .foregroundStyle(tone == .empty ? p.muted : p.unread)
            }
            .padding(.bottom, 12)
            Text(title).font(.custom(titleFamily, fixedSize: 26).weight(.semibold)).tracking(-0.26)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Text(detail).font(.custom(family, fixedSize: 17)).foregroundStyle(p.inkSoft).line(26, size: 17)
                .fixedSize(horizontal: false, vertical: true)
            if primary != nil || secondary != nil {
                HStack(spacing: 8) {
                    if let primary { Button(primary.0, action: primary.1).buttonStyle(ActionStyle(kind: tone == .working ? .secondary : .primary)) }
                    if let secondary { Button(secondary.0, action: secondary.1).buttonStyle(ActionStyle(kind: .quiet)) }
                }
                .padding(.top, 24)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// A turning arc. Under Reduce Motion it holds still.
struct Spinner: View {
    var size: CGFloat = 14
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var turning = false

    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(p.unread, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(reduce ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityLabel("Working")
    }
}

struct ProgressLine: View {
    let fraction: Double
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(p.hairline)
                Capsule().fill(p.unread).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
        .motion(fraction)
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// A key as the interface names it: ⌘Z, ←, Tab.
struct KeyHint: View {
    let text: String
    var onDark = false
    @Environment(\.palette) private var p

    var body: some View {
        Text(text).font(.ui(11, .medium))
            .foregroundStyle(onDark ? p.ground.opacity(0.7) : p.muted)
            .padding(.horizontal, 4).frame(minWidth: 20, minHeight: 20)
            .background(onDark ? p.ground.opacity(0.12) : p.selected, in: RoundedRectangle(cornerRadius: Radii.mark))
    }
}

/// The caps label above a group: 11 pt, weight 600, +0.06em, muted.
struct SectionLabel: View {
    let text: String
    @Environment(\.palette) private var p
    var body: some View {
        Text(text.uppercased()).font(.ui(11, .semibold)).tracking(0.66).foregroundStyle(p.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Marks generated text as generated.
struct GeneratedTag: View {
    let text: String
    @Environment(\.palette) private var p
    var body: some View {
        Text(text.uppercased()).font(.ui(11, .semibold)).tracking(0.5)
            .foregroundStyle(p.inkSoft)
            .padding(.horizontal, 8).frame(height: 20)
            .background(p.selected, in: RoundedRectangle(cornerRadius: Radii.mark))
    }
}

/// A one-line text field in the control shape, with a focus ring.
struct Field: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 32
    var font: Font? = nil
    var submit: () -> Void = {}
    @FocusState private var focused: Bool
    @Environment(\.palette) private var p
    var autofocus = false

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(p.muted))
            .textFieldStyle(.plain)
            .font(font ?? .ui(14))
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(p.ground, in: RoundedRectangle(cornerRadius: Radii.control))
            .overlay(RoundedRectangle(cornerRadius: Radii.control).stroke(focused ? p.unread : p.control, lineWidth: focused ? 1.5 : 1))
            .focused($focused)
            .accessibilityLabel(placeholder)
            .onSubmit(submit)
            .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
            .motion(focused, Motion.quick)
    }
}

// MARK: Hover

extension View {
    /// Reports where this view is in the reader's coordinate space.
    func frameIn(_ space: String, _ report: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { report($0) }
    }
}
