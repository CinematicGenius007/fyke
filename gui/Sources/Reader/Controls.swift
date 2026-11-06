// The app's own controls. They are drawn from tokens, so they follow every theme and
// every change the user makes, which native controls would not.
import AppKit
import Observation
import SwiftUI

// MARK: Icons

/// Drawn on a 16 unit grid with a 1.5 stroke, as in the Paper file.
enum Glyph {
    case search, briefing, inbox, star, circle, globe, reload, left, right, down, up
    case check, lock, folder, arrowLeft, arrowRight, close, plus

    func path() -> Path {
        var p = Path()
        func line(_ points: (CGFloat, CGFloat)...) {
            p.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
        }
        switch self {
        case .search:
            p.addEllipse(in: CGRect(x: 2.75, y: 2.75, width: 8.5, height: 8.5))
            line((10.2, 10.2), (13.5, 13.5))
        case .briefing:
            line((3, 3.5), (13, 3.5)); line((3, 8), (13, 8)); line((3, 12.5), (9, 12.5))
        case .inbox:
            p.addRoundedRect(in: CGRect(x: 2.75, y: 2.75, width: 10.5, height: 10.5), cornerSize: CGSize(width: 2, height: 2))
            line((2.75, 9.5), (5.75, 9.5), (6.75, 11), (9.25, 11), (10.25, 9.5), (13.25, 9.5))
        case .star:
            line((8, 2.2), (9.8, 5.9), (13.8, 6.5), (10.9, 9.3), (11.6, 13.3), (8, 11.4), (4.4, 13.3), (5.1, 9.3), (2.2, 6.5), (6.2, 5.9))
            p.closeSubpath()
        case .circle:
            p.addEllipse(in: CGRect(x: 2.75, y: 2.75, width: 10.5, height: 10.5))
        case .globe:
            p.addEllipse(in: CGRect(x: 2.25, y: 2.25, width: 11.5, height: 11.5))
            line((2.5, 8), (13.5, 8))
            p.addEllipse(in: CGRect(x: 5.5, y: 2.3, width: 5, height: 11.4))
        case .reload:
            p.addArc(center: CGPoint(x: 8, y: 8), radius: 4.8, startAngle: .degrees(0), endAngle: .degrees(315), clockwise: false)
            line((12.8, 2.5), (12.8, 5.5), (9.8, 5.5))
        case .left: line((9.5, 3.5), (5, 8), (9.5, 12.5))
        case .right: line((6, 4), (10, 8), (6, 12))
        case .down: line((4, 6), (8, 10), (12, 6))
        case .up: line((4, 10), (8, 6), (12, 10))
        case .check: line((3.5, 8.5), (6.5, 11.5), (12.5, 4.5))
        case .lock:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 7, width: 9, height: 6.5), cornerSize: CGSize(width: 1.5, height: 1.5))
            p.move(to: CGPoint(x: 5.5, y: 7))
            p.addLine(to: CGPoint(x: 5.5, y: 5))
            p.addArc(center: CGPoint(x: 8, y: 5), radius: 2.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: 10.5, y: 7))
        case .folder:
            line((2.5, 12), (2.5, 4.5), (3.5, 3.5), (6.5, 3.5), (8, 5), (12.5, 5), (13.5, 6), (13.5, 12), (12.5, 13), (3.5, 13))
            p.closeSubpath()
        case .arrowLeft: line((13, 8), (3.5, 8)); line((7, 4.5), (3.5, 8), (7, 11.5))
        case .arrowRight: line((3, 8), (12.5, 8)); line((9, 4.5), (12.5, 8), (9, 11.5))
        case .close: line((4, 4), (12, 12)); line((12, 4), (4, 12))
        case .plus: line((8, 3), (8, 13)); line((3, 8), (13, 8))
        }
        return p
    }
}

private struct GlyphShape: Shape {
    let glyph: Glyph
    func path(in rect: CGRect) -> Path {
        glyph.path().applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16))
    }
}

struct Icon: View {
    let glyph: Glyph
    var size: CGFloat = 16
    var color: Color?
    var filled = false
    @Environment(\.palette) private var p

    var body: some View {
        let ink = color ?? p.inkSoft
        ZStack {
            if filled { GlyphShape(glyph: glyph).fill(ink) }
            GlyphShape(glyph: glyph)
                .stroke(ink, style: StrokeStyle(lineWidth: 1.5 * size / 16, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

/// A 30 point square button holding one icon.
struct IconButton: View {
    let glyph: Glyph
    let help: String
    var color: Color?
    var filled = false
    var enabled = true
    let run: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: run) {
            Icon(glyph: glyph, color: enabled ? color : p.control, filled: filled)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: Floating panels

/// Holds the one panel open in a window. Selects, pickers and right-click menus all
/// open here, above everything, so a panel is never clipped by the view that opened it.
@MainActor @Observable
final class FloatLayer {
    struct Item {
        let id = UUID()
        let anchor: CGRect
        let content: AnyView
    }

    var item: Item?
    /// A submenu, open beside `item`.
    var side: Item?

    func show(at anchor: CGRect, @ViewBuilder content: () -> some View) {
        side = nil
        item = Item(anchor: anchor, content: AnyView(content()))
    }

    func showSide(at anchor: CGRect, @ViewBuilder content: () -> some View) {
        side = Item(anchor: anchor, content: AnyView(content()))
    }

    func close() {
        item = nil
        side = nil
    }
}

private struct FloatPlacement: View {
    let item: FloatLayer.Item
    let bounds: CGSize
    @State private var size = CGSize.zero

    /// Opens below the anchor, and above it when the window has no room below.
    private var origin: CGPoint {
        let below = item.anchor.maxY + 4
        let y = below + size.height > bounds.height - 8 ? max(8, item.anchor.minY - size.height - 4) : below
        let x = min(max(8, item.anchor.minX), max(8, bounds.width - size.width - 8))
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        item.content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: origin.x, y: origin.y)
            .opacity(size == .zero ? 0 : 1)
    }
}

struct FloatHost<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var layer = FloatLayer()

    var body: some View {
        content
            .coordinateSpace(.named("float"))
            .environment(layer)
            .overlay {
                if let item = layer.item {
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.001).onTapGesture { layer.close() }
                            FloatPlacement(item: item, bounds: proxy.size).id(item.id)
                            if let side = layer.side { FloatPlacement(item: side, bounds: proxy.size).id(side.id) }
                        }
                    }
                    .environment(layer)
                }
            }
    }
}

extension View {
    /// The look every floating panel shares.
    func floatPanel(padding: CGFloat = 6) -> some View {
        modifier(FloatPanelStyle(padding: padding))
    }

    /// Reports this view's frame, in the space floating panels use.
    func floatFrame(_ frame: Binding<CGRect>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("float")) } action: { frame.wrappedValue = $0 }
    }
}

private struct FloatPanelStyle: ViewModifier {
    let padding: CGFloat
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: Radii.panel).fill(p.ground)
                    .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.12), radius: 15, y: 10)
            }
            .overlay(RoundedRectangle(cornerRadius: Radii.panel).stroke(p.hairline))
    }
}

/// One row of a floating menu.
struct MenuRow: View {
    let title: String
    var detail: String?
    var checked = false
    var indent: CGFloat = 0
    var trailing: Glyph?
    let run: () -> Void
    @State private var hovering = false
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: run) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(14)).foregroundStyle(p.ink)
                    if let detail { Text(detail).font(.ui(12)).foregroundStyle(p.muted) }
                }
                Spacer(minLength: 16)
                if checked { Icon(glyph: .check, size: 14, color: p.unread) }
                if let trailing { Icon(glyph: trailing, size: 14) }
            }
            .padding(.leading, 8 + indent).padding(.trailing, 8)
            .frame(minHeight: 30)
            .background(hovering ? p.selected : .clear, in: RoundedRectangle(cornerRadius: Radii.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Select

struct SelectOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var indent: CGFloat = 0
    var id: Value { value }
}

struct SelectBox<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SelectOption<Value>]
    var width: CGFloat?
    var height: CGFloat = 30
    /// A last row that runs an action, such as making a new folder.
    var action: (label: String, run: () -> Void)?
    @Environment(FloatLayer.self) private var layer
    @Environment(\.palette) private var p
    @State private var frame = CGRect.zero

    var body: some View {
        Button(action: show) {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? "").font(.ui(14)).foregroundStyle(p.ink).lineLimit(1)
                if width != nil { Spacer(minLength: 4) }
                Icon(glyph: .down, size: 14)
            }
            .padding(.leading, 10).padding(.trailing, 8)
            .frame(width: width, height: height)
            .overlay(RoundedRectangle(cornerRadius: Radii.control).stroke(p.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .floatFrame($frame)
    }

    private func show() {
        layer.show(at: frame) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options) { option in
                    MenuRow(title: option.label, checked: option.value == selection, indent: option.indent) {
                        selection = option.value
                        layer.close()
                    }
                }
                if let action {
                    Rule().padding(.vertical, 3)
                    MenuRow(title: action.label) {
                        layer.close()
                        action.run()
                    }
                }
            }
            .frame(minWidth: max(frame.width - 12, 150), alignment: .leading)
            .floatPanel()
        }
    }
}

// MARK: Accordion

struct DetailsToggle: View {
    @Binding var open: Bool
    var title = "Details"
    @Environment(\.palette) private var p

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Icon(glyph: open ? .down : .right, size: 14, color: p.muted)
                Text(title).font(.ui(13)).foregroundStyle(p.inkSoft)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Checkbox

struct Checkbox: View {
    @Binding var on: Bool
    @Environment(\.palette) private var p

    var body: some View {
        Button { on.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(on ? p.unread : p.ground)
                RoundedRectangle(cornerRadius: 4).stroke(on ? p.unread : p.control)
                if on { Icon(glyph: .check, size: 13, color: p.onAccent) }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Scrollbar

private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var view: CGFloat = 0
}

/// Replaces the system scrollbar with one drawn from tokens. Web pages keep their
/// own, because a page's scrolling happens inside WebKit.
private struct ThemedScrollbar: ViewModifier {
    @State private var metrics = ScrollMetrics()
    @State private var position = ScrollPosition()
    @State private var active = false
    @State private var hovering = false
    @State private var dragStart: CGFloat?
    @State private var hide: Task<Void, Never>?
    @Environment(\.palette) private var p

    private var mode: String { Prefs.shared.ui.scrollbars }
    private var scrollable: Bool { metrics.content > metrics.view + 1 }
    private var thumbHeight: CGFloat { max(32, metrics.view * metrics.view / max(metrics.content, 1)) }
    private var travel: CGFloat { max(1, metrics.view - thumbHeight - 8) }
    private var range: CGFloat { max(1, metrics.content - metrics.view) }
    private var thumbTop: CGFloat { 4 + min(max(metrics.offset / range, 0), 1) * travel }
    private var visible: Bool {
        scrollable && mode != "never" && (mode == "always" || active || hovering || dragStart != nil)
    }

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(offset: geometry.contentOffset.y + geometry.contentInsets.top, content: geometry.contentSize.height, view: geometry.containerSize.height)
            } action: { old, new in
                metrics = new
                if old.offset != new.offset { flash() }
            }
            .overlay(alignment: .topTrailing) {
                if scrollable && mode != "never" { bar }
            }
    }

    private var bar: some View {
        let wide = hovering || dragStart != nil
        return ZStack(alignment: .top) {
            Rectangle().fill(wide ? p.surface : .clear)
            Capsule()
                .fill(wide ? p.muted : p.control)
                .frame(width: wide ? 8 : 4, height: thumbHeight)
                .offset(y: thumbTop)
                .opacity(visible ? 1 : 0)
        }
        .frame(width: 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            if dragStart == nil { dragStart = metrics.offset }
            let moved = drag.translation.height / travel * range
            position.scrollTo(y: min(max((dragStart ?? 0) + moved, 0), range))
        }.onEnded { _ in dragStart = nil })
        .animation(.easeOut(duration: 0.12), value: wide)
        .animation(.easeOut(duration: 0.2), value: visible)
    }

    private func flash() {
        active = true
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { active = false }
        }
    }
}

extension View {
    func themedScrollbar() -> some View { modifier(ThemedScrollbar()) }
}

// MARK: Right click

/// Catches a right click over a view, and lets every other event pass through.
private final class RightClickView: NSView {
    var onClick: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    let onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) { view.onClick = onClick }
}

private struct RightClickMenu<Menu: View>: ViewModifier {
    @ViewBuilder let menu: () -> Menu
    @Environment(FloatLayer.self) private var layer
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .floatFrame($frame)
            .overlay {
                RightClickCatcher { point in
                    let anchor = CGRect(x: frame.minX + point.x, y: frame.minY + point.y, width: 0, height: 0)
                    layer.show(at: anchor) { menu() }
                }
            }
    }
}

extension View {
    /// Opens an in-app menu on right click, at the pointer.
    func rightClickMenu(@ViewBuilder _ menu: @escaping () -> some View) -> some View {
        modifier(RightClickMenu(menu: menu))
    }
}
