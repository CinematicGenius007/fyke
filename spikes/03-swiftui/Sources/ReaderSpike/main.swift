// Spike: SwiftUI client of the socket API. Pages 10,000 rows into a List.
// Usage: ReaderSpike <socket-path> [--bench | --scroll <png-path>]
//   --bench loads everything headlessly and prints timing, then exits.
//   --scroll opens the window, scrolls the list top to bottom on the display
//   link, prints frame timing, saves a snapshot, then exits.
import AppKit
import Foundation
import QuartzCore
import SwiftUI

struct Entry: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let feed: String
}

struct Page: Decodable, Sendable {
    let next: Int
    let items: [Entry]
}

struct Reply: Decodable, Sendable {
    let id: Int
    let result: Page
}

/// One blocking Unix-socket connection speaking newline-delimited JSON-RPC.
final class Connection: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()
    private var nextId = 1

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
    }

    func list(after: Int, limit: Int) throws -> Page {
        let id = nextId
        nextId += 1
        let request = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"entries.list\",\"params\":{\"after\":\(after),\"limit\":\(limit)}}\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        return try JSONDecoder().decode(Reply.self, from: readLine()).result
    }

    private func readLine() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw POSIXError(.ECONNRESET) }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var status = "Loading"

    func load(path: String) {
        Task.detached {
            do {
                let connection = try Connection(path: path)
                var after = 0
                while after < 10_000 {
                    let page = try connection.list(after: after, limit: 500)
                    after = page.next
                    await MainActor.run {
                        self.entries.append(contentsOf: page.items)
                        self.status = "\(self.entries.count) entries"
                    }
                }
            } catch {
                await MainActor.run { self.status = "Error: \(error)" }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    let path: String

    var body: some View {
        List(model.entries) { entry in
            VStack(alignment: .leading) {
                Text(entry.title)
                Text(entry.feed).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.status)
        .frame(minWidth: 500, minHeight: 600)
        .onAppear { model.load(path: path) }
    }
}

/// Drives the real List's scroll view once per display frame and records frame gaps.
@MainActor
final class ScrollProbe: NSObject {
    let snapshotPath: String
    private var link: CADisplayLink?
    private var scroller: NSScrollView?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var offset: CGFloat = 0

    init(snapshotPath: String) { self.snapshotPath = snapshotPath }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self.begin() } }
    }

    private func findScroller(_ view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, (s.documentView?.frame.height ?? 0) > 100_000 { return s }
        for child in view.subviews { if let s = findScroller(child) { return s } }
        return nil
    }

    private func begin() {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }),
              let content = window.contentView, let s = findScroller(content) else {
            func dump(_ v: NSView, _ d: Int) {
                let extra = (v as? NSScrollView).map { " doc=\($0.documentView?.frame.height ?? -1)" } ?? ""
                if d < 12 { print(String(repeating: " ", count: d) + String(describing: type(of: v)) + " \(v.frame.size)" + extra) }
                v.subviews.prefix(4).forEach { dump($0, d + 1) }
            }
            print("windows \(NSApp.windows.count)")
            NSApp.windows.compactMap(\.contentView).forEach { dump($0, 0) }
            print("no large scroll view found"); exit(1)
        }
        print("document height \(s.documentView!.frame.height) screen \(window.screen?.maximumFramesPerSecond ?? 0) fps")
        scroller = s
        link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last != 0 { gaps.append((link.timestamp - last) * 1000) }
        last = link.timestamp
        guard let s = scroller, let doc = s.documentView else { return }
        offset += 400 // far faster than a real flick, so every frame lays out new rows
        s.contentView.scroll(to: NSPoint(x: 0, y: offset))
        s.reflectScrolledClipView(s.contentView)
        if offset >= doc.frame.height - s.contentView.bounds.height || gaps.count >= 1200 { finish(s) }
    }

    private func finish(_ s: NSScrollView) {
        link?.invalidate()
        let sorted = gaps.sorted()
        let budget = 1000.0 / Double(NSApp.windows.first?.screen?.maximumFramesPerSecond ?? 60)
        let dropped = gaps.filter { $0 > budget * 1.5 }.count
        print(String(format: "frames %d  p50 %.2f ms  p95 %.2f ms  p99 %.2f ms  max %.2f ms  over 1.5x budget: %d",
                     sorted.count, sorted[sorted.count / 2], sorted[sorted.count * 95 / 100],
                     sorted[sorted.count * 99 / 100], sorted.last!, dropped))
        if let view = NSApp.windows.first?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshotPath))
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("peak rss \(usage.ru_maxrss / 1024 / 1024) MB")
        exit(0)
    }
}

/// Hosts the SwiftUI view in a plain window: a bare executable has no bundle,
/// and the SwiftUI App lifecycle opened no window without one.
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var probe: ScrollProbe?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 800),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: ContentView(path: CommandLine.arguments[1]))
            w.makeKeyAndOrderFront(nil)
            window = w
            if let i = CommandLine.arguments.firstIndex(of: "--scroll") {
                probe = ScrollProbe(snapshotPath: CommandLine.arguments[i + 1])
                probe?.start()
            }
        }
    }
}

func bench(path: String) throws {
    let connection = try Connection(path: path)
    let clock = ContinuousClock()
    var rows = 0
    var after = 0
    var pages: [Duration] = []
    let total = try clock.measure {
        while after < 10_000 {
            let start = clock.now
            let page = try connection.list(after: after, limit: 50)
            pages.append(clock.now - start)
            rows += page.items.count
            after = page.next
        }
    }
    pages.sort()
    print("rows \(rows) pages \(pages.count) total \(total) p50 \(pages[pages.count / 2]) p95 \(pages[pages.count * 95 / 100]) max \(pages.last!)")
}

if CommandLine.arguments.contains("--bench") {
    try bench(path: CommandLine.arguments[1])
} else {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate()
    app.run()
}
