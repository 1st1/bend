import AppKit
import Testing
import WebKit
@testable import Browse

@MainActor private final class HoverTestWindow: NSWindow {
    var pointer = NSPoint(x: 100, y: 100)
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

// @lat: [[lat.md/tests/link-navigation-tests#Title URL preview]]
@Test @MainActor func titleURLPreview() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendTitleHover-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"))
    let page = store.selectedTab.pages[0]
    let controller = store.controller(for: page)
    controller.isStartPage = false
    controller.address = "https://example.com/page?q=a%20b"
    let web = controller.webView
    let host = WebSurfaceHost(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let window = HoverTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.update(webView: web, topContentInset: 40)
    window.orderFront(nil)
    defer { window.close() }
    let handle = PaneDragSourceView(frame: NSRect(x: 50, y: 360, width: 200, height: 40))
    handle.store = store; handle.pageID = page.id; handle.tabID = store.selectedTab.id
    host.addSubview(handle)
    window.pointer = NSPoint(x: 100, y: 380)
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: window.pointer,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 0, pressure: 0))
    handle.mouseEntered(with: event)
    #expect(handle.isHovering)
    #expect(host.linkPreview.url == controller.address)
    #expect(!host.linkPreview.isHidden)
    // A delayed DOM pointerout must not erase the title's preview.
    web.hoveredLink = ""
    #expect(host.linkPreview.url == controller.address)
    web.hoveredLink = "https://example.com/stale-link"
    #expect(host.linkPreview.url == controller.address)
    // Native title exit can lag behind the page's pointerover message.
    window.pointer = NSPoint(x: 100, y: 100)
    web.hoveredLink = "https://github.com/signup?source=form-home-signup&user_email="
    #expect(host.linkPreview.url == web.hoveredLink)
    handle.mouseExited(with: event)
    #expect(host.linkPreview.url == web.hoveredLink)
    web.hoveredLink = ""
    #expect(host.linkPreview.isHidden)
    window.pointer = NSPoint(x: 100, y: 100)
    web.hoveredLink = "https://example.com/link"
    #expect(host.linkPreview.url == web.hoveredLink)
    window.pointer = NSPoint(x: 100, y: 380)
    handle.mouseEntered(with: event)
    handle.mouseDown(with: event)
    #expect(host.linkPreview.isHidden)
    handle.cancelDrag()
    handle.mouseExited(with: event)
    handle.mouseEntered(with: event)
    web.clearURLPreview()
    #expect(host.linkPreview.isHidden)
    handle.mouseExited(with: event)
    handle.mouseEntered(with: event)
    handle.viewDidHide()
    #expect(host.linkPreview.isHidden)
    #expect(!handle.isHovering)
    handle.mouseEntered(with: event)
    handle.removeFromSuperview()
    #expect(host.linkPreview.isHidden)
    #expect(LinkHoverObserver.displayURL("https://example.com/\u{202E}path\n") == "https://example.com/path")
}

// @lat: [[lat.md/tests/link-navigation-tests#Link hover preview]]
@Test @MainActor func linkHoverPreview() async throws {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start")
    let web = controller.webView
    let window = HoverTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = WebSurfaceHost(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView = host
    host.update(webView: web, topContentInset: 40)
    window.orderFront(nil)
    defer { window.close() }
    web.loadHTMLString("""
        <title>Hover test</title>
        <a href="../destination?q=a%20b"><span id="nested">Link</span></a>
        <div id="plain">Plain text</div><div id="shadow"></div>
        <iframe srcdoc="<a id='inside' href='https://frame.example/path'>Frame</a>"></iframe>
        <script>
        document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML =
          '<a href="mailto:hello@example.com"><span>Shadow link</span></a>';
        </script>
        """, baseURL: URL(string: "https://example.com/folder/page"))
    for _ in 0..<100 {
        if (try? await web.evaluateJavaScript("document.querySelector('iframe')?.contentDocument?.querySelector('#inside') != null")) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    func hover(_ expression: String, expected: String) async throws {
        _ = try await web.evaluateJavaScript("\(expression).dispatchEvent(new PointerEvent('pointerover', {bubbles:true, composed:true})); void 0")
        for _ in 0..<100 where web.hoveredLink != expected { try await Task.sleep(for: .milliseconds(10)) }
        #expect(web.hoveredLink == expected)
        #expect(host.linkPreview.url == expected)
        #expect(host.linkPreview.isHidden == expected.isEmpty)
    }
    try await hover("document.querySelector('#nested')", expected: "https://example.com/destination?q=a%20b")
    try await hover("document.querySelector('#plain')", expected: "")
    try await hover("document.querySelector('#shadow').shadowRoot.querySelector('span')", expected: "mailto:hello@example.com")
    try await hover("document.querySelector('iframe').contentDocument.querySelector('#inside')", expected: "https://frame.example/path")
    _ = try await web.evaluateJavaScript("document.querySelector('iframe').contentDocument.querySelector('#inside').dispatchEvent(new PointerEvent('pointerout', {bubbles:true})); void 0")
    for _ in 0..<100 where !web.hoveredLink.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(web.hoveredLink.isEmpty)
    #expect(host.linkPreview.isHidden)
    #expect(host.subviews.last === host.linkPreview)
    #expect(host.hitTest(NSPoint(x: 20, y: 15)) !== host.linkPreview)
    // The bridge belongs to an isolated world, not the site's JavaScript world.
    #expect(try await web.evaluateJavaScript("typeof window.webkit?.messageHandlers?.bendLinkHover") as? String == "undefined")
    try await hover("document.querySelector('#nested')", expected: "https://example.com/destination?q=a%20b")
    // Native movement must reposition even while the DOM stays on one link
    // and the isolated script suppresses duplicate URL messages.
    let nearPreview = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 20, y: 16),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 0, pressure: 0))
    host.mouseMoved(with: nearPreview)
    #expect(host.linkPreview.frame.maxX == host.bounds.maxX - 8)
    let rightFrame = host.linkPreview.frame
    host.mouseMoved(with: nearPreview)
    #expect(host.linkPreview.frame == rightFrame)
    let away = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 100, y: 100),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 0, pressure: 0))
    host.mouseMoved(with: away)
    #expect(host.linkPreview.frame.minX == 8)
    web.loadHTMLString("<title>Next page</title>", baseURL: nil)
    for _ in 0..<100 where !web.hoveredLink.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(web.hoveredLink.isEmpty)

    let preview = LinkHoverPreview()
    let signupURL = "https://github.com/signup?source=form-home-signup&user_email="
    for address in ["https://github.com/", signupURL, "https://github.com/site/terms"] {
        preview.url = address
        preview.place(in: NSRect(x: 0, y: 0, width: 900, height: 400))
        let textWidth = (address as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        #expect(preview.frame.width >= ceil(textWidth) + 14)
        let label = try #require(preview.subviews.first as? NSTextField)
        let drawingRect = try #require(label.cell?.drawingRect(forBounds: label.bounds))
        #expect(drawingRect.width >= ceil(textWidth))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 60))
        container.addSubview(preview)
        func render() throws -> NSBitmapImageRep {
            let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: bitmap)
            return bitmap
        }
        let bitmap = try render()
        // With enough room, truncation and clipping must render identical text.
        // Width-only assertions miss the text cell's internal layout padding.
        label.lineBreakMode = .byClipping
        let untruncated = try render()
        #expect(bitmap.representation(using: .png, properties: [:]) ==
                untruncated.representation(using: .png, properties: [:]))
        label.lineBreakMode = .byTruncatingMiddle
        if let directory = ProcessInfo.processInfo.environment["BEND_URL_PREVIEW_SNAPSHOTS"] {
            let name = address.contains("signup") ? "signup" : address.contains("terms") ? "terms" : "home"
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        preview.removeFromSuperview()
    }
    preview.url = "https://example.com/" + String(repeating: "long-path/", count: 100)
    preview.place(in: NSRect(x: 0, y: 0, width: 240, height: 400))
    #expect(!preview.isHidden)
    #expect(preview.frame.minX == 8 && preview.frame.minY == 8)
    #expect(preview.frame.maxX <= 232)
    #expect(preview.hitTest(NSPoint(x: 10, y: 10)) == nil)
    preview.place(in: NSRect(x: 0, y: 0, width: 240, height: 400), avoiding: NSPoint(x: 20, y: 16))
    #expect(preview.frame.minX >= 32 && preview.frame.maxX == 232)
    preview.place(in: NSRect(x: 0, y: 0, width: 240, height: 400), avoiding: NSPoint(x: 200, y: 16))
    #expect(preview.frame.minX == 8 && preview.frame.maxX <= 188)
    preview.place(in: NSRect(x: 0, y: 0, width: 120, height: 400), avoiding: NSPoint(x: 20, y: 16))
    #expect(preview.frame.minX >= 32 && preview.frame.maxX == 112)
    preview.url = ""
    #expect(preview.isHidden)
}
