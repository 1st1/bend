import AppKit
import Testing
import WebKit
@testable import Browse

@MainActor
private final class LinkAction: WKNavigationAction {
    var modifiers: NSEvent.ModifierFlags = .command
    // WKNavigationAction uses a button mask: left = 1, right = 2, middle = 4.
    var button = 1
    var kind: WKNavigationType = .linkActivated
    var destination = URL(string: "https://example.com/target?q=one#section")!
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override var buttonNumber: Int { button }
    override var navigationType: WKNavigationType { kind }
    override var request: URLRequest { URLRequest(url: destination) }
    override var targetFrame: WKFrameInfo? { nil }
}

// @lat: [[tests#Command-click navigation]]
@Test @MainActor func commandClickNavigation() {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start")
    var panes: [String] = []
    controller.onNewPane = { panes.append($0) }
    let action = LinkAction()
    var policies: [WKNavigationActionPolicy] = []
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies == [.cancel])
    #expect(panes == [action.destination.absoluteString])
    #expect(controller.address == "browse://start")

    action.modifiers = []
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies.last == .allow)
    action.modifiers = .command
    for button in [0, 2, 4] {
        action.button = button
        controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
        #expect(policies.last == .allow)
    }
    action.button = 1
    action.kind = .other
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies.last == .allow)
    action.kind = .linkActivated
    action.destination = URL(string: "custom://target")!
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies.last == .cancel)
    #expect(panes.count == 1)
}

// @lat: [[tests#Command-click new-window links]]
@Test @MainActor func commandClickNewWindowLink() {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start")
    var panes: [String] = []
    var tabs: [String] = []
    controller.onNewPane = { panes.append($0) }
    controller.onNewTab = { tabs.append($0) }
    let action = LinkAction()
    let result = controller.webView(controller.webView, createWebViewWith: WKWebViewConfiguration(),
                                    for: action, windowFeatures: WKWindowFeatures())
    #expect(result == nil)
    #expect(panes == [action.destination.absoluteString])
    #expect(tabs.isEmpty)
    action.modifiers = []
    _ = controller.webView(controller.webView, createWebViewWith: WKWebViewConfiguration(),
                           for: action, windowFeatures: WKWindowFeatures())
    #expect(panes.count == 1)
    #expect(tabs == [action.destination.absoluteString])
}
