import AppKit
import Testing
import WebKit
@testable import Browse

@MainActor private final class DialogTestWindow: NSWindow {
    var acceptsDialogs = true
    override var isKeyWindow: Bool { acceptsDialogs }
}
@MainActor private final class DialogPresentation {
    var alerts: [NSAlert] = []
    var completions: [(NSApplication.ModalResponse) -> Void] = []
    var time = 100.0
    lazy var dialogs = JavaScriptDialogs(now: { [unowned self] in self.time }, present: { [unowned self] alert, _, completion in
        self.alerts.append(alert); self.completions.append(completion)
    })
}
@MainActor private final class DialogFrameProbe: NSObject, WKNavigationDelegate {
    var frame: WKFrameInfo?
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if !action.sourceFrame.isMainFrame, action.sourceFrame.securityOrigin.host == "child.example" {
            frame = action.sourceFrame
        }
        decisionHandler(.allow)
    }
}
@MainActor private func dialogFrame() async throws -> WKFrameInfo {
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: config)
    let probe = DialogFrameProbe(); web.navigationDelegate = probe
    web.loadHTMLString("<iframe srcdoc=\"<script>location.href='about:blank'</script>\"></iframe>",
                       baseURL: URL(string: "https://child.example:8443/"))
    for _ in 0..<100 where probe.frame == nil { try await Task.sleep(for: .milliseconds(20)) }
    web.stopLoading()
    return try #require(probe.frame)
}
@MainActor private func dialogWindow() -> DialogTestWindow {
    _ = NSApplication.shared
    let window = DialogTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    return window
}
@MainActor private func dialogPage(_ dialogs: JavaScriptDialogs, in window: NSWindow) -> PageController {
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = FocusWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
    let page = PageController(address: "browse://start", webView: web, javaScriptDialogs: dialogs)
    window.contentView = web
    return page
}

// @lat: [[lat.md/tests/web-pages-tests#JavaScript dialog origin and responses]]
@Test @MainActor func javaScriptDialogOriginAndResponses() async throws {
    let presentation = DialogPresentation()
    let window = dialogWindow(); defer { window.close() }
    let page = dialogPage(presentation.dialogs, in: window)
    let frame = try await dialogFrame()
    var alerts = 0
    page.webView(page.webView, runJavaScriptAlertPanelWithMessage: "Untrusted text", initiatedByFrame: frame) { alerts += 1 }
    let alert = try #require(presentation.alerts.last)
    #expect(alert.messageText == "JavaScript from https://child.example:8443")
    #expect(alert.informativeText == "Untrusted text")
    #expect(alerts == 0)
    presentation.completions.last?(.alertFirstButtonReturn)
    #expect(alerts == 1)
    var confirmed: Bool?
    page.webView(page.webView, runJavaScriptConfirmPanelWithMessage: "Proceed?", initiatedByFrame: frame) { confirmed = $0 }
    presentation.completions.last?(.alertSecondButtonReturn)
    #expect(confirmed == false)
    var answer: String?
    page.webView(page.webView, runJavaScriptTextInputPanelWithPrompt: "Enter text", defaultText: "Initial", initiatedByFrame: frame) { answer = $0 }
    let prompt = try #require(presentation.alerts.last)
    #expect(prompt.messageText == "JavaScript from https://child.example:8443")
    let field = try #require(prompt.accessoryView as? NSTextField)
    #expect(field.stringValue == "Initial")
    field.stringValue = "Synthetic response"
    presentation.completions.last?(.alertFirstButtonReturn)
    #expect(answer == "Synthetic response")
    #expect(JavaScriptDialogs.originLabel(scheme: "https", host: "example.com", port: 443) == "https://example.com")
    #expect(JavaScriptDialogs.originLabel(scheme: "http", host: "::1", port: 8000) == "http://[::1]:8000")
    #expect(JavaScriptDialogs.originLabel(scheme: "file", host: "", port: 0) == "a local file")
    #expect(JavaScriptDialogs.originLabel(scheme: "safari-web-extension", host: "extension-id", port: 0) == "safari-web-extension://extension-id")
    #expect(JavaScriptDialogs.originLabel(scheme: "", host: "", port: 0) == "an unknown origin")
}

// @lat: [[lat.md/tests/web-pages-tests#JavaScript dialog admission and rate limits]]
@Test @MainActor func javaScriptDialogAdmissionAndLimits() throws {
    let presentation = DialogPresentation()
    let window = dialogWindow(); defer { window.close() }
    let otherWindow = dialogWindow(); defer { otherWindow.close() }
    let page = dialogPage(presentation.dialogs, in: window)
    let other = dialogPage(presentation.dialogs, in: otherWindow)
    let request = JavaScriptDialogs.Request(kind: .confirm, origin: "https://example.test", message: "Question")
    var cancelled = 0
    let rejected: (JavaScriptDialogs.Response) -> Void = { response in
        #expect(!response.accepted && response.text == nil); cancelled += 1
    }
    window.acceptsDialogs = false
    presentation.dialogs.request(request, from: page.webView, completion: rejected)
    window.acceptsDialogs = true
    page.webView.isHidden = true
    presentation.dialogs.request(request, from: page.webView, completion: rejected)
    page.webView.isHidden = false
    #expect(cancelled == 2 && presentation.alerts.isEmpty)

    presentation.dialogs.request(request, from: page.webView) { _ in }
    presentation.dialogs.request(request, from: page.webView, completion: rejected)
    #expect(cancelled == 3 && presentation.alerts.count == 1)
    // An outstanding dialog never blocks another browser window's event loop.
    presentation.dialogs.request(request, from: other.webView) { _ in }
    #expect(presentation.alerts.count == 2)
    presentation.completions[1](.alertFirstButtonReturn)
    presentation.completions[0](.alertFirstButtonReturn)
    for _ in 0..<2 {
        presentation.dialogs.didCommitNavigation(in: page.webView)
        presentation.dialogs.request(request, from: page.webView) { _ in }
        presentation.completions.last?(.alertFirstButtonReturn)
    }
    let count = presentation.alerts.count
    presentation.dialogs.didCommitNavigation(in: page.webView)
    presentation.dialogs.request(request, from: page.webView, completion: rejected)
    #expect(presentation.alerts.count == count && cancelled == 4)
    presentation.time += 31
    presentation.dialogs.request(request, from: page.webView) { _ in }
    #expect(presentation.alerts.count == count + 1)
    let alert = try #require(presentation.alerts.last)
    alert.suppressionButton?.state = .on
    presentation.completions.last?(.alertFirstButtonReturn)
    presentation.time += 31
    presentation.dialogs.request(request, from: page.webView, completion: rejected)
    #expect(cancelled == 5)
    presentation.dialogs.didCommitNavigation(in: page.webView)
    presentation.dialogs.request(request, from: page.webView) { _ in }
    #expect(presentation.alerts.count == count + 2)
    presentation.completions.last?(.alertFirstButtonReturn)
}

// @lat: [[lat.md/tests/web-pages-tests#JavaScript dialog lifecycle cancellation]]
@Test @MainActor func javaScriptDialogLifecycleCancellation() throws {
    let presentation = DialogPresentation()
    let window = dialogWindow(); defer { window.close() }
    let page = dialogPage(presentation.dialogs, in: window)
    let request = JavaScriptDialogs.Request(kind: .prompt, origin: "https://example.test", message: "Input")
    var responses = 0
    func start() {
        presentation.time += 31
        presentation.dialogs.request(request, from: page.webView) { response in
            #expect(!response.accepted && response.text == nil); responses += 1
        }
    }
    start()
    page.navigate("browse://guide")
    #expect(responses == 1)
    presentation.completions.last?(.alertFirstButtonReturn)
    #expect(responses == 1)

    // Hiding a mounted tab's ancestor cancels its outstanding sheet.
    let container = NSView(frame: page.webView.frame)
    page.webView.removeFromSuperview()
    window.contentView = container
    container.addSubview(page.webView)
    start()
    container.isHidden = true
    #expect(responses == 2)
    container.isHidden = false
    start()
    page.webView.removeFromSuperview()
    #expect(responses == 3)
    container.addSubview(page.webView)
    start()
    page.webViewWebContentProcessDidTerminate(page.webView)
    #expect(responses == 4)
    start()
    window.close()
    #expect(responses == 5)
    presentation.completions.last?(.alertFirstButtonReturn)
    #expect(responses == 5)
}

// @lat: [[lat.md/tests/web-pages-tests#JavaScript native sheets]]
@Test @MainActor func javaScriptNativeSheets() async throws {
    let window = dialogWindow(); defer { window.close() }
    var shown: NSAlert?
    let dialogs = JavaScriptDialogs(present: { alert, window, completion in
        shown = alert
        alert.beginSheetModal(for: window, completionHandler: completion)
    })
    let page = dialogPage(dialogs, in: window)
    var result: JavaScriptDialogs.Response?
    dialogs.request(.init(kind: .prompt, origin: "https://example.test", message: "Input"), from: page.webView) { result = $0 }
    let alert = try #require(shown)
    #expect(alert.window.sheetParent === window)
    #expect(NSApp.modalWindow == nil)
    (alert.accessoryView as? NSTextField)?.stringValue = "Sheet response"
    window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
    for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(result?.accepted == true && result?.text == "Sheet response")
}
