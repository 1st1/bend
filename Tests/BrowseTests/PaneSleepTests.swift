import AppKit
import SwiftUI
import Testing
import WebKit
import BrowseCore
@testable import Browse

// @lat: [[lat.md/tests/pane-sleep-tests#Timeouts and uncertain replies]]
@Test @MainActor func paneSleepPolicyAndDeadline() async {
    #expect(PaneSleepPolicy.timeout(lowPower: false, pressure: .normal) == 1800)
    #expect(PaneSleepPolicy.timeout(lowPower: true, pressure: .normal) == 600)
    #expect(PaneSleepPolicy.timeout(lowPower: false, pressure: .warning) == 300)
    #expect(PaneSleepPolicy.timeout(lowPower: false, pressure: .critical) == 60)
    var late: (@MainActor (Bool?) -> Void)?
    let value: Bool? = await sleepReply(seconds: 0.01) { late = $0 }
    #expect(value == nil)
    late?(true) // Late replies cannot resume a completed operation twice.
    let missing: Bool? = await sleepReply(seconds: 0.01) { _ in }
    #expect(missing == nil)
}

@MainActor
private func sleepLoaded(_ web: WKWebView) async throws {
    for _ in 0..<100 {
        if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Test document did not load")
}

// @lat: [[lat.md/tests/pane-sleep-tests#Draft and activity protection]]
@Test @MainActor func paneSleepDraftChecks() async throws {
    _ = NSApplication.shared
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    PaneSleepProbe.install(in: config.userContentController)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = web
    defer { web.stopLoading(); window.contentView = nil }
    func load(_ body: String) async throws {
        web.loadHTMLString("<!doctype html><body>\(body)</body>", baseURL: URL(string: "https://example.test"))
        try await sleepLoaded(web)
    }
    try await load("<p>Read-only page</p>")
    #expect(await PaneSleepProbe.check(web) != nil)
    for body in ["<textarea>original</textarea>", "<input value='original'>"] {
        try await load(body)
        #expect(await PaneSleepProbe.check(web) != nil)
        _ = try await web.evaluateJavaScript("document.querySelector('input,textarea').value='draft'")
        #expect(await PaneSleepProbe.check(web) == nil)
    }
    try await load("<input value=''>")
    _ = try await web.evaluateJavaScript("document.querySelector('input').dispatchEvent(new Event('input', {bubbles:true}))")
    #expect(await PaneSleepProbe.check(web) == nil)
    for body in ["<div contenteditable>draft</div>", "<iframe srcdoc='<p>embedded</p>'></iframe>",
                 "<custom-editor></custom-editor>", "<input type='checkbox' checked>"] {
        try await load(body)
        if body.contains("checkbox") { _ = try await web.evaluateJavaScript("document.querySelector('input').checked=false") }
        #expect(await PaneSleepProbe.check(web) == nil)
    }
    try await load("<p>Call</p>")
    _ = try await web.evaluateJavaScript("window.call = new RTCPeerConnection(); window.call.close()")
    #expect(await PaneSleepProbe.check(web) == nil)
    try await load("<div id='host'></div>")
    _ = try await web.evaluateJavaScript("document.getElementById('host').attachShadow({mode:'closed'}).innerHTML='<input value=draft>'")
    #expect(await PaneSleepProbe.check(web) == nil)
    try await load("<p>Unload guard</p>")
    _ = try await web.evaluateJavaScript("window.addEventListener('beforeunload', () => {})")
    #expect(await PaneSleepProbe.check(web) == nil)
    try await load("<p>Broken probe</p>")
    _ = try await web.callAsyncJavaScript("globalThis.__bendSleepCheck = () => { throw new Error('unknown'); }; return null;", arguments: [:], in: nil,
        contentWorld: .world(name: "Bend.PaneSleep"))
    #expect(await PaneSleepProbe.check(web) == nil)
    let unknown = WKWebView()
    unknown.loadHTMLString("<p>No tracker</p>", baseURL: nil)
    try await sleepLoaded(unknown)
    #expect(await PaneSleepProbe.check(unknown) == nil)
}

// @lat: [[lat.md/tests/pane-sleep-tests#Release restore and visibility races]]
@Test @MainActor func paneSleepLifecycle() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendSleep-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let address = "http://127.0.0.1:\(server.port)/"
    let manager = ExtensionManager(root: root.appendingPathComponent("extensions"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    let domain = "BendSleepTest-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let prefs = PaneSleepPreferences(defaults: defaults)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager, sleepPreferences: prefs)
    defer { store.stopWindow() }
    #expect(store.sleepCoordinator == nil)
    let first = BrowserTab(pages: [Page(address: address), Page(address: address)])
    let second = BrowserTab(pages: [Page(address: address)])
    store.session.workspaces = [Workspace(name: "Test", tabs: [first, second])]
    store.session.selectedTab = first.id
    let host = MountedTabHost(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
    let window = BrowseWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func update() { host.update(store: store, environment: EnvironmentValues()); host.layoutSubtreeIfNeeded() }
    update()
    let page = first.pages[0]
    var controller: PageController? = store.controller(for: page)
    weak var oldWeb = controller?.webView
    weak var oldController = controller
    try await sleepLoaded(try #require(oldWeb))
    try await Task.sleep(for: .milliseconds(200))
    do {
        let web = try #require(controller?.webView)
        #expect(!web.configuration.userContentController.userScripts.contains { $0.source == PaneSleepProbe.tracker })
        prefs.enabled = true
        #expect(await PaneSleepProbe.check(web) == nil)
        web.reload()
        try await sleepLoaded(web)
        #expect(await PaneSleepProbe.check(web) != nil)
    }
    let coordinator = try #require(store.sleepCoordinator)
    // Every pane in the selected tab is protected, including the unfocused one.
    for page in first.pages { #expect(store.sleepCandidate(page.id) == nil) }
    _ = try await oldWeb?.evaluateJavaScript("history.pushState({}, '', '/second'); document.body.style.height='4000px'; window.scrollTo(0,400)")
    store.select(second.id); update()
    #expect(store.sleepCandidate(page.id) != nil)
    let justHidden = try #require(coordinator.lastVisible[page.id])
    await coordinator.run(now: justHidden + 59, lowPower: false)
    #expect(store.sleepingPanes[page.id] == nil)
    prefs.keepAwake("127.0.0.1", enabled: true)
    #expect(store.sleepCandidate(page.id) == nil)
    prefs.keepAwake("127.0.0.1", enabled: false)
    prefs.enabled = false
    #expect(oldWeb?.configuration.userContentController.userScripts.contains { $0.source == PaneSleepProbe.tracker } == false)
    #expect(store.sleepCoordinator == nil)
    #expect(store.sleepCandidate(page.id) == nil)
    prefs.enabled = true
    let resumedCoordinator = try #require(store.sleepCoordinator)
    store.editTab(first.id) { $0.pages[0].isPinned = true }
    #expect(store.sleepCandidate(page.id) == nil)
    store.editTab(first.id) { $0.pages[0].isPinned = false }
    controller?.isLoading = true
    #expect(store.sleepCandidate(page.id) == nil)
    controller?.isLoading = false
    // Start a check, then select the tab before WebKit replies.
    let attempt = Task { await resumedCoordinator.suspend(page.id) }
    await Task.yield()
    store.select(first.id); update()
    await attempt.value
    #expect(store.sleepingPanes[page.id] == nil)
    store.select(second.id); update()
    await resumedCoordinator.run(now: ProcessInfo.processInfo.systemUptime + 1801, lowPower: false)
    #expect(store.sleepingPanes[page.id] != nil)
    #expect(store.existingController(for: page.id) == nil)
    controller = nil
    update()
    for _ in 0..<40 {
        if oldWeb == nil && oldController == nil { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(oldController == nil)
    #expect(oldWeb == nil)
    store.select(first.id); update()
    let restored = store.controller(for: page)
    #expect(store.sleepingPanes[page.id] == nil)
    try await sleepLoaded(restored.webView)
    #expect(restored.webView.url?.path == "/second")
    #expect(restored.webView.backForwardList.backItem != nil)
    #expect(restored.wakeSnapshot == nil)
    // Navigation must invalidate an outstanding attempt even on the same URL.
    store.select(second.id); update()
    let navigating = Task { await resumedCoordinator.suspend(page.id) }
    await Task.yield()
    restored.navigate(address + "new")
    await navigating.value
    #expect(store.sleepingPanes[page.id] == nil)
    try await sleepLoaded(restored.webView)
    try await Task.sleep(for: .milliseconds(100))
    await resumedCoordinator.suspend(page.id)
    #expect(store.sleepingPanes[page.id] != nil)
    let sibling = first.pages[1].id
    // This sibling was opened before opt-in. Its first instrumented document
    // is eligible only after it navigates.
    let siblingWeb = try #require(store.existingController(for: sibling)?.webView)
    #expect(await PaneSleepProbe.check(siblingWeb) == nil)
    siblingWeb.reload()
    try await sleepLoaded(siblingWeb)
    #expect(await PaneSleepProbe.check(siblingWeb) != nil)
    await resumedCoordinator.suspend(sibling)
    #expect(store.sleepingPanes[sibling] != nil)
    let destination = BrowserStore(sessionFile: root.appendingPathComponent("other.json"), sharedStore: store)
    defer { destination.stopWindow() }
    #expect(store.transfer(tab: first.id, to: destination, at: .workspace(destination.session.workspaces[0].id)))
    #expect(store.sleepingPanes[page.id] == nil)
    #expect(destination.sleepingPanes[page.id] != nil)
    // A new destination must not accidentally restore the URL saved at sleep.
    destination.editTab(first.id) { $0.pages[0].address = address + "replacement" }
    let changed = destination.controller(for: destination.selectedTab.pages[0])
    try await sleepLoaded(changed.webView)
    #expect(changed.webView.url?.path == "/replacement")
    #expect(destination.sleepingPanes[page.id] == nil)
    // Closing a sleeping sibling drops its capture without waking it.
    #expect(destination.sleepingPanes[sibling] != nil)
    destination.closePage(sibling)
    #expect(destination.sleepingPanes[sibling] == nil)
    #expect(destination.existingController(for: sibling) == nil)
}

// @lat: [[lat.md/tests/pane-sleep-tests#Download startup protection]]
@Test @MainActor func paneSleepDownloadProtection() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SleepDownload-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await DownloadHTTPFixture.start()
    defer { server.listener.cancel() }
    let downloads = BrowserDownloads(directory: root)
    defer { downloads.shutdown() }
    let web = WKWebView(frame: .zero)
    let unrelated = WKWebView(frame: .zero)
    downloads.start(URLRequest(url: server.url("/slow")), in: web)
    #expect(downloads.hasActiveDownload(for: web))
    #expect(!downloads.hasActiveDownload(for: unrelated))
    for _ in 0..<100 {
        if !downloads.items.isEmpty { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let item = try #require(downloads.items.first)
    #expect(item.state == .downloading)
    #expect(downloads.hasActiveDownload(for: web))
    downloads.cancel(item)
    for _ in 0..<100 {
        if !downloads.hasActiveDownload(for: web) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!downloads.hasActiveDownload(for: web))
}

// @lat: [[lat.md/tests/pane-sleep-tests#Form resubmission protection]]
@Test @MainActor func paneSleepPOSTProtection() async throws {
    _ = NSApplication.shared
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let address = "http://127.0.0.1:\(server.port)/"
    let page = PageController(address: address, configure: { $0.websiteDataStore = .nonPersistent() })
    defer { page.webView.stopLoading(); page.media.detach() }
    try await sleepLoaded(page.webView)
    try await Task.sleep(for: .milliseconds(100))
    #expect(page.canSleep)
    var request = URLRequest(url: URL(string: address)!)
    request.httpMethod = "POST"
    page.webView.load(request)
    try await sleepLoaded(page.webView)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!page.canSleep)
}

// @lat: [[lat.md/tests/pane-sleep-tests#Persistent exceptions]]
@Test @MainActor func paneSleepSettingsPersistence() throws {
    let domain = "BendSleepPreferences-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let prefs = PaneSleepPreferences(defaults: defaults)
    #expect(!prefs.enabled)
    prefs.enabled = true
    prefs.keepAwake("example.com", enabled: true)
    let restored = PaneSleepPreferences(defaults: defaults)
    #expect(restored.enabled)
    #expect(restored.keepAwakeHosts == ["example.com"])
    restored.enabled = false
    #expect(!PaneSleepPreferences(defaults: defaults).enabled)
}
