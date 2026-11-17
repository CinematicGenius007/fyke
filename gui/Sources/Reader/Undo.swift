// Bulk and destructive actions happen at once and offer Undo, instead of asking first.
// Each one leaves a way back on this stack; ⌘Z and the toast's button take it.
import Observation
import ReaderLogic
import SwiftUI

@MainActor @Observable
final class UndoCenter {
    struct Item: Identifiable {
        let id = UUID()
        let message: String
        let undo: @MainActor () async -> Void
    }

    private(set) var stack = UndoStack<Item>()
    /// The toast on screen, if any. It names the newest change.
    private(set) var toast: Item?
    private var hide: Task<Void, Never>?

    static let toastSeconds = 6.0

    func push(_ message: String, undo: @escaping @MainActor () async -> Void) {
        let item = Item(message: message, undo: undo)
        stack.push(item)
        show(item)
    }

    var canUndo: Bool { !stack.isEmpty }

    func undoLast() {
        guard let item = stack.pop() else { return }
        if toast?.id == item.id { dismiss() }
        Task { await item.undo() }
    }

    func dismiss() {
        hide?.cancel()
        toast = nil
    }

    private func show(_ item: Item) {
        toast = item
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            if !Task.isCancelled, toast?.id == item.id { toast = nil }
        }
    }
}

/// "Marked 12 articles as read · Undo ⌘Z", at the foot of the window.
struct UndoToast: View {
    let item: UndoCenter.Item
    let center: UndoCenter
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            Text(item.message).font(.ui(14)).foregroundStyle(p.ground).lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") { center.undoLast() }
                .buttonStyle(ToastButton())
                .accessibilityHint("Takes back: \(item.message)")
            KeyHint(text: "⌘Z", onDark: true)
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: Metrics.panelHeader)
        .frame(minWidth: 360, maxWidth: 480)
        .background(p.ink, in: RoundedRectangle(cornerRadius: Radii.panel))
        .shadow(color: .black.opacity(0x1F / 255), radius: 16, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.message)
    }
}

private struct ToastButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ToastBody(configuration: configuration) }

    struct ToastBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.palette) private var p
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.ui(14, .medium)).foregroundStyle(p.ground)
                .padding(.horizontal, 10).frame(height: Metrics.compactControl)
                .background(p.ground.opacity(configuration.isPressed ? 0.28 : hovering ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: Radii.control))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .interactiveCursor()
                .motion(hovering, Motion.quick)
        }
    }
}
