import WebKit

// @lat: [[lat.md/architecture/link-navigation#Option-click event routing]]
@MainActor
final class OptionClickObserver: NSObject, WKScriptMessageHandlerWithReply {
    static let world = WKContentWorld.world(name: "BendOptionClick")
    static let script = #"""
    (() => {
        // Extension documents can share a content controller with other views.
        // Only panes with native link routing should suppress WebKit's default.
        let enabled = false;
        window.webkit.messageHandlers.bendOptionClick.postMessage(null)
            .then(value => { enabled = value === true; }).catch(() => {});
        document.addEventListener('click', event => {
            if (!enabled || !event.isTrusted || event.defaultPrevented || event.button !== 0 ||
                !event.altKey || event.metaKey || event.ctrlKey) return;
            const link = event.composedPath().find(element =>
                element instanceof Element && element.matches('a[href], area[href]'));
            if (!link) return;
            let url;
            try { url = new URL(link.getAttribute('href'), link.baseURI); }
            catch { return; }
            if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
            // macOS 26 handles Option-click as a download before navigation
            // policy runs. Cancel that default synchronously in the document.
            event.preventDefault();
            window.webkit.messageHandlers.bendOptionClick.postMessage(url.href).catch(() => {});
        });
    })();
    """#

    static func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source == script }) else { return }
        controller.addScriptMessageHandler(OptionClickObserver(), contentWorld: world, name: "bendOptionClick")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let web = message.webView as? FocusWebView, let open = web.onOptionLink else {
            return (false, nil)
        }
        if message.body is NSNull { return (true, nil) }
        guard let address = message.body as? String, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return (false, nil)
        }
        open(url.absoluteString, message.frameInfo.isMainFrame)
        return (true, nil)
    }
}
