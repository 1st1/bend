import AppKit
import Testing
import WebKit
import Network
import Combine
import BrowseCore
@testable import Browse

// @lat: [[tests#Favicon discovery]]
@Test @MainActor func faviconCandidates() async throws {
    let page = URL(string: "https://example.com/articles/page")!
    let urls = FaviconLoader.candidates(links: [
        "../brand.png", "https://cdn.example.com/icon.ico", "../brand.png",
        "file:///tmp/icon.png", "javascript:alert(1)", "/favicon.ico"
    ], pageURL: page)
    #expect(urls.map(\.absoluteString) == [
        "https://example.com/brand.png", "https://cdn.example.com/icon.ico", "https://example.com/favicon.ico"
    ])
    #expect(FaviconLoader.candidates(links: [], pageURL: page).last?.path == "/favicon.ico")
    #expect(FaviconLoader.candidates(links: [], pageURL: URL(string: "browse://history")!).isEmpty)

    _ = NSApplication.shared
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: config)
    let navigation = FaviconTestNavigation()
    web.navigationDelegate = navigation
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        navigation.completion = continuation
        web.loadHTMLString("""
            <base href="https://cdn.example.com/assets/">
            <link rel="apple-touch-icon" href="touch.png">
            <link rel="stylesheet" href="data:text/css,">
            <link rel="shortcut ICON" href="brand.ico">
            <body>Favicon fixture</body>
            """, baseURL: page)
    }
    let discovered = await FaviconLoader.candidates(in: web, pageURL: page)
    #expect(discovered.map(\.absoluteString) == [
        "https://cdn.example.com/assets/brand.ico", "https://cdn.example.com/assets/touch.png",
        "https://example.com/favicon.ico"
    ])
}

@MainActor
private final class FaviconTestNavigation: NSObject, WKNavigationDelegate {
    var completion: CheckedContinuation<Void, Error>?
    func load(_ web: WKWebView, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            web.load(URLRequest(url: url))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion?.resume(); completion = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error); completion = nil
    }
}

// @lat: [[tests#Favicon fallback and cancellation]]
@Test @MainActor func faviconFallback() async throws {
    _ = NSApplication.shared
    let server = try await FaviconHTTPFixture.start()
    defer { server.listener.cancel() }
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: config)
    let navigation = FaviconTestNavigation(); web.navigationDelegate = navigation
    try await navigation.load(web, url: server.url("/page"))
    let image = await FaviconLoader.load([server.url("/broken"), server.url("/icon.png")], in: web)
    #expect(image?.isValid == true)
    #expect(image?.size == NSSize(width: 64, height: 64))
    #expect(server.paths.contains("/broken") && server.paths.contains("/icon.png"))

    let task = Task { @MainActor in
        await FaviconLoader.load([server.url("/slow")], in: web)
    }
    for _ in 0..<100 where !server.paths.contains("/slow") { try await Task.sleep(for: .milliseconds(20)) }
    task.cancel()
    #expect(await task.value == nil)
}

// @lat: [[tests#Favicon navigation reset]]
@Test @MainActor func faviconNavigationReset() async throws {
    _ = NSApplication.shared
    let target = try await FaviconHTTPFixture.start()
    let server = try await FaviconHTTPFixture.start(redirect: target.url("/page"))
    defer { server.listener.cancel(); target.listener.cancel() }
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let web = FocusWebView(frame: .zero, configuration: config)
    let controller = PageController(address: server.url("/page").absoluteString, webView: web)
    defer { web.stopLoading() }
    func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<200 where !ready() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(ready())
    }
    try await waitUntil { controller.favicon != nil }
    let original = try #require(controller.favicon)
    var cleared = false
    let observation = controller.$favicon.dropFirst().sink { if $0 == nil { cleared = true } }
    defer { observation.cancel() }

    // Exercise a real link and a delayed response, not just a synthetic delegate call.
    _ = try await web.evaluateJavaScript("document.getElementById('next').click(); void 0")
    try await waitUntil { server.paths.contains("/next") }
    #expect(controller.favicon === original)
    try await waitUntil { web.url == server.url("/next") && !controller.isLoading && controller.favicon !== original }
    #expect(!cleared)

    let beforeReload = try #require(controller.favicon)
    web.reload()
    try await waitUntil { !controller.isLoading && controller.favicon !== beforeReload }
    #expect(!cleared)

    let beforeAddressEntry = try #require(controller.favicon)
    controller.navigate(server.url("/page").absoluteString)
    #expect(controller.favicon === beforeAddressEntry)
    try await waitUntil { web.url == server.url("/page") && !controller.isLoading && controller.favicon !== beforeAddressEntry }
    #expect(!cleared)

    // A missing or CSP-blocked icon on the next same-origin page keeps the last icon.
    let beforeBlocked = try #require(controller.favicon)
    controller.navigate(server.url("/blocked").absoluteString)
    try await waitUntil { web.url == server.url("/blocked") && !controller.isLoading }
    try await Task.sleep(for: .milliseconds(200))
    #expect(controller.favicon === beforeBlocked && !cleared)

    // A same-origin request may redirect to a different origin (here, another port).
    controller.navigate(server.url("/redirect").absoluteString)
    #expect(controller.favicon === beforeBlocked)
    try await waitUntil { web.url == target.url("/page") && !controller.isLoading && controller.favicon != nil }
    #expect(cleared)
    controller.navigate("browse://guide")
    #expect(controller.favicon == nil)

    // A late result from the old document cannot restore its icon on another site.
    controller.navigate(server.url("/slow-icon-page").absoluteString)
    try await waitUntil { server.paths.contains("/slow") }
    controller.navigate(target.url("/blocked").absoluteString)
    try await waitUntil { web.url == target.url("/blocked") && !controller.isLoading }
    try await Task.sleep(for: .milliseconds(700))
    #expect(controller.favicon == nil)

    #expect(FaviconLoader.sameOrigin(URL(string: "https://a.com/"), URL(string: "https://a.com:443/example")))
    #expect(!FaviconLoader.sameOrigin(URL(string: "https://a.com/"), URL(string: "http://a.com/example")))
    #expect(!FaviconLoader.sameOrigin(URL(string: "https://a.com/"), URL(string: "https://other.a.com/example")))
}

// @lat: [[tests#Favicon request security]]
@Test @MainActor func faviconRequestSecurity() async throws {
    _ = NSApplication.shared
    let target = try await FaviconHTTPFixture.start()
    let server = try await FaviconHTTPFixture.start(redirect: target.url("/icon.png"))
    defer { server.listener.cancel(); target.listener.cancel() }
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: configuration)
    let navigation = FaviconTestNavigation(); web.navigationDelegate = navigation
    try await navigation.load(web, url: server.url("/blocked"))
    let candidates = await FaviconLoader.candidates(in: web, pageURL: server.url("/blocked"))
    #expect(await FaviconLoader.load(candidates, in: web) == nil)
    #expect(!server.paths.contains("/icon.png") && !server.paths.contains("/favicon.ico"))
    #expect(!target.paths.contains("/icon.png"))

    // A permitted URL redirecting outside img-src must not escape the policy.
    try await navigation.load(web, url: server.url("/redirect-page"))
    #expect(await FaviconLoader.load([server.url("/redirect")], in: web) == nil)
    #expect(server.paths.contains("/redirect"))
    #expect(!target.paths.contains("/icon.png"))

    try await navigation.load(web, url: server.url("/page"))
    #expect(await FaviconLoader.load([target.url("/icon.png")], in: web) == nil)
    #expect(await FaviconLoader.load([target.url("/cors.png")], in: web)?.isValid == true)
    #expect(target.requests.contains { $0.lowercased().contains("\r\norigin: ") })

    // Page code must not replace the isolated world's loader or canvas encoder.
    _ = try await web.evaluateJavaScript("window.Image = function() { throw Error('page override'); }; HTMLCanvasElement.prototype.toDataURL = () => 'spoof'; void 0")
    #expect(await FaviconLoader.load([server.url("/icon.png")], in: web)?.isValid == true)
}

// @lat: [[tests#Sidebar favicons]]
@Test @MainActor func sidebarFavicons() async throws {
    _ = NSApplication.shared
    let server = try await FaviconHTTPFixture.start()
    defer { server.listener.cancel() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendSidebarIcons-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let tab = BrowserTab(pages: [Page(address: server.url("/page").absoluteString)])
    let lazy = BrowserTab(pages: [Page(address: server.url("/page").absoluteString)])
    store.session.workspaces = [Workspace(name: "Test", tabs: [tab, lazy])]
    store.session.selectedTab = tab.id
    let context = BrowserWindowSession(id: UUID().uuidString, store: store)
    context.window.orderFront(nil)
    context.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    defer { context.window.close() }
    func find(_ view: NSView) -> SidebarTabIconView? {
        if let icon = view as? SidebarTabIconView, icon.tabID == tab.id { return icon }
        return view.subviews.lazy.compactMap(find).first
    }
    func settle(_ ready: () -> Bool) async throws {
        for _ in 0..<200 where !ready() {
            context.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready())
    }
    try await settle { store.existingController(for: tab.pages[0].id)?.favicon != nil }
    let controller = try #require(store.existingController(for: tab.pages[0].id))
    let image = try #require(controller.favicon)
    try await settle { find(context.window.contentView!)?.image === image }
    let icon = try #require(find(context.window.contentView!))
    #expect(icon.frame.width == 16)
    #expect(icon.frame.height == 16)
    #expect(store.existingController(for: lazy.pages[0].id) == nil)
    // A visible 64-point raster catches intrinsic sizing and overflow that a
    // transparent network fixture cannot reveal in a rendered sidebar.
    controller.favicon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        NSColor.white.setFill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: 24, y: 16))
        triangle.line(to: NSPoint(x: 48, y: 32))
        triangle.line(to: NSPoint(x: 24, y: 48))
        triangle.close(); triangle.fill()
        return true
    }
    try await settle { icon.image === controller.favicon }
    for width in [100.0, 300.0, 236.0] {
        store.resizeSidebar(to: width)
        context.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        #expect(icon.frame.size == NSSize(width: 16, height: 16))
    }
    if let path = ProcessInfo.processInfo.environment["BEND_SIDEBAR_SNAPSHOT"] {
        let content = try #require(context.window.contentView)
        let rect = NSRect(x: 0, y: 0, width: store.sidebarWidth, height: content.bounds.height)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: rect))
        content.cacheDisplay(in: rect, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    let rendered = icon.image
    controller.navigate("browse://start")
    try await settle { find(context.window.contentView!)?.image !== rendered }
    #expect(find(context.window.contentView!)?.image != nil)
}

private final class FaviconHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var recorded: [String] = []
    var requests: [String] { lock.withLock { recorded } }
    var paths: [String] { requests.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) } }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }
    private init() throws { listener = try NWListener(using: .tcp, on: .any) }
    @MainActor static func start(redirect: URL? = nil) async throws -> FaviconHTTPFixture {
        let server = try FaviconHTTPFixture()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        server.listener.newConnectionHandler = { [weak server] connection in
            guard let server else { connection.cancel(); return }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                server.lock.withLock { server.recorded.append(request) }
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                var headers = "Content-Type: image/png\r\n"
                var status = "200 OK"
                var body = png
                if path == "/page" || path == "/next" {
                    headers = "Content-Type: text/html\r\n"
                    body = Data("<body><a id='next' href='/next'>Next page</a></body>".utf8)
                }
                if path == "/slow-icon-page" {
                    headers = "Content-Type: text/html\r\n"
                    body = Data("<link rel='icon' href='/slow'><body>Slow icon</body>".utf8)
                }
                if path == "/broken" { body = Data("not an image".utf8) }
                if path == "/cors.png" { headers += "Access-Control-Allow-Origin: *\r\n" }
                if path == "/redirect", let redirect { status = "302 Found"; headers += "Location: \(redirect.absoluteString)\r\n"; body = Data() }
                if path == "/blocked" || path == "/redirect-page" {
                    let policy = path == "/blocked" ? "'none'" : "'self'"
                    headers = "Content-Type: text/html\r\nContent-Security-Policy: img-src \(policy)\r\n"
                    body = Data("<link rel='icon' href='/icon.png'><link rel='icon' href='\(redirect?.absoluteString ?? "")'><body>Restricted</body>".utf8)
                }
                let head = "HTTP/1.1 \(status)\r\n\(headers)Cache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                let response = Data(head.utf8) + body
                if path == "/slow" || path == "/next" {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                } else {
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
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
