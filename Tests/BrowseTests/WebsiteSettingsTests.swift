import AppKit
import BrowseCore
import Network
import Testing
import WebKit
@testable import Browse

// @lat: [[tests#Website security preferences]]
@Test @MainActor func websiteSecurityPreferences() async throws {
    _ = NSApplication.shared
    let server = try await WebsiteZoomHTTPFixture.start()
    defer { server.listener.cancel() }
    let settings = WebsiteSettingsStore(temporary: WebsiteSettings())
    settings.setPreference(\.javaScriptEnabled, false)
    settings.setPreference(\.warnFraudulentSites, false)
    settings.setPreference(\.blockAllCookies, true)
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let page = PageController(address: "http://127.0.0.1:\(server.port)/script", websiteSettings: settings,
                              configure: { $0.websiteDataStore = dataStore })
    defer { page.webView.stopLoading() }
    func wait(_ path: String) async throws {
        for _ in 0..<200 {
            if page.webView.url?.path == path, !page.webView.isLoading, page.webView.title != nil { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Website did not finish loading")
    }
    try await wait("/script")
    #expect(page.webView.title == "Zoom fixture")
    #expect(!page.webView.configuration.preferences.isFraudulentWebsiteWarningEnabled)
    #expect(await dataStore.httpCookieStore.cookiePolicy == .disallow)
    settings.setPreference(\.javaScriptEnabled, true)
    settings.setPreference(\.warnFraudulentSites, true)
    settings.setPreference(\.blockAllCookies, false)
    page.navigate("http://127.0.0.1:\(server.port)/script-enabled")
    try await wait("/script-enabled")
    #expect(page.webView.title == "Script ran")
    #expect(page.webView.configuration.preferences.isFraudulentWebsiteWarningEnabled)
    #expect(await dataStore.httpCookieStore.cookiePolicy == .allow)
    settings.setPreference(\.warnHTTP, true)
    let preferences = WKWebpagePreferences()
    page.webView(page.webView, decidePolicyFor: WKNavigationAction(), preferences: preferences) { _, resolved in
        #expect(resolved.preferredHTTPSNavigationPolicy == .userMediatedFallbackToHTTP)
    }
}

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

// @lat: [[tests#Website zoom during provisional navigation]]
@Test @MainActor func websiteZoomDuringProvisionalNavigation() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendProvisionalZoom-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await WebsiteZoomHTTPFixture.start()
    defer { server.listener.cancel() }
    let settings = WebsiteSettingsStore(file: root.appendingPathComponent("WebsiteSettings.db"))
    let source = URL(string: "http://127.0.0.1:\(server.port)/first")!
    let target = URL(string: "http://localhost:\(server.port)/slow")!
    settings.setZoom(1.1, for: source)
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let web = FocusWebView(frame: .zero, configuration: config)
    let page = PageController(address: source.absoluteString, webView: web, websiteSettings: settings)
    defer { web.stopLoading() }
    func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<150 where !ready() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(ready())
    }
    try await waitUntil { web.url == source && !web.isLoading }
    #expect(web.pageZoom == 1.1)
    page.navigate(target.absoluteString)
    #expect(web.pageZoom == 1.1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(web.isLoading && web.pageZoom == 1.1)
    #expect(try await web.evaluateJavaScript("location.hostname") as? String == "127.0.0.1")
    // Live settings still belong to the visible document while the next one loads.
    settings.setZoom(1.2, for: source)
    #expect(web.pageZoom == 1.2)
    settings.setZoom(1.5, for: target)
    #expect(web.pageZoom == 1.2)
    try await waitUntil { web.url == target && !web.isLoading }
    #expect(web.pageZoom == 1.5)

    // A failed provisional navigation must leave the outgoing zoom and ownership intact.
    page.navigate("http://127.0.0.1:\(server.port)/fail")
    #expect(web.pageZoom == 1.5)
    try await waitUntil { page.error != nil }
    #expect(web.pageZoom == 1.5)
    page.setPageZoom(1.6)
    #expect(settings.values.zoom(for: target) == 1.6)
    #expect(settings.values.zoom(for: source) == 1.2)

    // Redirects apply only the final site's setting, never the intermediate host's.
    page.navigate("http://127.0.0.1:\(server.port)/redirect")
    #expect(web.pageZoom == 1.6)
    try await waitUntil { web.url?.path == "/redirected" && !web.isLoading }
    #expect(web.pageZoom == 1.6)
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
                if request.hasPrefix("GET /fail ") { connection.cancel(); return }
                let response: String
                if request.hasPrefix("GET /redirect ") {
                    response = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(server.port)/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else {
                    let frame = request.hasPrefix("GET /with-frame ") ? "<iframe src='http://localhost:\(server.port)/frame'></iframe>" : ""
                    let script = request.hasPrefix("GET /script") ? "<script>document.title='Script ran';</script>" : ""
                    let body = "<html><head><title>Zoom fixture</title>\(script)</head><body><input value='keep me'>\(frame)</body></html>"
                    response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                }
                if request.hasPrefix("GET /slow ") {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    }
                } else {
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
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

// @lat: [[tests#Native privacy preferences]]
@Test @MainActor func nativePrivacyPreferences() async throws {
    _ = NSApplication.shared
    let settings = WebsiteSettingsStore(temporary: WebsiteSettings())
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let page = PageController(address: "about:blank", websiteSettings: settings,
                              configure: { $0.websiteDataStore = dataStore })
    defer { page.webView.stopLoading() }
    func flag(_ object: NSObject, _ key: String) throws -> Bool {
        try #require(object.value(forKey: key) as? Bool)
    }
    #expect(try !flag(page.webView.configuration.preferences, "_privateClickMeasurementEnabled"))
    for enabled in [true, false, true] {
        settings.setPreference(\.preventCrossSiteTracking, enabled)
        settings.setPreference(\.applePayDisclosureAllowed, enabled)
        settings.setPreference(\.privateClickMeasurementEnabled, enabled)
        #expect(try flag(dataStore, "_resourceLoadStatisticsEnabled") == enabled)
        #expect(try flag(page.webView.configuration.preferences, "_applePayCapabilityDisclosureAllowed") == enabled)
        #expect(try flag(page.webView.configuration.preferences, "_privateClickMeasurementEnabled") == enabled)
        let preferences = WKWebpagePreferences()
        page.webView(page.webView, decidePolicyFor: WKNavigationAction(), preferences: preferences) { _, resolved in
            #expect((resolved.value(forKey: "_networkConnectionIntegrityEnabled") as? Bool) == true)
        }
    }
    // Unsupported objects are safely ignored rather than invoking undefined KVC.
    let unsupported = NSObject()
    #expect(!WebKitPrivacy.supports(.tracking, on: unsupported))
    WebKitPrivacy.set(.tracking, on: unsupported, enabled: true)
    // The regular session and each private window have independent data stores.
    let otherStore = WKWebsiteDataStore.nonPersistent()
    let otherSettings = WebsiteSettingsStore(temporary: settings.values)
    let other = PageController(address: "about:blank", websiteSettings: otherSettings,
                               configure: { $0.websiteDataStore = otherStore })
    defer { other.webView.stopLoading() }
    settings.setPreference(\.preventCrossSiteTracking, false)
    #expect(try flag(otherStore, "_resourceLoadStatisticsEnabled"))
}
