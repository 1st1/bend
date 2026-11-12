import AppKit
import SwiftUI
import Testing
import WebKit
import Network
import Combine
import BrowseCore
@testable import Browse

// @lat: [[lat.md/tests/favicons-tests#Favicon discovery]]
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

// @lat: [[lat.md/tests/favicons-tests#Favicon fallback and cancellation]]
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

// @lat: [[lat.md/tests/favicons-tests#Favicon history navigation]]
@Test @MainActor func faviconHistoryNavigation() async throws {
    _ = NSApplication.shared
    let server = try await FaviconHTTPFixture.start()
    defer { server.listener.cancel() }
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = FocusWebView(frame: .zero, configuration: configuration)
    let page = PageController(address: server.url("/spa-media-page").absoluteString, webView: web)
    defer { page.media.detach(); web.stopLoading() }
    for _ in 0..<200 where !server.paths.contains("/slow") { try await Task.sleep(for: .milliseconds(10)) }
    try #require(server.paths.contains("/slow"))
    try #require(page.media.sessions.first?.playing == true)
    // A video site's client-side navigation changes the URL while its first
    // favicon is loading, without triggering another didFinish callback.
    _ = try await web.evaluateJavaScript("history.replaceState({}, '', '/watch?v=next'); void 0")
    for _ in 0..<200 where page.favicon == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(page.favicon?.isValid == true)
    #expect(page.media.sessions.first?.playing == true)
    #expect(web.url?.path == "/watch")
}

// @lat: [[lat.md/tests/favicons-tests#Favicon navigation reset]]
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

// @lat: [[lat.md/tests/favicons-tests#Favicon request security]]
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

// @lat: [[lat.md/tests/favicons-tests#Sidebar favicons]]
@Test @MainActor func sidebarFavicons() async throws {
    _ = NSApplication.shared
    let server = try await FaviconHTTPFixture.start()
    defer { server.listener.cancel() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendSidebarIcons-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let tab = BrowserTab(pages: [Page(address: server.url("/page").absoluteString)])
    let lazy = BrowserTab(pages: (0..<3).map { _ in Page(address: server.url("/page").absoluteString) })
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
    try await settle { find(context.window.contentView!)?.frontIcon.image === image }
    let icon = try #require(find(context.window.contentView!))
    #expect(icon.frontIcon.frame.width == 16)
    #expect(icon.frontIcon.frame.height == 16)
    #expect(lazy.pages.allSatisfy { store.existingController(for: $0.id) == nil })
    // A visible 64-point raster catches intrinsic sizing and overflow that a
    // transparent network fixture cannot reveal in a rendered sidebar.
    controller.favicon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.systemRed.setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.white.setFill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: 24, y: 16))
        triangle.line(to: NSPoint(x: 48, y: 32))
        triangle.line(to: NSPoint(x: 24, y: 48))
        triangle.close(); triangle.fill()
        return true
    }
    try await settle { icon.frontIcon.image === controller.favicon }
    for width in [200.0, 400.0, 250.0] {
        store.resizeSidebar(to: width)
        context.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        #expect(icon.frontIcon.frame.size == NSSize(width: 16, height: 16))
    }
    // Three panes still render exactly two icons, with focus deciding the front.
    store.onAddressRequested = nil
    store.split(.horizontal)
    let secondPage = store.selectedTab.pages.last!
    let second = store.controller(for: secondPage)
    second.isStartPage = false
    let blue = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.systemBlue.setFill(); NSBezierPath(rect: rect).fill(); return true
    }
    second.favicon = blue
    try await settle { icon.frontIcon.image === blue && icon.backIcon.image === controller.favicon && icon.paneCount == 2 }
    store.split(.horizontal)
    let thirdPage = store.selectedTab.pages.last!
    let third = store.controller(for: thirdPage)
    third.isStartPage = false
    let green = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.systemGreen.setFill(); NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill(); return true
    }
    third.favicon = green
    try await settle { icon.frontIcon.image === green && icon.paneCount == 3 }
    #expect(icon.backIcon.image === controller.favicon)
    #expect(icon.subviews.compactMap { $0 as? NSImageView }.count == 2)
    #expect(!icon.subviews.contains { $0 is NSTextField })
    store.focus(tab.pages[0].id)
    try await settle { icon.frontIcon.image === controller.favicon && icon.backIcon.image === blue }
    for width in [200.0, 400.0, 250.0] {
        store.resizeSidebar(to: width)
        context.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        #expect(icon.frame.size == SidebarTabIconView.slotSize)
        #expect(icon.frontIcon.frame.size == NSSize(width: 16, height: 16))
        #expect(icon.backIcon.frame.size == NSSize(width: 12, height: 12))
        #expect(!icon.backIcon.isHidden)
        #expect(abs(icon.backIcon.frame.midX - icon.frontIcon.frame.midX) < 0.01)
        #expect(abs(icon.frontIcon.frame.union(icon.backIcon.frame).midY - icon.bounds.midY) < 0.01)
    }
    #expect(lazy.pages.allSatisfy { store.existingController(for: $0.id) == nil })
    let renderedStack = try #require(icon.bitmapImageRepForCachingDisplay(in: icon.bounds))
    icon.cacheDisplay(in: icon.bounds, to: renderedStack)
    let scale = CGFloat(renderedStack.pixelsWide) / icon.bounds.width
    func brightness(at y: CGFloat) throws -> CGFloat {
        let color = try #require(renderedStack.colorAt(x: Int(icon.backIcon.frame.midX * scale),
            y: Int(y * scale))?.usingColorSpace(.sRGB))
        return color.redComponent + color.greenComponent + color.blueComponent
    }
    // The exposed back icon darkens toward the front icon's overlapping edge.
    #expect(try brightness(at: icon.backIcon.frame.minY + 3) < brightness(at: icon.backIcon.frame.minY + 1) * 0.95)
    if let path = ProcessInfo.processInfo.environment["BEND_SIDEBAR_SNAPSHOT"] {
        let content = try #require(context.window.contentView)
        let rect = NSRect(x: 0, y: 0, width: store.sidebarWidth, height: content.bounds.height)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: rect))
        content.cacheDisplay(in: rect, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    store.closePane(secondPage.id)
    try await settle { icon.paneCount == 2 && icon.backIcon.image === green }
    store.closePane(thirdPage.id)
    try await settle { icon.paneCount == 1 && icon.backIcon.isHidden }
    let rendered = icon.frontIcon.image
    controller.navigate("browse://start")
    try await settle { find(context.window.contentView!)?.frontIcon.image !== rendered }
    #expect(find(context.window.contentView!)?.frontIcon.image != nil)
}

// @lat: [[lat.md/tests/favicons-tests#Stacked favicon transitions]]
@Test @MainActor func stackedFaviconTransitions() throws {
    _ = NSApplication.shared
    let icon = SidebarTabIconView(frame: NSRect(origin: .zero, size: SidebarTabIconView.slotSize))
    let window = NSWindow(contentRect: icon.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = icon
    defer { window.contentView = nil }
    let first = UUID(), second = UUID(), third = UUID()
    icon.updateStack(front: first, back: nil, count: 1, animate: true)
    #expect(icon.frontIcon.layer?.animation(forKey: "stackFade") == nil)
    icon.updateStack(front: second, back: first, count: 2, animate: true)
    #expect(icon.frontIcon.layer?.animation(forKey: "stackFade") != nil)
    #expect(icon.backIcon.layer?.animation(forKey: "stackFade") != nil)
    icon.frontIcon.layer?.removeAllAnimations()
    icon.backIcon.layer?.removeAllAnimations()
    icon.updateStack(front: second, back: first, count: 2, animate: true)
    #expect(icon.frontIcon.layer?.animation(forKey: "stackFade") == nil)
    #expect(icon.backIcon.layer?.animation(forKey: "stackFade") == nil)
    icon.updateStack(front: first, back: second, count: 2, animate: true)
    #expect(icon.frontIcon.layer?.animation(forKey: "stackFade") != nil)
    icon.updateStack(front: third, back: first, count: 3, animate: false)
    #expect(icon.frontIcon.layer?.animation(forKey: "stackFade") == nil)
    #expect(icon.backIcon.layer?.animation(forKey: "stackFade") == nil)
    #expect(icon.frontIcon.alphaValue == 1)
    #expect(icon.backIcon.alphaValue == 0.65)
    icon.updateStack(front: first, back: third, count: 2, animate: true)
    icon.updateStack(front: first, back: nil, count: 1, animate: true)
    #expect(icon.frontIcon.layer?.animation(forKey: "stackFade") == nil)
    #expect(icon.backIcon.isHidden)
}

// @lat: [[lat.md/tests/favicons-tests#Persistent favicon restoration]]
@Test @MainActor func persistentFaviconRestoration() async throws {
    _ = NSApplication.shared
    let server = try await FaviconHTTPFixture.start()
    defer { server.listener.cancel() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFaviconCache-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    let page = Page(address: server.url("/page").absoluteString)
    let lazy = BrowserTab(pages: [page, Page(address: server.url("/next").absoluteString)])
    store.session.workspaces = [Workspace(name: "Tabs", tabs: [lazy])]
    store.session.selectedTab = lazy.id
    func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<200 where !ready() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(ready())
    }
    let controller = store.controller(for: page)
    try await waitUntil { controller.favicon != nil }
    store.save()
    let cacheFile = root.appendingPathComponent("Favicons.json")
    #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    store.stopWindow()

    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    defer { restored.stopWindow() }
    #expect(restored.favicon(for: page) != nil)
    #expect(lazy.pages.allSatisfy { restored.existingController(for: $0.id) == nil })
    let host = NSHostingView(rootView: SidebarTabIcon(store: restored, tab: lazy)
        .frame(width: 24, height: 28))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 24, height: 28),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host; window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func icon(_ view: NSView) -> SidebarTabIconView? {
        (view as? SidebarTabIconView) ?? view.subviews.lazy.compactMap(icon).first
    }
    try await waitUntil { host.layoutSubtreeIfNeeded(); return icon(host)?.paneCount == 2 }
    let mounted = try #require(icon(host))
    #expect(mounted.frontIcon.image === restored.favicon(for: page))
    #expect(mounted.backIcon.image === restored.favicon(for: lazy.pages[1]))
    #expect(lazy.pages.allSatisfy { restored.existingController(for: $0.id) == nil })
    let other = BrowserStore(sessionFile: root.appendingPathComponent("window/session.json"), persistentExtensions: false, sharedStore: restored)
    defer { other.stopWindow() }
    #expect(other.faviconCache === restored.faviconCache)
    #expect(other.favicon(for: page) != nil)
    let separate = BrowserStore(sessionFile: root.appendingPathComponent("separate/session.json"), persistentExtensions: false)
    defer { separate.stopWindow() }
    #expect(separate.favicon(for: page) == nil)

    // A live controller starts with the cache, then refreshes through WebKit.
    let live = restored.controller(for: page)
    let seeded = try #require(live.favicon)
    try await waitUntil { live.favicon != nil && live.favicon !== seeded }
    live.navigate("browse://start")
    #expect(live.favicon == nil)
    restored.save()
    let beforePrivate = try Data(contentsOf: cacheFile)
    let privateFile = root.appendingPathComponent("private/session.json")
    let privateStore = BrowserStore(sessionFile: privateFile, persistentExtensions: false, sharedStore: restored, isPrivate: true)
    #expect(privateStore.faviconCache == nil)
    #expect(privateStore.favicon(for: page) == nil)
    let privatePage = privateStore.controller(for: page)
    #expect(privatePage.favicon == nil)
    try await waitUntil { privatePage.favicon != nil }
    privateStore.save(); privateStore.clearHistory(); privateStore.stopWindow()
    #expect(try Data(contentsOf: cacheFile) == beforePrivate)
    #expect(!FileManager.default.fileExists(atPath: privateFile.deletingLastPathComponent().path))
    #expect(privateStore.favicon(for: page) == nil)

    restored.clearHistory()
    #expect(restored.faviconCache?.image(for: server.url("/page")) == nil)
    #expect(FaviconCache(file: cacheFile).image(for: server.url("/page")) == nil)
}

// @lat: [[lat.md/tests/favicons-tests#Favicon cache bounds and recovery]]
@Test @MainActor func faviconCacheBoundsAndRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFaviconBounds-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Favicons.json")
    let cache = FaviconCache(file: file, limit: 2)
    let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.red.setFill(); NSBezierPath(rect: rect).fill(); return true
    }
    let url = URL(string: "https://user:password@Example.com/path?secret=value#fragment")!
    cache.record(image, for: url); cache.flush()
    let data = try Data(contentsOf: file)
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("password") && !json.contains("secret") && !json.contains("fragment"))
    let loaded = FaviconCache(file: file)
    let restoredImage = try #require(loaded.image(for: URL(string: "https://example.com:443/elsewhere")))
    let tiff = try #require(restoredImage.tiffRepresentation)
    let pixels = try #require(NSBitmapImageRep(data: tiff))
    let color = try #require(pixels.colorAt(x: 32, y: 32)?.usingColorSpace(.sRGB))
    let originalTIFF = try #require(image.tiffRepresentation)
    let originalPixels = try #require(NSBitmapImageRep(data: originalTIFF))
    let expected = try #require(originalPixels.colorAt(x: 32, y: 32)?.usingColorSpace(.sRGB))
    #expect(abs(color.redComponent - expected.redComponent) < 0.02)
    #expect(abs(color.greenComponent - expected.greenComponent) < 0.02)
    #expect(abs(color.blueComponent - expected.blueComponent) < 0.02)
    #expect(color.alphaComponent > 0.99)
    for different in ["http://example.com/", "https://example.com:444/", "https://other.example.com/", "browse://start"] {
        #expect(loaded.image(for: URL(string: different)) == nil)
    }
    cache.record(image, for: URL(string: "https://b.example/")!)
    cache.record(image, for: URL(string: "https://c.example/")!)
    cache.flush()
    let bounded = FaviconCache(file: file)
    #expect(bounded.image(for: url) == nil)
    #expect(bounded.image(for: URL(string: "https://b.example/")) != nil)
    #expect(bounded.image(for: URL(string: "https://c.example/")) != nil)
    try Data("corrupt cache".utf8).write(to: file)
    let recovered = FaviconCache(file: file)
    #expect(recovered.image(for: url) == nil)
    recovered.record(image, for: url); recovered.flush()
    #expect(FaviconCache(file: file).image(for: url) != nil)
    var invalid = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var entries = try #require(invalid["entries"] as? [String: [String: Any]])
    let key = try #require(entries.keys.first)
    entries[key]?["png"] = Data("invalid image".utf8).base64EncodedString()
    invalid["entries"] = entries
    try JSONSerialization.data(withJSONObject: invalid).write(to: file)
    #expect(FaviconCache(file: file).image(for: url) == nil)
    let blocked = root.appendingPathComponent("not-a-directory")
    try Data().write(to: blocked)
    let memory = FaviconCache(file: blocked.appendingPathComponent("Favicons.json"))
    memory.record(image, for: url); memory.flush()
    #expect(memory.image(for: url) != nil)
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
                if path == "/spa-media-page" {
                    headers = "Content-Type: text/html\r\n"
                    body = Data("""
                        <link rel='icon' href='/slow'><script>
                        navigator.mediaSession.setPositionState({duration:60});
                        navigator.mediaSession.playbackState = 'playing';
                        </script><body>Media page</body>
                        """.utf8)
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
