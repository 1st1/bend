import AppKit
import BrowseCore
import Network
import Testing
import WebKit
@testable import Browse

// @lat: [[tests#Website zoom navigation and sharing]]
@Test @MainActor func websiteZoomNavigationAndSharing() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendWebsiteZoom-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await WebsiteZoomHTTPFixture.start()
    defer { server.listener.cancel() }
    let primary = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let secondary = BrowserStore(sessionFile: root.appendingPathComponent("Windows/second.json"), sharedStore: primary)
    #expect(primary.websiteSettings === secondary.websiteSettings)
    let settings = primary.websiteSettings
    settings.setDefaultZoom(1.1)
    let firstURL = "http://127.0.0.1:\(server.port)/first"
    let otherURL = "http://localhost:\(server.port)/other"
    let page = primary.controller(for: Page(address: firstURL))
    let sameHost = secondary.controller(for: Page(address: "http://127.0.0.1:\(server.port)/second"))
    let other = secondary.controller(for: Page(address: otherURL))
    defer { for controller in [page, sameHost, other] { controller.webView.stopLoading() } }
    func wait(_ page: PageController, host: String, path: String) async throws {
        for _ in 0..<100 {
            if page.webView.url?.host == host, page.webView.url?.path == path, !page.webView.isLoading,
               (try? await page.webView.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        Issue.record("Navigation did not complete: \(host)\(path), error: \(page.error ?? "none")")
    }
    try await wait(page, host: "127.0.0.1", path: "/first")
    try await wait(sameHost, host: "127.0.0.1", path: "/second")
    try await wait(other, host: "localhost", path: "/other")
    #expect(page.webView.pageZoom == 1.1)
    let origin = try await page.webView.evaluateJavaScript("performance.timeOrigin") as? Double
    page.setPageZoom(1.5)
    #expect(page.webView.pageZoom == 1.5)
    #expect(sameHost.webView.pageZoom == 1.5)
    #expect(other.webView.pageZoom == 1.1)
    #expect(try await page.webView.evaluateJavaScript("performance.timeOrigin") as? Double == origin)
    let reopened = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    #expect(reopened.websiteSettings.values.defaultZoom == 1.1)
    let restored = reopened.controller(for: Page(address: firstURL))
    #expect(restored.webView.pageZoom == 1.5)
    restored.webView.stopLoading()
    // Loading a different website must replace this pane's previous zoom.
    page.navigate(otherURL)
    try await wait(page, host: "localhost", path: "/other")
    #expect(page.webView.pageZoom == 1.1)
    page.webView.goBack()
    try await wait(page, host: "127.0.0.1", path: "/first")
    #expect(page.webView.pageZoom == 1.5)
    page.webView.goForward()
    try await wait(page, host: "localhost", path: "/other")
    #expect(page.webView.pageZoom == 1.1)
    // Server redirect changes hostname without calling PageController.navigate again.
    page.navigate("http://127.0.0.1:\(server.port)/redirect")
    try await wait(page, host: "localhost", path: "/redirected")
    #expect(page.webView.pageZoom == 1.1)
    // Ordinary links use the destination's preference, while iframe loads do not.
    try await page.webView.evaluateJavaScript("location.href = 'http://127.0.0.1:\(server.port)/with-frame'")
    try await wait(page, host: "127.0.0.1", path: "/with-frame")
    #expect(page.webView.pageZoom == 1.5)
    settings.setDefaultZoom(1.25)
    #expect(other.webView.pageZoom == 1.25)
    #expect(page.webView.pageZoom == 1.5)
    // Command-zero's explicit 100% remains an override when the default differs.
    page.setPageZoom(1)
    #expect(settings.values.zoomByHost["127.0.0.1"] == 1)
    #expect(sameHost.webView.pageZoom == 1)
    settings.removeOverride(for: "127.0.0.1")
    #expect(page.webView.pageZoom == 1.25)
    #expect(sameHost.webView.pageZoom == 1.25)
    page.setPageZoom(1.5)
    page.setPageZoom(1.25)
    #expect(settings.values.zoomByHost["127.0.0.1"] == nil)
    page.setPageZoom(2)
    other.setPageZoom(0.9)
    primary.recordVisit(url: firstURL, title: "History")
    primary.clearHistory()
    #expect(settings.values.zoomByHost.count == 2)
    settings.removeAllOverrides()
    #expect(page.webView.pageZoom == 1.25)
    #expect(other.webView.pageZoom == 1.25)
    #expect(WebsiteSettingsStore(file: root.appendingPathComponent("WebsiteSettings.db")).values == settings.values)
    page.navigate("browse://start")
    #expect(page.webView.pageZoom == 1)
    settings.setDefaultZoom(1.5)
    #expect(page.webView.pageZoom == 1)
}

// @lat: [[tests#Website settings failure recovery]]
@Test @MainActor func websiteSettingsFailureRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendWebsiteRecovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("WebsiteSettings.db")
    let corrupt = Data("unreadable settings".utf8)
    try corrupt.write(to: file)
    let settings = WebsiteSettingsStore(file: file)
    #expect(settings.errorMessage != nil)
    settings.setDefaultZoom(1.5)
    #expect(settings.values.defaultZoom == 1)
    #expect(try Data(contentsOf: file) == corrupt)
    try FileManager.default.removeItem(at: file)
    settings.reload()
    #expect(settings.errorMessage == nil)
    settings.setDefaultZoom(1.25)
    settings.setZoom(2, for: URL(string: "https://EXAMPLE.com/a")!)
    settings.setZoom(.nan, forHost: "example.com")
    #expect(settings.values.zoomByHost["example.com"] == 2)
    #expect(WebsiteSettingsStore(file: file).values == settings.values)
}

private final class WebsiteZoomHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() async throws -> WebsiteZoomHTTPFixture {
        let server = try WebsiteZoomHTTPFixture()
        server.listener.newConnectionHandler = { [weak server] connection in
            guard let server else { return }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let response: String
                if request.hasPrefix("GET /redirect ") {
                    response = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(server.port)/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    let frame = request.hasPrefix("GET /with-frame ") ? "<iframe src='http://localhost:\(server.port)/frame'></iframe>" : ""
                    let body = "<html><head><title>Zoom fixture</title></head><body><input value='keep me'>\(frame)</body></html>"
                    response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: server.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): server.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: .global())
        }
        return server
    }
}
