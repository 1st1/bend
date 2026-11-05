import AppKit
import WebKit

/// Extension-owned pages need their context's configuration, not a normal page's web view.
@available(macOS 15.4, *)
@MainActor
final class ExtensionDocument: NSObject, WKWebExtensionTab, WKWebExtensionWindow, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    weak var manager: ExtensionManager?
    let context: WKWebExtensionContext
    private(set) var web: WKWebView
    private let extensionWeb: WKWebView
    private var websiteWeb: WKWebView?
    let nativeWindow: NSWindow
    private var permittedExtensionNavigation: URL?

    init(manager: ExtensionManager, context: WKWebExtensionContext, configuration: WKWebViewConfiguration) {
        self.manager = manager; self.context = context
        let view = WKWebView(frame: .zero, configuration: configuration)
        web = view; extensionWeb = view
        nativeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        nativeWindow.title = context.webExtension.displayName ?? "Extension"
        nativeWindow.isReleasedWhenClosed = false
        nativeWindow.contentView = web
        nativeWindow.delegate = self
        web.navigationDelegate = self; web.uiDelegate = self
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [self] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { self }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func frame(for context: WKWebExtensionContext) -> CGRect { nativeWindow.frame }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nativeWindow.screen?.frame ?? .zero }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        InputDiagnostics.transition(.extensionWindowFocus, .requested, view: web, window: nativeWindow)
        nativeWindow.makeKeyAndOrderFront(nil); completionHandler(nil)
    }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        focus(for: context, completionHandler: completionHandler)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        InputDiagnostics.transition(.windowClose, .requested, view: web, window: nativeWindow)
        nativeWindow.close(); completionHandler(nil)
    }
    func navigate(to url: URL) {
        let isExtension = url.scheme == context.baseURL.scheme && url.host == context.baseURL.host
        let destination: WKWebView
        if isExtension { destination = extensionWeb }
        else {
            guard ["http", "https"].contains(url.scheme ?? "") else { return }
            if websiteWeb == nil {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = extensionWeb.configuration.websiteDataStore
                manager?.configure(configuration)
                let view = WKWebView(frame: web.frame, configuration: configuration)
                view.navigationDelegate = self; view.uiDelegate = self
                websiteWeb = view
            }
            destination = websiteWeb!
        }
        if web !== destination {
            web.stopLoading()
            web = destination
            nativeWindow.contentView = web
        }
        permittedExtensionNavigation = isExtension ? url : nil
        web.load(URLRequest(url: url))
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if url.scheme == self.context.baseURL.scheme, url.host == self.context.baseURL.host {
            guard context === self.context else { completionHandler(manager?.failure("The extension cannot navigate to this URL.")); return }
            navigate(to: url); completionHandler(nil)
        } else if ["http", "https"].contains(url.scheme ?? "") {
            navigate(to: url); completionHandler(nil)
        } else { completionHandler(manager?.failure("The extension cannot navigate to this URL.")) }
    }
    func windowWillClose(_ notification: Notification) {
        manager?.controller.didCloseTab(self, windowIsClosing: true)
        manager?.controller.didCloseWindow(self)
        extensionWeb.stopLoading(); websiteWeb?.stopLoading()
        manager?.documents[id] = nil
    }
    func windowDidBecomeKey(_ notification: Notification) { manager?.controller.didFocusWindow(self) }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === web else { return }
        nativeWindow.title = webView.url?.scheme == context.baseURL.scheme
            ? (context.webExtension.displayName ?? "Extension") : (webView.url?.host ?? "Web page")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        manager?.controller.didChangeTabProperties([.URL, .title, .loading], for: self)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
            let source = action.sourceFrame.securityOrigin
            guard (source.protocol == context.baseURL.scheme && source.host == context.baseURL.host)
                    || permittedExtensionNavigation == url else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame != false { permittedExtensionNavigation = nil }
            decisionHandler(.allow)
        } else if ["http", "https"].contains(url.scheme ?? "") {
            // Extension-configured WKWebViews cannot leave their required origin.
            // Retain that view's sessionStorage while this same tab visits the web.
            if webView === extensionWeb, action.targetFrame?.isMainFrame == true {
                decisionHandler(.cancel)
                navigate(to: url)
                return
            }
            if action.targetFrame?.isMainFrame != false { permittedExtensionNavigation = nil }
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
            let source = action.sourceFrame.securityOrigin
            guard source.protocol == context.baseURL.scheme, source.host == context.baseURL.host else { return nil }
            do { _ = try manager?.openDocument(url: url, context: context) }
            catch { manager?.error = error.localizedDescription }
        } else if ["http", "https"].contains(url.scheme ?? "") { manager?.store?.newTab(address: url.absoluteString) }
        return nil
    }
}
