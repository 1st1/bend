import AppKit
import WebKit

/// Extension-owned pages need their context's configuration, not a normal page's web view.
@available(macOS 15.4, *)
@MainActor
final class ExtensionDocument: NSObject, WKWebExtensionTab, WKWebExtensionWindow, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    weak var manager: ExtensionManager?
    let context: WKWebExtensionContext
    let web: WKWebView
    let nativeWindow: NSWindow

    init(manager: ExtensionManager, context: WKWebExtensionContext, configuration: WKWebViewConfiguration) {
        self.manager = manager; self.context = context
        web = WKWebView(frame: .zero, configuration: configuration)
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
        nativeWindow.makeKeyAndOrderFront(nil); completionHandler(nil)
    }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        focus(for: context, completionHandler: completionHandler)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        nativeWindow.close(); completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if url.scheme == self.context.baseURL.scheme, url.host == self.context.baseURL.host {
            web.load(URLRequest(url: url)); completionHandler(nil)
        } else if ["http", "https"].contains(url.scheme ?? "") {
            manager?.store?.newTab(address: url.absoluteString); completionHandler(nil)
        } else { completionHandler(manager?.failure("The extension cannot navigate to this URL.")) }
    }
    func windowWillClose(_ notification: Notification) {
        manager?.controller.didCloseTab(self, windowIsClosing: true)
        manager?.controller.didCloseWindow(self)
        web.stopLoading()
        manager?.documents[id] = nil
    }
    func windowDidBecomeKey(_ notification: Notification) { manager?.controller.didFocusWindow(self) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        manager?.controller.didChangeTabProperties([.URL, .title, .loading], for: self)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
            decisionHandler(.allow)
        } else {
            if action.targetFrame?.isMainFrame != false, ["http", "https"].contains(url.scheme ?? "") {
                manager?.store?.newTab(address: url.absoluteString)
            }
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
            do { _ = try manager?.openDocument(url: url, context: context) }
            catch { manager?.error = error.localizedDescription }
        } else if ["http", "https"].contains(url.scheme ?? "") { manager?.store?.newTab(address: url.absoluteString) }
        return nil
    }
}
