import AppKit
import WebKit

// @lat: [[lat.md/architecture/ai#Account sign-in]]
@MainActor final class AIOAuthBrowser: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let anchor: NSWindow
    let panel: NSPanel
    let webView: WKWebView
    private(set) var popups: [(panel: NSPanel, webView: WKWebView)] = []
    private var callback: OAuthLoopback?
    private var redirect: URL?

    init(anchor: NSWindow, websiteDataStore: WKWebsiteDataStore = AppProfile.current.websiteDataStore) {
        self.anchor = anchor
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.applicationNameForUserAgent = PageController.websiteApplicationName
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        panel = OAuthPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        configure(panel, webView: webView)
    }

    func authenticate(url: URL, callback: OAuthLoopback, redirect: URL) async throws -> URL {
        try Task.checkCancellation()
        guard anchor.isVisible else { throw CancellationError() }
        self.callback = callback
        self.redirect = redirect
        let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: anchor, queue: .main) { _ in
            Task { @MainActor in callback.cancel() }
        }
        defer {
            self.callback = nil
            NotificationCenter.default.removeObserver(closing)
            for item in popups.reversed() { dismiss(item.panel, webView: item.webView) }
            popups.removeAll()
            dismiss(panel, webView: webView)
        }
        guard allowsNavigation(to: url) else { throw AIOAuthError.invalid("Invalid sign-in address.") }
        show(panel, above: anchor)
        webView.load(URLRequest(url: url))
        return try await callback.wait()
    }

    // Only the existing loopback listener can complete authorization. The web
    // view navigates to it normally, preserving all state and callback checks.
    func allowsNavigation(to url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        if url.scheme == "https", url.host != nil { return true }
        if url.absoluteString == "about:blank" { return true }
        guard let redirect else { return false }
        return url.scheme == "http" && url.host == "127.0.0.1" && url.host == redirect.host
            && url.port == redirect.port && url.path == redirect.path
    }

    private func configure(_ panel: NSPanel, webView: WKWebView) {
        panel.title = "Sign in to Bend"
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 420, height: 480)
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.delegate = self
        panel.contentView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private func show(_ panel: NSPanel, above parent: NSWindow) {
        let visible = parent.screen?.visibleFrame ?? parent.frame
        var frame = panel.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(parent.frame.midX - frame.width / 2, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(parent.frame.midY - frame.height / 2, visible.maxY - frame.height))
        panel.setFrame(frame, display: false)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    private func dismiss(_ panel: NSPanel, webView: WKWebView) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === panel { callback?.cancel() }
        else if let index = popups.firstIndex(where: { $0.panel === window }) {
            let popup = popups.remove(at: index)
            dismiss(popup.panel, webView: popup.webView)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url.map(allowsNavigation(to:)) == true ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        if let url = webView.url, let host = url.host {
            webView.window?.title = "Sign in — \(host)"
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard callback != nil, popups.count < 3, let url = navigationAction.request.url,
              allowsNavigation(to: url) else { return nil }
        let view = WKWebView(frame: .zero, configuration: configuration)
        let popup = OAuthPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        configure(popup, webView: view)
        popups.append((popup, view))
        show(popup, above: panel)
        return view
    }

    func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        callback?.cancel(with: AIOAuthError.invalid("Could not load the sign-in page. Check your connection and try again."))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        callback?.cancel(with: AIOAuthError.invalid("The sign-in page stopped responding. Try again."))
    }
}

private final class OAuthPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": performClose(nil); return true
            case "[": (contentView as? WKWebView)?.goBack(); return true
            case "r": (contentView as? WKWebView)?.reload(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
