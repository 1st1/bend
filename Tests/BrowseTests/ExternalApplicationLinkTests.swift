import AppKit
import Testing
import WebKit
@testable import Browse

@MainActor private func externalLinkTestWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    return window
}

// @lat: [[tests#External application consent]]
@Test @MainActor func externalApplicationConsent() async {
    _ = NSApplication.shared
    let window = externalLinkTestWindow()
    defer { window.close() }
    let app = ExternalApplicationLinks.Application(url: URL(fileURLWithPath: "/Applications/Test.app"), name: "Test App")
    let source = URL(string: "https://user:secret@launch.example:8443/path?private=value#fragment")!
    #expect(ExternalApplicationLinks.sourceName(source) == "https://launch.example:8443")
    var opened: [URL] = []
    var approved = false
    var available = true
    var failOpening = false
    var unavailableCount = 0
    var failureCount = 0
    let links = ExternalApplicationLinks(resolve: { _ in available ? app : nil }, confirm: { prompt, _ in
        switch prompt {
        case .open(let resolved, let origin):
            #expect(resolved.url == app.url)
            #expect(origin == source)
            return approved
        case .unavailable: unavailableCount += 1; return false
        case .failed: failureCount += 1; return false
        }
    }, open: { url, resolved in
        #expect(resolved.url == app.url)
        if failOpening { throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError) }
        opened.append(url)
    })
    let url = URL(string: "zoommtg://launch.example/join?confno=123&pwd=synthetic")!
    await links.request(url, source: source, in: window)?.value
    #expect(opened.isEmpty)
    approved = true
    for scheme in ["zoommtg", "slack", "mailto", "custom-app"] {
        let destination = URL(string: "\(scheme):test?value=unchanged%20value")!
        await links.request(destination, source: source, in: window)?.value
        #expect(opened.last == destination)
    }
    #expect(opened.count == 4)
    for blocked in ["https://example.com", "http://example.com", "about:blank", "file:///tmp/test.html",
                    "data:text/html,test", "javascript:alert(1)", "blob:https://example.com/id", "browse://start", "applewebdata://id/page", "webkit-extension://id/page", "safari-web-extension://id/page"] {
        #expect(links.request(URL(string: blocked)!, source: source, in: window) == nil)
    }
    available = false
    await links.request(url, source: source, in: window)?.value
    #expect(unavailableCount == 1)
    #expect(opened.count == 4)
    available = true
    failOpening = true
    await links.request(url, source: source, in: window)?.value
    #expect(failureCount == 1)
    #expect(opened.count == 4)
}

// @lat: [[tests#External application prompt coalescing]]
@Test @MainActor func externalApplicationPromptCoalescing() async throws {
    _ = NSApplication.shared
    let window = externalLinkTestWindow()
    defer { window.close() }
    var response: CheckedContinuation<Bool, Never>?
    var launches = 0
    let links = ExternalApplicationLinks(resolve: { _ in
        .init(url: URL(fileURLWithPath: "/Applications/Test.app"), name: "Test")
    }, confirm: { _, _ in
        await withCheckedContinuation { response = $0 }
    }, open: { _, _ in launches += 1 })
    let url = URL(string: "custom-app:launch")!
    let first = try #require(links.request(url, source: nil, in: window))
    #expect(links.request(url, source: nil, in: window) == nil)
    for _ in 0..<100 where response == nil { await Task.yield() }
    let firstResponse = try #require(response)
    firstResponse.resume(returning: false)
    await first.value
    #expect(launches == 0)
    response = nil
    let retry = try #require(links.request(url, source: nil, in: window))
    for _ in 0..<100 where response == nil { await Task.yield() }
    let secondResponse = try #require(response)
    window.orderOut(nil)
    secondResponse.resume(returning: true)
    await retry.value
    #expect(launches == 0)
    #expect(links.request(url, source: nil, in: window) == nil)
}

// @lat: [[tests#WebKit external application routes]]
@Test @MainActor func webKitExternalApplicationRoutes() async throws {
    _ = NSApplication.shared
    let window = externalLinkTestWindow()
    defer { window.close() }
    var opened: [URL] = []
    var origins: [URL?] = []
    let links = ExternalApplicationLinks(resolve: { _ in
        .init(url: URL(fileURLWithPath: "/Applications/Test.app"), name: "Test")
    }, confirm: { prompt, _ in
        if case .open(_, let source) = prompt { origins.append(source) }
        return true
    }, open: { url, _ in opened.append(url) })
    let controller = PageController(address: "browse://start", externalApplications: links) {
        $0.preferences.javaScriptCanOpenWindowsAutomatically = true
    }
    window.contentView = controller.webView
    controller.isStartPage = false
    var newTabs: [String] = []
    controller.onNewTab = { newTabs.append($0) }
    controller.webView.loadHTMLString("<title>Launcher</title><a id='app' href='custom-app:normal'>Open</a>",
                                      baseURL: URL(string: "https://launch.example/"))
    for _ in 0..<100 {
        if (try? await controller.webView.evaluateJavaScript("document.title")) as? String == "Launcher" { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let routes = [
        ("document.getElementById('app').click()", "custom-app:normal"),
        ("location.href = 'custom-app:script'", "custom-app:script"),
        ("window.open('custom-app:new-window'); void 0", "custom-app:new-window"),
        ("var frame = document.createElement('iframe'); frame.src = 'custom-app:iframe'; document.body.appendChild(frame); void 0", "custom-app:iframe")
    ]
    for (index, route) in routes.enumerated() {
        _ = try await controller.webView.evaluateJavaScript(route.0)
        for _ in 0..<100 {
            if opened.count > index { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(opened.count == index + 1)
        #expect(opened.last?.absoluteString == route.1)
        #expect(controller.error == nil)
        #expect(try await controller.webView.evaluateJavaScript("document.title") as? String == "Launcher")
    }
    #expect(origins.allSatisfy { $0?.host == "launch.example" })
    #expect(newTabs.isEmpty)
}
