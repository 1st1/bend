import AppKit
import WebKit
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Modal account sign-in popup]]
@Test @MainActor func aiOAuthModalBrowser() async throws { try await checkOAuthBrowser("success") }
@Test @MainActor func aiOAuthPopupCancellation() async throws { try await checkOAuthBrowser("popup cancel") }
@Test @MainActor func aiOAuthTaskCancellation() async throws { try await checkOAuthBrowser("task cancel") }
@Test @MainActor func aiOAuthSettingsClosure() async throws { try await checkOAuthBrowser("settings close") }
@Test @MainActor func aiOAuthInvalidBrowserURL() async throws { try await checkOAuthBrowser("invalid URL") }
@Test @MainActor func aiOAuthWebProcessFailure() async throws { try await checkOAuthBrowser("web process failure") }
@Test @MainActor func aiOAuthProviderPopup() async throws { try await checkOAuthBrowser("provider popup") }

@MainActor private func checkOAuthBrowser(_ outcome: String) async throws {
    _ = NSApplication.shared
    // A plain native window keeps SwiftUI's application lifecycle out of the
    // test host. Settings' own modal lifecycle is covered separately.
    let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
    settings.isReleasedWhenClosed = false
    settings.makeKeyAndOrderFront(nil)
    let modal = NSApp.beginModalSession(for: settings)
    _ = NSApp.runModalSession(modal)
    defer { NSApp.endModalSession(modal); settings.close() }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate())
    }
    let listener = OAuthLoopback()
    let redirect = try await listener.start(port: 0, state: "expected")
    defer { listener.cancel() }
    let browser = AIOAuthBrowser(anchor: settings, websiteDataStore: .nonPersistent())
    // An invalid-state request returns a real HTTP page without completing login.
    let initial = outcome == "invalid URL" ? URL(string: "file:///etc/hosts")! : redirect
    let pending = Task { try await browser.authenticate(url: initial, callback: listener, redirect: redirect) }
    defer { pending.cancel() }
    if outcome == "invalid URL" {
        await #expect(throws: AIOAuthError.self) { try await pending.value }
        #expect(!browser.panel.isVisible)
        return
    }
    try await wait { browser.panel.isVisible && !browser.webView.isLoading && browser.webView.url != nil }
    #expect(browser.panel.worksWhenModal)
    #expect(browser.panel.parent === settings)
    #expect(browser.panel.contentView === browser.webView)
    #expect(NSApp.modalWindow === settings)
    #expect(!browser.webView.configuration.websiteDataStore.isPersistent)
    #expect(browser.webView.configuration.userContentController.userScripts.isEmpty)
    #expect(browser.allowsNavigation(to: URL(string: "https://auth.openai.com/log-in")!))
    #expect(browser.allowsNavigation(to: redirect))
    for blocked in ["file:///etc/hosts", "http://example.com", "javascript:alert(1)",
                    "custom-scheme://open", "http://127.0.0.1:1/auth/callback",
                    redirect.absoluteString + "/wrong", "https://user:secret@example.com"] {
        #expect(!browser.allowsNavigation(to: URL(string: blocked)!))
    }
    switch outcome {
    case "success":
        let callbackURL = URL(string: redirect.absoluteString + "?state=expected&code=test&client_id=issued")!
        browser.webView.load(URLRequest(url: callbackURL))
        #expect(try await pending.value == callbackURL)
        #expect(try await listener.wait() == callbackURL)
    case "popup cancel":
        browser.panel.close()
        await #expect(throws: CancellationError.self) { try await pending.value }
    case "task cancel":
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
    case "settings close":
        settings.close()
        await #expect(throws: CancellationError.self) { try await pending.value }
    case "web process failure":
        browser.webViewWebContentProcessDidTerminate(browser.webView)
        await #expect(throws: AIOAuthError.self) { try await pending.value }
    default:
        _ = try await browser.webView.evaluateJavaScript("void window.open('about:blank', 'provider')")
        try await wait { browser.popups.count == 1 }
        let child = try #require(browser.popups.first)
        #expect(child.panel.worksWhenModal && child.panel.isVisible)
        #expect(child.panel.parent === browser.panel)
        _ = try await child.webView.evaluateJavaScript("void window.close()")
        try await wait { browser.popups.isEmpty }
        #expect(browser.panel.isVisible)
        _ = try await browser.webView.evaluateJavaScript("void window.open('about:blank', 'provider2')")
        try await wait { browser.popups.count == 1 }
        let remaining = try #require(browser.popups.first?.panel)
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!remaining.isVisible)
    }
    #expect(!browser.panel.isVisible && browser.panel.parent == nil && browser.popups.isEmpty)
    #expect(browser.webView.navigationDelegate == nil && browser.webView.uiDelegate == nil)
    if outcome != "settings close" { #expect(NSApp.modalWindow === settings) }
}
