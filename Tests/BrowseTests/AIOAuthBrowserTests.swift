import AppKit
import AuthenticationServices
import Testing
@testable import Browse

@MainActor private final class OAuthBrowserStub: OAuthBrowserSession {
    weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    var completion: ASWebAuthenticationSession.CompletionHandler?
    var canStart = true
    var started = false
    var cancelled = false
    func start() -> Bool { started = true; return canStart }
    func cancel() {
        cancelled = true
        completion?(nil, NSError(domain: ASWebAuthenticationSessionErrorDomain,
                                 code: ASWebAuthenticationSessionError.canceledLogin.rawValue))
    }
}

// @lat: [[lat.md/tests/ai-tests#Modal account sign-in popup]]
@Test(arguments: ["success", "popup cancel", "task cancel", "settings close", "start failure", "session error"]) @MainActor
func aiOAuthModalBrowser(outcome: String) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OAuthModal-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let settings = SettingsWindowController(store: store)
    // Use AppKit's cooperative modal session in the test host. The Settings
    // lifecycle test separately covers its blocking production modal loop.
    settings.window.delegate = nil // This test owns and ends the cooperative session.
    settings.window.makeKeyAndOrderFront(nil)
    let modal = NSApp.beginModalSession(for: settings.window)
    _ = NSApp.runModalSession(modal)
    defer {
        NSApp.endModalSession(modal)
        settings.window.close()
        store.stopWindow()
        try? FileManager.default.removeItem(at: root)
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate())
    }
    try await wait { NSApp.modalWindow === settings.window }
    let listener = OAuthLoopback()
    let redirect = try await listener.start(port: 0, state: "expected")
    defer { listener.cancel() }
    let stub = OAuthBrowserStub()
    stub.canStart = outcome != "start failure"
    let url = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    let browser = AIOAuthBrowser(anchor: settings.window) { requestedURL, completion in
        #expect(requestedURL == url)
        stub.completion = completion
        return stub
    }
    let pending = Task { try await browser.authenticate(url: url, callback: listener) }
    defer { pending.cancel() }
    try await wait { stub.started }
    #expect(stub.presentationContextProvider === browser)
    #expect(browser.anchor === settings.window)
    #expect(NSApp.modalWindow === settings.window)
    switch outcome {
    case "success":
        let callbackURL = URL(string: redirect.absoluteString + "?state=expected&code=test&client_id=issued")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: callbackURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await pending.value == callbackURL)
        // Dismissing the browser after a valid loopback result must not cancel it.
        #expect(try await listener.wait() == callbackURL)
    case "popup cancel":
        stub.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
    case "task cancel":
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
    case "settings close":
        settings.window.close()
        await #expect(throws: CancellationError.self) { try await pending.value }
    case "start failure":
        await #expect(throws: AIOAuthError.self) { try await pending.value }
    default:
        stub.completion?(nil, AIOAuthError.invalid("System sign-in failed."))
        await #expect(throws: AIOAuthError.self) { try await pending.value }
    }
    #expect(stub.cancelled)
    if outcome != "settings close" { #expect(NSApp.modalWindow === settings.window) }
}
