import AppKit
import WebKit

@available(macOS 15.4, *)
@MainActor final class ProbeTab: NSObject, WKWebExtensionTab, WKWebExtensionWindow {
    let web: WKWebView
    init(configuration: WKWebViewConfiguration) { web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration) }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [self] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { self }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func url(for context: WKWebExtensionContext) -> URL? { web.url }
    func title(for context: WKWebExtensionContext) -> String? { web.title }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !web.isLoading }
    func frame(for context: WKWebExtensionContext) -> CGRect { web.frame }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { web.frame }
}

@available(macOS 15.4, *)
// @lat: [[lat.md/architecture/extensions/diagnostics#Extension runtime diagnostics]]
@MainActor final class RuntimeProbe: NSObject, WKScriptMessageHandler, WKWebExtensionControllerDelegate {
    var controller: WKWebExtensionController!
    var context: WKWebExtensionContext!
    var views: [WKWebView] = []
    var tabs: [ProbeTab] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("PAGE", message.body)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] { tabs }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { tabs.last }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        print("OPEN_TAB", configuration.url?.absoluteString ?? "nil")
        if let url = configuration.url, url.scheme == context.baseURL.scheme, url.host == context.baseURL.host,
            let webConfiguration = context.webViewConfiguration {
            let tab = ProbeTab(configuration: webConfiguration)
            tabs.append(tab)
            controller.didOpenWindow(tab)
            controller.didOpenTab(tab)
            tab.web.load(URLRequest(url: url))
            completionHandler(tab, nil)
            return
        }
        completionHandler(nil, NSError(domain: "BrowseProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Windowless probe does not open tabs."]))
    }

    func run(source: URL) async throws {
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let webConfiguration = WKWebViewConfiguration()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        webConfiguration.websiteDataStore = dataStore
        configuration.defaultWebsiteDataStore = dataStore
        if ProcessInfo.processInfo.environment["BROWSE_PROBE_NOTIFICATIONS"] == "1" {
            print("NOTIFICATIONS_FEATURE", enableProbeFeature(webConfiguration.preferences, "WebExtensionNotificationsEnabled"))
        }
        let content = webConfiguration.userContentController
        content.add(self, name: "probe")
        if let path = ProcessInfo.processInfo.environment["BROWSE_PROBE_SCRIPT"] {
            print("DIAGNOSTIC_SCRIPT", path, "(results do not establish unmodified-package compatibility)")
            content.addUserScript(WKUserScript(source: try String(contentsOfFile: path, encoding: .utf8), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        content.addUserScript(WKUserScript(source: #"""
            (() => {
                const report = (kind, message) => window.webkit.messageHandlers.probe.postMessage({kind, path: location.pathname, message: String(message).slice(0, 1800)});
                window.addEventListener('error', event => report('error', event.message + ' @ ' + event.filename + ':' + event.lineno));
                window.addEventListener('unhandledrejection', event => report('rejection', String(event.reason) + '\n' + (event.reason?.stack || '')));
                for (const level of ['info', 'warn', 'error']) {
                    const original = console[level].bind(console);
                    console[level] = (...args) => {
                        report(level, args.map(value => typeof value === 'string' ? value : value instanceof Error ? value.message : '[' + typeof value + ']').join(' '));
                        return original(...args);
                    };
                }
                document.addEventListener('DOMContentLoaded', () => report('apis', JSON.stringify({
                    notifications: typeof chrome?.notifications,
                    navigationTarget: typeof chrome?.webNavigation?.onCreatedNavigationTarget
                })));
            })();
            """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.webViewConfiguration = webConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        let pageConfiguration = WKWebViewConfiguration()
        pageConfiguration.webExtensionController = controller
        pageConfiguration.websiteDataStore = dataStore
        let tab = ProbeTab(configuration: pageConfiguration)
        tabs.append(tab)
        tab.web.loadHTMLString("<title>Browse probe</title><body>Isolated extension probe</body>", baseURL: URL(string: "https://probe.invalid/"))
        controller.didOpenWindow(tab)
        controller.didOpenTab(tab)
        controller.didFocusWindow(tab)
        controller.didActivateTab(tab, previousActiveTab: nil)
        let ext = try await WKWebExtension(resourceBaseURL: source)
        print("PACKAGE", ext.displayName ?? "?", ext.version ?? "?")
        context = WKWebExtensionContext(for: ext)
        // The probe owns only this ephemeral data store. WebKit treats it as
        // private browsing, so event delivery needs explicit private access.
        context.hasAccessToPrivateData = true
        context.uniqueIdentifier = UUID().uuidString
        for permission in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in ext.requestedPermissionMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        try controller.load(context)
        defer { try? controller.unload(context) }
        try await context.loadBackgroundContent()
        try await Task.sleep(for: .seconds(25))
        if let background = probeBackgroundView(context) {
            print("BACKGROUND_STATE", try await background.callAsyncJavaScript(#"""
                chrome.browserAction.onClicked.addListener(() => window.webkit.messageHandlers.probe.postMessage('ACTION_RECEIVED'));
                browser.browserAction.onClicked.addListener(() => window.webkit.messageHandlers.probe.postMessage('BROWSER_ACTION_RECEIVED'));
                return JSON.stringify({sameNamespace: chrome === browser, tabs: await browser.tabs.query({}), windows: await browser.windows.getAll()});
                """#, arguments: [:], in: nil, contentWorld: .page) ?? "nil")
        }
        print("ACTION_ENABLED", context.action(for: tab)?.isEnabled ?? false)
        context.userGesturePerformed(in: tab)
        context.performAction(for: tab)
        try await Task.sleep(for: .seconds(5))
        if let path = ProcessInfo.processInfo.environment["BROWSE_PROBE_PAGE"],
            let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL,
            url.scheme == context.baseURL.scheme, url.host == context.baseURL.host,
            let configuration = context.webViewConfiguration {
            let page = ProbeTab(configuration: configuration)
            tabs.append(page)
            controller.didOpenWindow(page)
            controller.didOpenTab(page)
            page.web.load(URLRequest(url: url))
            print("DIRECT_PAGE", path)
            try await Task.sleep(for: .seconds(5))
        }
        print("CONTEXT_ERRORS", context.errors.map(\.localizedDescription))
        for tab in tabs.dropFirst() {
            print("EXTENSION_TAB", try await tab.web.evaluateJavaScript("document.body.innerText.slice(0, 1500)") ?? "nil")
        }
        if let action = context.action(for: tab), action.presentsPopup, let popup = action.popupWebView {
            views.append(popup)
            try await Task.sleep(for: .seconds(5))
            print("POPUP", try await popup.evaluateJavaScript("document.body.innerText.slice(0, 1500)") ?? "nil")
        } else { print("POPUP_NOT_CONFIGURED") }
    }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
if #available(macOS 15.4, *), CommandLine.arguments.count == 2 {
    Task { @MainActor in
        let probe = RuntimeProbe()
        do { try await probe.run(source: URL(fileURLWithPath: CommandLine.arguments[1])); exit(0) }
        catch { print("PROBE_ERROR", error); exit(1) }
    }
    // Bound hangs even if a WebKit callback never arrives.
    DispatchQueue.main.asyncAfter(deadline: .now() + 45) { print("PROBE_TIMEOUT"); exit(2) }
    NSApp.run()
} else {
    print("usage: BrowseRuntimeProbe unpacked-extension-path (macOS 15.4+)")
    exit(2)
}
