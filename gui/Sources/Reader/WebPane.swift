// Shows a remote page in place of the reader. The page is the same one a browser
// would show. Feed HTML never comes through here: only an http(s) address does.
// See docs/decisions/0002-web-viewer.md.
import SwiftUI
import WebKit

enum WebGuard {
    /// The address of a page must not reach this Mac or its network. The check reads
    /// the host name only, so a public name resolving to a private address gets past
    /// it, which the daemon's fetcher can prevent and WebKit gives no way to.
    static func isPrivateHost(_ host: String) -> Bool {
        var name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // `localhost.` is the same host, written as fully qualified.
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        if name.contains(":") {
            return name == "::" || name == "::1" || name.hasPrefix("::ffff:")
                || ["fc", "fd", "fe8", "fe9", "fea", "feb"].contains { name.hasPrefix($0) }
        }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 127 || parts[0] == 10 || parts[0] == 0 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254) || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 100 && (64...127).contains(parts[1]))
    }

    /// The same rule as `isPrivateHost`, for what a page loads: images, scripts and
    /// requests. Content rule patterns have no alternation, so each range is a pattern.
    /// Each ends where the host ends, so `0.example.com` is not mistaken for `0.0.0.0`.
    private static let privateHosts = [
        #"localhost"#, #"[^/]*\.localhost"#, #"[^/]*\.local"#,
        #"127\.[0-9.]*"#, #"10\.[0-9.]*"#, #"0\.[0-9.]*"#, #"192\.168\.[0-9.]*"#, #"169\.254\.[0-9.]*"#,
        #"172\.1[6-9]\.[0-9.]*"#, #"172\.2[0-9]\.[0-9.]*"#, #"172\.3[01]\.[0-9.]*"#,
        #"100\.6[4-9]\.[0-9.]*"#, #"100\.[7-9][0-9]\.[0-9.]*"#, #"100\.1[01][0-9]\.[0-9.]*"#, #"100\.12[0-7]\.[0-9.]*"#,
        #"\[::1?\]"#, #"\[::ffff:[^/]*"#, #"\[f[cd][^/]*"#, #"\[fe[89ab][^/]*"#,
    ]

    static var blockRules: String {
        let rules = [#"^https?://"#, #"^wss?://"#].flatMap { scheme in
            privateHosts.map { host in
                let pattern = (scheme + #"([^/]*@)?"# + host + #"\.?[:/?#]"#).replacingOccurrences(of: #"\"#, with: #"\\"#)
                return #"{"trigger":{"url-filter":"\#(pattern)"},"action":{"type":"block"}}"#
            }
        }
        return "[" + rules.joined(separator: ",") + "]"
    }
}

@MainActor @Observable
final class WebState {
    var address: URL
    var progress = 0.0
    var loading = true
    var canGoBack = false
    var canGoForward = false
    var failure: String?
    /// The address that failed, which is not where the page still sits.
    var failedAddress: URL?
    fileprivate(set) weak var view: WKWebView?

    init(address: URL) { self.address = address }

    func back() { view?.goBack() }
    func forward() { view?.goForward() }
    func reload() {
        let target = failedAddress
        clearFailure()
        if let target {
            view?.load(URLRequest(url: target))
        } else if view?.url == nil {
            view?.load(URLRequest(url: address))
        } else {
            view?.reload()
        }
    }

    func fail(_ text: String, at url: URL?) {
        failure = text
        failedAddress = url
    }

    func clearFailure() {
        failure = nil
        failedAddress = nil
    }

    /// What a browser should open: the page that would not load, if one did not.
    var browserAddress: URL { failedAddress ?? address }
}

final class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let state: WebState
    var observations: [NSKeyValueObservation] = []

    init(state: WebState) { self.state = state }

    func watch(_ view: WKWebView) {
        let state = state
        func follow<T>(_ path: KeyPath<WKWebView, T>, _ apply: @escaping @MainActor (WKWebView) -> Void) {
            observations.append(view.observe(path, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { apply(view) }
            })
        }
        follow(\.estimatedProgress) { state.progress = $0.estimatedProgress }
        follow(\.isLoading) { state.loading = $0.isLoading }
        follow(\.canGoBack) { state.canGoBack = $0.canGoBack }
        follow(\.canGoForward) { state.canGoForward = $0.canGoForward }
        follow(\.url) { view in if let url = view.url { state.address = url } }
    }

    /// A page chooses where its links go, so the rules hold on every step, not only
    /// the first. Anything else goes nowhere: `file:`, `javascript:`, app schemes.
    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == "about" && action.targetFrame?.isMainFrame == false { return .allow }
        guard Links.isSafe(url) else { return .cancel }
        if WebGuard.isPrivateHost(url.host() ?? "") {
            if action.targetFrame?.isMainFrame == true {
                await MainActor.run { state.fail("This page is on a private address, so it stays out of the app.", at: url) }
            }
            return .cancel
        }
        return .allow
    }

    /// Downloads and file types WebKit cannot show are refused here.
    func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.canShowMIMEType { return .allow }
        // One frame of a working page is no reason to cover the page.
        if response.isForMainFrame {
            let url = response.response.url
            await MainActor.run { state.fail("This address is a download, not a page.", at: url) }
        }
        return .cancel
    }

    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        MainActor.assumeIsolated { state.clearFailure() }
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        fail(error)
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        let failure = error as NSError
        // Code 102 is a load this class refused, which has already said why.
        guard failure.code != NSURLErrorCancelled, !(failure.domain == "WebKitErrorDomain" && failure.code == 102) else { return }
        let message = failure.localizedDescription
        let url = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        MainActor.assumeIsolated { state.fail(message, at: url) }
    }

    /// A new window would escape the pane, so a link asking for one opens here.
    func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { view.load(action.request) }
        return nil
    }

    func webView(_ view: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }
}

struct WebSurface: NSViewRepresentable {
    let state: WebState

    func makeCoordinator() -> WebCoordinator { WebCoordinator(state: state) }

    /// Each visit gets a store of its own, in memory, so nothing a site sets outlives
    /// the pane. No script message handler is installed, which leaves a page no path
    /// to the app or the daemon, and JavaScript stays on because most sites need it.
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.allowsAirPlayForMediaPlayback = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        state.view = view
        context.coordinator.watch(view)
        let address = state.address
        let state = state
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "private-addresses", encodedContentRuleList: WebGuard.blockRules) { list, _ in
            // Without the rules, a page could reach private addresses, so nothing loads.
            guard let list else {
                state.fail("The app could not set up its page protections.", at: address)
                return
            }
            view.configuration.userContentController.add(list)
            view.load(URLRequest(url: address))
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: WebCoordinator) {
        coordinator.observations = []
        view.stopLoading()
    }
}

struct WebPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let state: WebState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rule()
            ZStack(alignment: .top) {
                WebSurface(state: state).id(ObjectIdentifier(state))
                if let failure = state.failure { problem(failure) }
                if state.loading && state.failure == nil {
                    GeometryReader { proxy in
                        Rectangle().fill(p.unread).frame(width: proxy.size.width * state.progress, height: 2)
                    }
                    .frame(height: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { model.closeWeb() } label: {
                HStack(spacing: 6) {
                    Icon(glyph: .left, color: p.ink)
                    Text(model.article == nil ? "Back" : "Article").font(.ui(13, .medium)).foregroundStyle(p.ink)
                }
                .padding(.leading, 6).padding(.trailing, 10).frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            IconButton(glyph: .arrowLeft, help: "Previous page", enabled: state.canGoBack) { state.back() }
            IconButton(glyph: .arrowRight, help: "Next page", enabled: state.canGoForward) { state.forward() }
            address
            IconButton(glyph: .reload, help: "Reload") { state.reload() }
            IconButton(glyph: .globe, help: "Open in browser") { NSWorkspace.shared.open(state.browserAddress) }
        }
        .padding(.leading, 12).padding(.trailing, 16)
        .frame(height: 52)
        .background(p.ground)
    }

    private var address: some View {
        let host = state.address.host() ?? ""
        let path = String(state.address.absoluteString.split(separator: host, maxSplits: 1).last ?? "")
        return HStack(spacing: 7) {
            if state.address.scheme == "https" { Icon(glyph: .lock, size: 14, color: p.muted) }
            (Text(host).foregroundStyle(p.ink) + Text(path).foregroundStyle(p.muted))
                .font(.ui(13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(p.surface, in: RoundedRectangle(cornerRadius: Radii.control))
    }

    private func problem(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This page did not open").font(.ui(20, .semibold))
            Text(text).font(.ui(14)).foregroundStyle(p.inkSoft)
            HStack(spacing: 8) {
                Button("Try again") { state.reload() }.buttonStyle(Plain())
                Button("Open in browser") { NSWorkspace.shared.open(state.browserAddress) }.buttonStyle(Plain())
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(p.ground)
    }
}
