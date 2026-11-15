import AppKit
import WebKit
import Testing
import BrowseCore
@testable import Browse

// @lat: [[lat.md/tests/web-pages-tests#Web pages tests#Website permission isolation]]
@Test @MainActor func websitePermissionIsolation() async throws {
    _ = NSApplication.shared
    let settings = WebsiteSettingsStore(temporary: WebsiteSettings())
    let page = PageController(address: "bend://start", websiteSettings: settings) { $0.websiteDataStore = .nonPersistent() }
    defer { page.stopCapture(); page.media.detach(); page.webView.stopLoading() }
    page.webView.loadHTMLString("<title>Permissions</title>", baseURL: URL(string: "https://top.example/"))
    for _ in 0..<100 where page.permissionOrigin == nil { try await Task.sleep(for: .milliseconds(20)) }
    let top = try #require(page.permissionOrigin)
    let child = URL(string: "https://child.example:8443")!
    #expect(page.permissionDecision([.camera], requesting: child) == .prompt)
    settings.setBlocked(true, permission: .camera, origin: top)
    #expect(page.permissionDecision([.camera, .microphone], requesting: child) == .deny)
    #expect(page.permissionDecision([.microphone], requesting: child) == .prompt)
    settings.setBlocked(false, permission: .camera, origin: top)
    settings.setBlocked(true, permission: .location, origin: WebsitePermission.origin(for: child)!)
    #expect(page.permissionDecision([.location], requesting: child) == .deny)
    #expect(page.permissionDecision([.location], requesting: URL(string: "https://child.example")) == .prompt)
    #expect(page.permissionDecision([.camera], requesting: URL(string: "file:///tmp/test")) == .deny)
    settings.setPermission(.allow, permission: .camera, origin: top)
    #expect(page.permissionDecision([.camera], requesting: URL(string: top)) == .grant)
    #expect(page.permissionDecision([.camera, .microphone], requesting: URL(string: top)) == .prompt)
    #expect(page.permissionDecision([.camera], requesting: child) == .prompt)
    settings.setPermission(.allow, permission: .camera, origin: WebsitePermission.origin(for: child)!)
    #expect(page.permissionDecision([.camera], requesting: child) == .prompt)
    settings.setPermission(.block, permission: .camera, origin: top)
    #expect(page.permissionDecision([.camera], requesting: URL(string: top)) == .deny)
    #expect(settings.values.allowedPermissions[top] == nil)
    settings.setPermission(.ask, permission: .camera, origin: top)
    #expect(page.permissionDecision([.camera], requesting: URL(string: top)) == .prompt)
    let privateSettings = WebsiteSettingsStore(temporary: settings.values)
    privateSettings.setBlocked(true, permission: .microphone, origin: top)
    #expect(settings.values.blockedPermissions[top] == nil)
    privateSettings.resetTemporary()
    #expect(privateSettings.values.blockedPermissions.isEmpty)
}

@MainActor private final class UploadTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

// @lat: [[lat.md/tests/web-pages-tests#Web pages tests#Website upload lifecycle]]
@Test @MainActor func websiteUploadLifecycle() async throws {
    _ = NSApplication.shared
    let window = UploadTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let web = FocusWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
    let page = PageController(address: "bend://start", webView: web)
    defer { page.fileUpload.cancel(); page.media.detach(); web.stopLoading() }
    #expect(page.responds(to: NSSelectorFromString("webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:")))
    #expect(page.responds(to: NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")))
    window.contentView = web
    window.orderFront(nil)
    defer { window.close() }
    var panels: [NSOpenPanel] = []
    var callbacks: [(NSApplication.ModalResponse) -> Void] = []
    let upload = WebsiteFileUpload { panel, _, callback in panels.append(panel); callbacks.append(callback) }
    var completions = 0
    upload.request(from: web, multiple: true, directories: true) { urls in
        #expect(urls == nil); completions += 1
    }
    let panel = try #require(panels.first)
    #expect(panel.allowsMultipleSelection)
    #expect(panel.canChooseDirectories)
    #expect(!panel.canChooseFiles)
    upload.request(from: web, multiple: false, directories: false) { urls in
        #expect(urls == nil); completions += 1
    }
    #expect(panels.count == 1)
    #expect(completions == 1)
    upload.cancel()
    callbacks[0](.OK)
    #expect(completions == 2)
    web.isHidden = true
    upload.request(from: web, multiple: false, directories: false) { urls in
        #expect(urls == nil); completions += 1
    }
    #expect(panels.count == 1)
    #expect(completions == 3)
    web.isHidden = false
    web.loadHTMLString("<input type=file>", baseURL: URL(string: "https://upload.example"))
    for _ in 0..<100 {
        if (try? await web.evaluateJavaScript("!!document.querySelector('input')")) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try await web.evaluateJavaScript("document.querySelector('input').click()")
    for _ in 0..<100 where page.fileUpload.panel == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(page.fileUpload.panel != nil)
    page.fileUpload.cancel()
    #expect(page.fileUpload.panel == nil)
}

// @lat: [[lat.md/tests/web-pages-tests#Remembered permission prompts]]
@Test @MainActor func websitePermissionRememberPrompt() {
    _ = NSApplication.shared
    let window = UploadTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView = web; window.orderFront(nil)
    defer { window.close() }
    var alerts: [NSAlert] = []
    var callbacks: [(NSApplication.ModalResponse) -> Void] = []
    let prompt = WebsitePermissionPrompt { alert, _, callback in alerts.append(alert); callbacks.append(callback) }
    var replies: [String] = []
    let complete: (Bool, Bool) -> Void = { replies.append("\($0):\($1)") }
    prompt.request([.camera], origin: "https://example.com:443", top: "https://example.com:443", from: web, completion: complete)
    #expect(alerts.count == 1)
    #expect(alerts[0].showsSuppressionButton)
    alerts[0].suppressionButton?.state = .on
    callbacks[0](.alertSecondButtonReturn)
    #expect(replies == ["true:true"])
    prompt.request([.microphone], origin: "https://example.com:443", top: "https://example.com:443", from: web, completion: complete)
    alerts[1].suppressionButton?.state = .on
    prompt.cancel()
    callbacks[1](.alertSecondButtonReturn)
    #expect(replies == ["true:true", "false:false"])
    prompt.request([.camera], origin: "https://child.example:443", top: "https://example.com:443", from: web, completion: complete)
    #expect(!alerts[2].showsSuppressionButton)
    callbacks[2](.alertSecondButtonReturn)
    #expect(replies.last == "true:false")
    prompt.request([.location], origin: "https://example.com:443", top: "https://example.com:443", from: web, completion: complete)
    alerts[3].suppressionButton?.state = .on
    callbacks[3](.alertFirstButtonReturn)
    #expect(replies.last == "false:true")
}

// @lat: [[lat.md/tests/web-pages-tests#Removing saved website permissions]]
@Test @MainActor func websitePermissionRemoval() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("settings.sqlite")
    let settings = WebsiteSettingsStore(file: file)
    let site = "https://example.com:443"
    let other = "https://example.com:8443"
    settings.setPermission(.allow, permission: .camera, origin: site)
    settings.setPermission(.block, permission: .location, origin: site)
    settings.setPermission(.allow, permission: .microphone, origin: other)
    settings.setZoom(1.5, forHost: "example.com")
    settings.setPermissions(.ask, permissions: WebsitePermission.allCases, origin: site)
    #expect(settings.errorMessage == nil)
    let restored = WebsiteSettingsStore(file: file)
    #expect(restored.values.permissionOrigins == [other])
    #expect(WebsitePermission.allCases.allSatisfy { restored.values.permission($0, for: site) == .ask })
    #expect(restored.values.permission(.microphone, for: other) == .allow)
    #expect(restored.values.zoomByHost["example.com"] == 1.5)
}

// @lat: [[lat.md/tests/web-pages-tests#Certificate site identity]]
@Test @MainActor func certificateSiteIdentity() {
    let committed = URL(string: "https://www.youtube.com/")!
    #expect(WebsiteCertificates.matchesSite(URL(string: "https://www.youtube.com/watch?v=test#player"), committed: committed))
    #expect(!WebsiteCertificates.matchesSite(URL(string: "https://other.example/"), committed: committed))
    #expect(!WebsiteCertificates.matchesSite(URL(string: "https://www.youtube.com:8443/"), committed: committed))
    #expect(!WebsiteCertificates.matchesSite(URL(string: "http://www.youtube.com/"), committed: committed))
    #expect(!WebsiteCertificates.matchesSite(nil, committed: committed))
}
