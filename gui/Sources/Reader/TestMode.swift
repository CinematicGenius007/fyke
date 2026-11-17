import AppKit
import ObjectiveC

// The checks in tools/e2e_gui.py drive the app through environment variables:
//
//   FYKE_SCREEN    opens one screen at launch (AppModel.openRequestedScreen)
//   FYKE_KEYS      plays key presses and clicks, then quits
//   FYKE_SNAPSHOT  saves a picture of a window, then quits
//   FYKE_HEADLESS  runs all of that without the person at this Mac noticing
//
// Headless is what lets the checks run while someone works. The app's activation policy
// is `.prohibited`, so it can never become the active app and focus stays where it was;
// it has no Dock icon and no place in ⌘-Tab. A prohibited app's windows are created but
// never ordered in, and SwiftUI only lays out and draws a window that is on screen, so
// the app orders each one in itself. They are fully transparent and let clicks fall
// through to whatever is below. Pictures still come out right, because they are drawn from the view tree, not
// read back from the screen. Events are handed to the window directly, in process, so
// they need neither key-window status nor any system permission.

/// The test mode this run asked for.
@MainActor enum TestMode {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let headless = environment["FYKE_HEADLESS"] != nil
    /// Checks click at window coordinates and compare pictures, so they need the default
    /// size, not the frame the window last had on this Mac.
    static let driven = environment["FYKE_KEYS"] != nil || environment["FYKE_SNAPSHOT"] != nil
    static let screen = environment["FYKE_SCREEN"]

    /// Runs before any window exists, so that none is ever shown visibly.
    static func prepare() {
        guard headless else { return }
        // A prohibited app cannot be activated at all, so nothing it does can take focus
        // from the app in front.
        NSApp.setActivationPolicy(.prohibited)
        HiddenWindows.install()
        // Activation should be impossible. If a later macOS allows it, the check fails
        // loudly instead of quietly taking over the screen.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            FileHandle.standardError.write(Data("FYKE_HEADLESS: the app became active\n".utf8))
            exit(3)
        }
    }

    static func start() {
        if headless { HiddenWindows.revealEachOnce() }
        if driven {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.isVisible && window.frame.width >= 960 {
                    window.setContentSize(NSSize(width: 1440, height: 900))
                }
            }
        }
        KeyReplay.startIfRequested()
        guard let path = environment["FYKE_SNAPSHOT"] else { return }
        // With keys to play, the replay calls `snapshot` once its last key is sent.
        if environment["FYKE_KEYS"] == nil { Launch.whenReady { snapshot(to: path) } }
    }

    static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.width >= 960 } }

    /// The window that keys, clicks and the picture go to. Every screen, Settings too, is
    /// in the main window. Key-window status cannot decide, because a headless app has no
    /// key window.
    static var target: NSWindow? { mainWindow }

    /// Saves the window after `FYKE_SNAPSHOT_DELAY` seconds, for screens that are still
    /// loading or animating once the app is ready. `FYKE_SNAPSHOT_CHROME` takes the frame
    /// around the content too, which holds the window buttons.
    static func snapshot(to path: String) {
        let delay = Double(environment["FYKE_SNAPSHOT_DELAY"] ?? "") ?? 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let chrome = environment["FYKE_SNAPSHOT_CHROME"] != nil
            guard let window = target,
                let view = chrome ? window.contentView?.superview : window.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            exit(0)
        }
    }
}

/// Makes every window transparent and click-through at the moment it is ordered in,
/// before the window server first composites it, so there is no frame in which it shows.
/// Every way of showing a window, `makeKeyAndOrderFront`, `orderFront`,
/// `orderFrontRegardless` and SwiftUI's own, passes through `orderWindow(_:relativeTo:)`,
/// so replacing that one method covers them all.
@MainActor private enum HiddenWindows {
    private static var revealed = Set<ObjectIdentifier>()

    /// Orders in, once each, the titled windows SwiftUI made but the activation policy
    /// kept off screen, such as the main window at launch. A window that later closes
    /// stays closed. Panels, popovers and menus are left to
    /// show themselves, and sheets are not attached, which is a limit of headless runs.
    static func revealEachOnce() {
        for window in NSApp.windows where !window.isVisible && window.styleMask.contains(.titled) && window.sheetParent == nil && !(window is NSPanel) {
            guard revealed.insert(ObjectIdentifier(window)).inserted else { continue }
            window.orderFrontRegardless()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { revealEachOnce() }
    }

    static func install() {
        guard let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:))),
            let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.fyke_hiddenOrder(_:relativeTo:)))
        else { return }
        method_exchangeImplementations(original, hidden)
    }
}

extension NSWindow {

    /// Swapped with `order(_:relativeTo:)` by `HiddenWindows`, so calling itself calls
    /// the original.
    @objc fileprivate func fyke_hiddenOrder(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out {
            alphaValue = 0
            ignoresMouseEvents = true
            hasShadow = false
            // Kept out of Mission Control and the window cycle.
            collectionBehavior.formUnion([.transient, .ignoresCycle])
        }
        fyke_hiddenOrder(place, relativeTo: other)
    }
}

/// Waits for the first load to finish, then for the window to lay out and draw.
/// Checks start from here, not from a fixed delay, because a cold start after a
/// rebuild can take several seconds longer than a warm one.
@MainActor enum Launch {
    private static let limit = Date.now.addingTimeInterval(60)
    /// Time for the window to lay out and for focus to land after the first load.
    private static let settleSeconds = 0.5

    static func whenReady(_ run: @escaping @MainActor () -> Void) {
        let window = TestMode.mainWindow
        if AppModel.launched && window != nil || Date.now > limit {
            // A visible run brings the window forward, as a person would. A headless run
            // leaves focus where it is.
            if !TestMode.headless {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) { run() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenReady(run) }
    }
}

/// `FYKE_KEYS` plays key presses into the window once it settles, then quits, for
/// tools/e2e_gui.py. Steps are separated by spaces: `cmd+K` or `shift+cmd+K` for any
/// letter or digit K, `up`, `down`, `left`, `right`, `tab`, `space`, `return`, `esc`, `wait`,
/// `click:X,Y`, `rclick:X,Y`, `drag:X1,Y1,X2,Y2`, or text to type. Coordinates count from the
/// window's top left. Each event names its window and goes through `NSApp.sendEvent` or the
/// event queue, which route it by that window, so the same path real events take inside
/// the app is used, and the window needs no key status.
@MainActor private enum KeyReplay {
    private static let stepSeconds = 0.5

    static func startIfRequested() {
        guard let script = TestMode.environment["FYKE_KEYS"] else { return }
        let steps = script.split(separator: " ").map(String.init)
        Launch.whenReady { play(steps[...]) }
    }

    private static func play(_ steps: ArraySlice<String>) {
        // With a snapshot requested, that is what ends the run.
        guard let step = steps.first else {
            if let path = TestMode.environment["FYKE_SNAPSHOT"] { TestMode.snapshot(to: path) } else { exit(0) }
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
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "n": 45, "m": 46,
    ]

    /// A prohibited app never has a key window, and AppKit treats a mouse-down in a window
    /// that is not key as the click that would activate it: the view under the pointer
    /// gets it only if it accepts the first mouse. SwiftUI's views decline, so in a
    /// headless run the class of the view under each synthetic press is made to accept.
    private static func acceptFirstMouse(in window: NSWindow, at point: NSPoint) {
        guard TestMode.headless, let content = window.contentView, let view = content.hitTest(point) else { return }
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        guard let method = class_getInstanceMethod(type(of: view), selector) else { return }
        let accept: @convention(block) (AnyObject, NSEvent?) -> Bool = { _, _ in true }
        class_replaceMethod(type(of: view), selector, imp_implementationWithBlock(accept), method_getTypeEncoding(method))
    }

    /// Posted, not sent, so that they pass through the event queue and become
    /// `NSApp.currentEvent`, as real clicks do.
    private static func mouse(_ point: Substring, down: NSEvent.EventType, up: NSEvent.EventType) {
        let parts = point.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let window = TestMode.target, let height = window.contentView?.bounds.height else { return }
        acceptFirstMouse(in: window, at: NSPoint(x: parts[0], y: height - parts[1]))
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
        guard p.count == 4, let window = TestMode.target, let height = window.contentView?.bounds.height else { return }
        acceptFirstMouse(in: window, at: NSPoint(x: p[0], y: height - p[1]))
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
                windowNumber: TestMode.target?.windowNumber ?? 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
            if let event { NSApp.sendEvent(event) }
        }
    }
}

