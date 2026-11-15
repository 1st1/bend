import AppKit
import WebKit
import BrowseCore

// @lat: [[lat.md/architecture/web-pages#Browser capability diagnostics]]
@MainActor
final class WebCapabilityProbe: NSObject, NSWindowDelegate {
    private var page: PageController?
    private var window: NSWindow?

    static func run() {
        let app = NSApplication.shared
        let probe = WebCapabilityProbe()
        app.setActivationPolicy(.regular)
        guard let file = Bundle.main.url(forResource: "BrowserCapabilities", withExtension: "html"),
              let html = try? String(contentsOf: file, encoding: .utf8) else {
            print("Run this diagnostic from a packaged Bend app."); return
        }
        let page = PageController(address: "bend://start", isPrivate: true,
                                  websiteSettings: WebsiteSettingsStore(temporary: WebsiteSettings())) {
            $0.websiteDataStore = .nonPersistent()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 780),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Bend — Browser Capability Checks"
        window.isReleasedWhenClosed = false
        window.contentView = page.webView
        window.delegate = probe
        probe.page = page; probe.window = window
        // A synthetic HTTPS origin permits feature detection without contacting
        // a website. Background push needs an actual server and is not tested.
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://capability-check.bend.invalid/"))
        window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(probe) { app.run() }
    }

    func windowWillClose(_ notification: Notification) {
        page?.permissionPrompt.cancel()
        page?.fileUpload.cancel()
        page?.stopCapture()
        page?.webView.stopLoading()
        NSApp.stop(nil)
    }
}
