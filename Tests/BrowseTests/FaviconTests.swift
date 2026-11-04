import AppKit
import Testing
import WebKit
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion?.resume(); completion = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error); completion = nil
    }
}

// @lat: [[tests#Favicon fallback and cancellation]]
@Test @MainActor func faviconFallback() async throws {
    let broken = URL(string: "https://example.com/broken.png")!
    let fallback = URL(string: "https://example.com/favicon.ico")!
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    var requests: [URL] = []
    let image = await FaviconLoader.load([broken, fallback]) { url in
        requests.append(url)
        return url == broken ? Data("not an image".utf8) : png
    }
    #expect(image?.isValid == true)
    #expect(requests == [broken, fallback])

    // Cancellation during a fetch must discard even a successfully decoded response.
    let task = Task { @MainActor in
        await FaviconLoader.load([fallback]) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return png
        }
    }
    #expect(await task.value == nil)
}

// @lat: [[tests#Favicon navigation reset]]
@Test @MainActor func faviconNavigationReset() {
    _ = NSApplication.shared
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let web = FocusWebView(frame: .zero, configuration: config)
    let controller = PageController(address: "browse://start", webView: web)
    controller.favicon = NSImage(size: NSSize(width: 16, height: 16))
    controller.webView(web, didStartProvisionalNavigation: nil)
    #expect(controller.favicon == nil)
    controller.favicon = NSImage(size: NSSize(width: 16, height: 16))
    controller.navigate("browse://guide")
    #expect(controller.favicon == nil)
}
