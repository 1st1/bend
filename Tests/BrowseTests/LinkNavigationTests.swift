import AppKit
import BrowseCore
import Testing
import WebKit
@testable import Browse

@MainActor
private final class LinkFrameProbe: NSObject, WKNavigationDelegate {
    var main: WKFrameInfo?
    var child: WKFrameInfo?
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.sourceFrame.isMainFrame { main = action.sourceFrame }
        else { child = action.sourceFrame }
        decisionHandler(.allow)
    }
}

@MainActor
private final class LinkAction: WKNavigationAction {
    var source: WKFrameInfo?
    var modifiers: NSEvent.ModifierFlags = .command
    // WKNavigationAction uses a button mask: left = 1, right = 2, middle = 4.
    var button = 1
    var kind: WKNavigationType = .linkActivated
    var download = false
    override var shouldPerformDownload: Bool { download }
    var destination = URL(string: "https://example.com/target?q=one#section")!
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override var buttonNumber: Int { button }
    override var navigationType: WKNavigationType { kind }
    override var request: URLRequest { URLRequest(url: destination) }
    override var targetFrame: WKFrameInfo? { nil }
    override var sourceFrame: WKFrameInfo { source ?? super.sourceFrame }
}

@MainActor private final class NativeLinkNavigationProbe: NSObject, WKNavigationDelegate {
    let controller: PageController
    var actions: [String] = []

    init(controller: PageController) { self.controller = controller }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        actions.append("url=\(action.request.url?.absoluteString ?? "nil") type=\(action.navigationType.rawValue) button=\(action.buttonNumber) modifiers=\(action.modifierFlags.rawValue) download=\(action.shouldPerformDownload)")
        controller.webView(webView, decidePolicyFor: action, decisionHandler: decisionHandler)
    }
}

// @lat: [[lat.md/tests/link-navigation-tests#Command-click navigation]]
@Test @MainActor func commandClickNavigation() {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start")
    var panes: [String] = []
    controller.onNewPane = { panes.append($0) }
    let action = LinkAction()
    var policies: [WKNavigationActionPolicy] = []
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies == [.cancel])
    #expect(panes == [action.destination.absoluteString])
    #expect(controller.address == "browse://start")

    action.modifiers = []
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies.last == .allow)
    action.modifiers = .command
    for button in [0, 2, 4] {
        action.button = button
        controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
        #expect(policies.last == .allow)
    }
    action.button = 1
    action.kind = .other
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies.last == .allow)
    action.kind = .linkActivated
    action.destination = URL(string: "custom://target")!
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies.last == .cancel)
    #expect(panes.count == 1)
}

// @lat: [[lat.md/tests/link-navigation-tests#Command-click new-window links]]
@Test @MainActor func commandClickNewWindowLink() {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start")
    var panes: [String] = []
    var tabs: [String] = []
    controller.onNewPane = { panes.append($0) }
    controller.onNewTab = { tabs.append($0) }
    let action = LinkAction()
    let result = controller.webView(controller.webView, createWebViewWith: WKWebViewConfiguration(),
                                    for: action, windowFeatures: WKWindowFeatures())
    #expect(result == nil)
    #expect(panes == [action.destination.absoluteString])
    #expect(tabs.isEmpty)
    action.modifiers = []
    _ = controller.webView(controller.webView, createWebViewWith: WKWebViewConfiguration(),
                           for: action, windowFeatures: WKWindowFeatures())
    #expect(panes.count == 1)
    #expect(tabs == [action.destination.absoluteString])
}

// @lat: [[lat.md/tests/link-navigation-tests#Configurable link destination]]
@Test @MainActor func configurableLinkDestination() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsePreferences-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserStore(sessionFile: directory.appendingPathComponent("session.json"), persistentExtensions: false)
    let originalTab = store.selectedTab
    let source = try #require(originalTab.pages.first)
    let controller = store.controller(for: source)
    let initialCount = originalTab.pages.count
    store.newTab(address: "browse://guide")
    let trailingTab = store.selectedTab.id
    store.select(originalTab.id)

    controller.onNewLink?("https://example.com/adjacent", true, true)
    #expect(store.selectedTab.id == originalTab.id)
    #expect(store.selectedTab.pages.count == initialCount + 1)
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == source.id)
    #expect(store.selectedTab.layout.paneIDs.firstIndex(of: store.selectedTab.focusedPane)
        == store.selectedTab.layout.paneIDs.firstIndex(of: source.id).map { $0 + 1 })

    // The same existing controller must use the new preference immediately.
    store.commandClickDestination = .newTab
    controller.onNewLink?("https://example.com/tab", true, true)
    #expect(store.selectedTab.id != originalTab.id)
    #expect(store.selectedTab.pages.count == 1)
    #expect(store.selectedTab.pages[0].address == "https://example.com/tab")
    let linkTab = store.selectedTab.id
    let originalIndex = try #require(store.session.workspaces[0].tabs.firstIndex { $0.id == originalTab.id })
    #expect(store.session.workspaces[0].tabs[originalIndex + 1].id == linkTab)
    #expect(store.session.workspaces[0].tabs.last?.id == trailingTab)
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == source.id)
    #expect(store.session.workspaces[0].tabs.first { $0.id == originalTab.id }?.pages.count == initialCount + 1)

    store.commandClickDestination = .newPane
    controller.onNewLink?("https://example.com/window", false, false)
    #expect(store.selectedTab.id != originalTab.id)
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == nil)
    #expect(store.session.workspaces[0].tabs[originalIndex + 2].id == store.selectedTab.id)
    #expect(store.session.workspaces[0].tabs.last?.id == trailingTab)
    controller.onNewLink?("https://example.com/adjacent-again", true, false)
    #expect(store.selectedTab.id == originalTab.id)
    #expect(store.selectedTab.pages.count == initialCount + 2)
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == nil)
}

// @lat: [[lat.md/tests/link-navigation-tests#Dedicated Command-click pane]]
@Test @MainActor func dedicatedCommandClickPane() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseDedicatedLink-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    store.commandClickDestination = .dedicatedPane
    let original = store.selectedTab
    let source = original.pages[0], other = original.pages[1]
    let sourceController = store.controller(for: source)
    sourceController.onNewLink?("browse://guide", true, true)
    let dedicated = try #require(store.selectedTab.commandClickPaneID)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    #expect(store.selectedTab.layout.paneIDs.firstIndex(of: dedicated) == 1)
    let target = store.controller(for: try #require(store.selectedTab.pages.first { $0.id == dedicated }))
    let web = target.webView
    let otherController = store.controller(for: other)
    otherController.onNewLink?("browse://history", true, true)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    #expect(store.selectedTab.focusedPane == dedicated && store.selectedTab.commandClickPaneID == dedicated)
    #expect(target.address == "browse://history" && target.webView === web)
    #expect(store.linkOpeners[dedicated] == other.id)
    #expect(sourceController.address == source.address && otherController.address == other.address)
    // Reuse from an iframe clears the preceding main-frame opener. Clicking in
    // the dedicated pane reuses it too, without a self-referential opener.
    sourceController.onNewLink?("browse://guide", true, false)
    #expect(store.linkOpeners[dedicated] == nil)
    target.onNewLink?("browse://history", true, true)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    #expect(store.linkOpeners[dedicated] == nil)
    store.newTab(address: "browse://guide")
    let secondTab = store.selectedTab
    store.controller(for: secondTab.pages[0]).onNewLink?("browse://history", true, true)
    #expect(store.selectedTab.pages.count == 2)
    #expect(store.selectedTab.commandClickPaneID != dedicated)
    sourceController.onNewLink?("browse://guide", true, true)
    #expect(store.selectedTab.id == original.id && store.selectedTab.commandClickPaneID == dedicated)
    store.closePage(dedicated)
    #expect(store.selectedTab.commandClickPaneID == nil)
    store.reopenClosed()
    #expect(store.selectedTab.commandClickPaneID == dedicated)
    store.closePage(dedicated)
    sourceController.onNewLink?("browse://history", true, true)
    let replacement = try #require(store.selectedTab.commandClickPaneID)
    #expect(replacement != dedicated)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.commandClickDestination == .dedicatedPane)
    #expect(restored.selectedTab.commandClickPaneID == replacement)
    restored.controller(for: source).onNewLink?("browse://guide", true, true)
    #expect(restored.selectedTab.commandClickPaneID == replacement)
    #expect(restored.selectedTab.pages.count == original.pages.count + 1)
    // Switching modes is live and must not repurpose an ordinary pane.
    restored.commandClickDestination = .newPane
    restored.controller(for: source).onNewLink?("browse://guide", true, true)
    #expect(restored.selectedTab.pages.count == original.pages.count + 2)
    #expect(restored.selectedTab.commandClickPaneID == replacement)
    restored.commandClickDestination = .dedicatedPane
    restored.controller(for: source).onNewLink?("browse://history", true, true)
    #expect(restored.selectedTab.pages.count == original.pages.count + 2)
    #expect(restored.selectedTab.focusedPane == replacement)

    // The last remaining pane becomes ordinary without losing its live WebView.
    let survivor = try #require(restored.selectedTab.pages.first { $0.id == replacement })
    let survivorController = restored.controller(for: survivor)
    let survivorWeb = survivorController.webView
    let survivorAddress = survivorController.address
    let ordinaryPanes = restored.selectedTab.pages.filter { $0.id != replacement }
    for (index, pane) in ordinaryPanes.enumerated() {
        restored.closePage(pane.id)
        #expect(restored.selectedTab.commandClickPaneID == (index == ordinaryPanes.count - 1 ? nil : replacement))
    }
    #expect(restored.selectedTab.pages.count == 1)
    #expect(restored.selectedTab.focusedPane == replacement)
    #expect(restored.controller(for: survivor).webView === survivorWeb)
    #expect(survivorController.address == survivorAddress)
    restored.save()
    #expect(BrowserStore(sessionFile: file, persistentExtensions: false).selectedTab.commandClickPaneID == nil)
    survivorController.onNewLink?("browse://guide", true, true)
    let newTarget = try #require(restored.selectedTab.commandClickPaneID)
    #expect(newTarget != replacement)
    #expect(restored.selectedTab.pages.count == 2)
    #expect(survivorController.address == survivorAddress && survivorController.webView === survivorWeb)
    #expect(restored.linkOpeners[newTarget] == replacement)
    survivorController.onNewLink?("browse://history", true, true)
    #expect(restored.selectedTab.commandClickPaneID == newTarget && restored.selectedTab.pages.count == 2)

    // Normalize the stale single-pane designation saved by older versions too.
    restored.closePage(newTarget)
    restored.editTab { $0.commandClickPaneID = replacement }
    restored.save()
    let legacyRestored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(legacyRestored.selectedTab.commandClickPaneID == nil)
    #expect(legacyRestored.selectedTab.pages[0].id == replacement)
}

// @lat: [[lat.md/tests/link-navigation-tests#Command-click preference migration]]
@Test @MainActor func commandClickPreferenceMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseLinkMigration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("session.json")
    for legacy in [false, true] {
        var session = BrowserSession()
        session.commandClickOpensNewTab = legacy
        try JSONEncoder().encode(session).write(to: file)
        let store = BrowserStore(sessionFile: file, persistentExtensions: false)
        #expect(store.commandClickDestination == (legacy ? .newTab : .newPane))
        store.commandClickDestination = .dedicatedPane
        store.save()
        let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
        #expect(restored.commandClickDestination == .dedicatedPane)
        #expect(restored.session.selectedTab == session.selectedTab)
    }
}

// @lat: [[lat.md/tests/link-navigation-tests#Command-Shift-click destinations]]
@Test @MainActor func commandShiftClickDestinations() async throws {
    try await modifiedClickDestinations(option: false)
}

// @lat: [[lat.md/tests/link-navigation-tests#Option-click destinations]]
@Test @MainActor func optionClickDestinations() async throws {
    try await modifiedClickDestinations(option: true)
}

@MainActor private func modifiedClickDestinations(option: Bool) async throws {
    let preference: ReferenceWritableKeyPath<BrowserStore, LinkOpenDestination> = option
        ? \.optionClickDestination : \.commandShiftClickDestination
    let sessionPreference: KeyPath<BrowserSession, LinkOpenDestination?> = option
        ? \.optionClickDestination : \.commandShiftClickDestination
    let modifiers: NSEvent.ModifierFlags = option ? .option : [.command, .shift]
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendShiftLink-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    let origin = try #require(owner.active)
    let store = origin.store
    let original = store.selectedTab, page = original.pages[0]
    let controller = store.controller(for: page)
    #expect(store[keyPath: preference] == .newTab)
    let otherPreference: ReferenceWritableKeyPath<BrowserStore, LinkOpenDestination> = option
        ? \.commandShiftClickDestination : \.optionClickDestination
    store[keyPath: otherPreference] = .newPane
    store.commandClickDestination = .dedicatedPane
    store.newTab(address: "browse://guide")
    let trailing = store.selectedTab.id
    store.select(original.id)
    let action = LinkAction()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let probeWeb = WKWebView(frame: .zero, configuration: configuration)
    let probe = LinkFrameProbe()
    probeWeb.navigationDelegate = probe
    probeWeb.loadHTMLString("<iframe srcdoc=\"<script>location.href='about:blank'</script>\"></iframe>", baseURL: nil)
    for _ in 0..<100 where probe.main == nil || probe.child == nil { try await Task.sleep(for: .milliseconds(20)) }
    defer { probeWeb.stopLoading() }
    action.source = try #require(probe.main)
    action.modifiers = modifiers
    action.download = option
    action.destination = URL(string: "http://127.0.0.1:9/shift-click")!
    func click(popup: Bool) {
        if popup {
            #expect(controller.webView(controller.webView, createWebViewWith: WKWebViewConfiguration(),
                for: action, windowFeatures: WKWindowFeatures()) == nil)
        } else {
            var policy: WKNavigationActionPolicy?
            controller.webView(controller.webView, decidePolicyFor: action) { policy = $0 }
            #expect(policy == .cancel)
        }
    }
    click(popup: false)
    #expect(store.selectedTab.id != original.id)
    #expect(store.selectedTab.pages.map(\.address) == [action.destination.absoluteString])
    #expect(store.session.workspaces[0].tabs.map(\.id) == [original.id, store.selectedTab.id, trailing])
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == page.id)
    #expect(controller.address == page.address)
    #expect(store.session.workspaces[0].tabs[0].commandClickPaneID == nil)

    store[keyPath: preference] = .newPane
    action.source = try #require(probe.child)
    click(popup: true)
    #expect(store.selectedTab.id == original.id)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    #expect(store.selectedTab.layout.paneIDs.firstIndex(of: store.selectedTab.focusedPane) == 1)
    #expect(store.selectedTab.commandClickPaneID == nil)
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == nil)
    #expect(controller.address == page.address)

    // Each modifier preference is independent of the dedicated-pane Command-click choice.
    action.modifiers = .command
    action.download = false
    action.source = try #require(probe.main)
    click(popup: false)
    #expect(store.selectedTab.commandClickPaneID == store.selectedTab.focusedPane)
    let sourceIDs = store.selectedTab.pages.map(\.id)
    let sourceTabIDs = store.session.workspaces[0].tabs.map(\.id)
    action.modifiers = modifiers
    action.download = option
    store[keyPath: preference] = .newWindow
    for popup in [false, true] {
        let count = owner.windows.count
        click(popup: popup)
        #expect(owner.windows.count == count + 1)
        let destination = try #require(owner.windows.last)
        #expect(destination !== origin && destination.window.isVisible)
        #expect(destination.store.session.workspaces.flatMap(\.tabs).count == 1)
        #expect(destination.store.selectedTab.pages.map(\.address) == [action.destination.absoluteString])
        #expect(destination.store[keyPath: preference] == .newWindow)
        #expect(store.selectedTab.pages.map(\.id) == sourceIDs)
        #expect(store.session.workspaces[0].tabs.map(\.id) == sourceTabIDs)
        let saved = try JSONDecoder().decode(BrowserSession.self,
            from: Data(contentsOf: root.appendingPathComponent("Windows/\(destination.id).json")))
        #expect(saved.workspaces[0].tabs[0].pages[0].address == action.destination.absoluteString)
    }
    // Preference changes from a secondary window reach the existing source controller.
    let secondary = try #require(owner.windows.last).store
    secondary[keyPath: preference] = .newTab
    #expect(store[keyPath: preference] == .newTab)
    click(popup: true)
    #expect(store.selectedTab.pages.count == 1)
    #expect(store.selectedTab.pages[0].address == action.destination.absoluteString)
    #expect(owner.windows.count == 3)
    for choice in [LinkOpenDestination.newTab, .newPane, .newWindow] {
        secondary[keyPath: preference] = choice
        owner.save()
        let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: root.appendingPathComponent("session.json")))
        #expect(saved[keyPath: sessionPreference] == choice)
        #expect(saved.commandClickDestination == .dedicatedPane)
        #expect(store[keyPath: otherPreference] == .newPane)
    }
}

// @lat: [[lat.md/tests/link-navigation-tests#Native Option-click links]]
@Test @MainActor func nativeOptionClickLinks() async throws {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start", configure: { $0.websiteDataStore = .nonPersistent() })
    let web = controller.webView
    let probe = NativeLinkNavigationProbe(controller: controller)
    web.navigationDelegate = probe
    web.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(web)
    defer { controller.media.detach(); web.stopLoading(); window.close() }
    var links: [(String, Bool)] = []
    controller.onOptionLink = { links.append(($0, $1)) }
    web.loadHTMLString("""
        <style>body { margin:0 } a { display:block; height:60px } iframe { border:0; width:500px; height:120px }</style>
        <a href="http://127.0.0.1:9/self">Same frame</a>
        <a target="_blank" href="http://127.0.0.1:9/blank">New window</a>
        <iframe srcdoc="<style>body{margin:0}a{display:block;height:80px}</style><a href='http://127.0.0.1:9/iframe'>Frame link</a>"></iframe>
        """, baseURL: URL(string: "http://127.0.0.1:9/source"))
    let ready = "document.readyState === 'complete' && document.querySelector('iframe')?.contentDocument?.querySelector('a') != null"
    for _ in 0..<250 {
        if (try? await web.evaluateJavaScript(ready)) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(try await web.evaluateJavaScript(ready) as? Bool == true, "Link fixture must finish loading before clicks")
    // DOM readiness can precede WebKit's presentation update. Wait for the
    // rendered page and derive native coordinates from the actual link bounds.
    let snapshot = WKSnapshotConfiguration()
    snapshot.afterScreenUpdates = true
    _ = try await web.takeSnapshot(configuration: snapshot)
    #expect(try await web.evaluateJavaScript("typeof window.webkit.messageHandlers.bendOptionClick") as? String == "undefined")
    // An untrusted page-generated event must not open a tab. Cancel its default
    // only at window bubbling, after the document-level isolated-world observer.
    _ = try await web.evaluateJavaScript("""
        window.addEventListener('click', event => { if (!event.isTrusted) event.preventDefault(); });
        document.querySelector('a').dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, altKey:true}));
        """)
    #expect(try await web.callAsyncJavaScript("return await window.webkit.messageHandlers.bendOptionClick.postMessage(null)",
        arguments: [:], in: nil, contentWorld: OptionClickObserver.world) as? Bool == true)
    #expect(links.isEmpty)
    for index in 0..<3 {
        let target = try #require(try await web.callAsyncJavaScript("""
            const frame = document.querySelector('iframe');
            const doc = index === 2 ? frame.contentDocument : document;
            const link = doc.querySelectorAll('a')[index === 2 ? 0 : index];
            const rect = link.getBoundingClientRect();
            const parent = index === 2 ? frame.getBoundingClientRect() : {x: 0, y: 0};
            window.nativeMouseEvents = [];
            for (const type of ['mousedown', 'mouseup', 'click']) {
                link.addEventListener(type, event => window.nativeMouseEvents.push({type, trusted: event.isTrusted, alt: event.altKey}), {once: true});
            }
            return [parent.x + rect.x + rect.width / 2, parent.y + rect.y + rect.height / 2];
            """, arguments: ["index": index], in: nil, contentWorld: .page) as? [Double])
        let local = NSPoint(x: target[0], y: web.isFlipped ? target[1] : web.bounds.height - target[1])
        let point = web.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: index + 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { web.mouseDown(with: event) }
            else { web.mouseUp(with: event) }
        }
        for _ in 0..<100 where links.count <= index { try await Task.sleep(for: .milliseconds(20)) }
        let events = try await web.evaluateJavaScript("JSON.stringify(window.nativeMouseEvents)") as? String ?? "missing"
        try #require(links.count == index + 1,
                     "Link \(index), native point \(point), bounds \(web.bounds), DOM events \(events), navigation actions \(probe.actions)")
    }
    #expect(links.map(\.0) == ["self", "blank", "iframe"].map { "http://127.0.0.1:9/\($0)" })
    #expect(links.map(\.1) == [true, true, false])
    #expect(web.url?.absoluteString == "http://127.0.0.1:9/source")
    #expect(controller.downloads.items.isEmpty)
    for name in ["self", "blank", "iframe"] {
        #expect(!probe.actions.contains { $0.contains("url=http://127.0.0.1:9/\(name) ") },
                "The document bridge handles Option-click before WebKit navigation or download policy")
    }
}

// @lat: [[lat.md/tests/link-navigation-tests#Option-click shared controller isolation]]
@Test @MainActor func optionClickSharedControllerIsolation() async throws {
    _ = NSApplication.shared
    let shared = WKUserContentController()
    let pane = PageController(address: "browse://start", configure: {
        $0.websiteDataStore = .nonPersistent()
        $0.userContentController = shared
    })
    var opened: [String] = []
    pane.onOptionLink = { address, _ in opened.append(address) }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = shared
    let other = WKWebView(frame: .zero, configuration: configuration)
    defer { pane.media.detach(); pane.webView.stopLoading(); other.stopLoading() }
    for web in [pane.webView, other] {
        web.loadHTMLString("<title>Option routing</title>", baseURL: nil)
        for _ in 0..<100 where web.title != "Option routing" { try await Task.sleep(for: .milliseconds(20)) }
        try #require(web.title == "Option routing")
        let enabled = try await web.callAsyncJavaScript("return await window.webkit.messageHandlers.bendOptionClick.postMessage(null)",
            arguments: [:], in: nil, contentWorld: OptionClickObserver.world) as? Bool
        #expect(enabled == (web === pane.webView))
    }
    let ignored = try await other.callAsyncJavaScript("return await window.webkit.messageHandlers.bendOptionClick.postMessage('https://example.com/ignored')",
        arguments: [:], in: nil, contentWorld: OptionClickObserver.world) as? Bool
    #expect(ignored == false)
    #expect(opened.isEmpty)
}

// @lat: [[lat.md/tests/link-navigation-tests#Dedicated pane window restoration]]
@Test @MainActor func dedicatedPaneWindowRestoration() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendDedicatedRestart-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let first = try #require(owner.active)
    let second = owner.newWindow(show: false)
    first.store.commandClickDestination = .dedicatedPane
    var targets: [String: (tab: UUID, source: UUID, destination: UUID)] = [:]
    for window in [first, second] {
        let store = window.store
        store.newTab(address: "browse://guide")
        let source = store.selectedTab.pages[0]
        store.controller(for: source).onNewLink?("browse://history", true, true)
        let originalDestination = try #require(store.selectedTab.commandClickPaneID)
        store.duplicateTab(store.selectedTab.id)
        let copy = store.selectedTab
        let destination = try #require(copy.commandClickPaneID)
        #expect(destination != originalDestination)
        #expect(destination == copy.pages[1].id)
        targets[window.id] = (copy.id, copy.pages[0].id, destination)
        #expect(store.selectedTab.pages.count == 2)
    }
    owner.prepareToQuit()
    for window in owner.windows { window.window.close() }
    let restored = BrowserWindows(root: root, persistentExtensions: false)
    restored.restore(show: false)
    defer {
        restored.prepareToQuit()
        for window in restored.windows { window.window.close() }
    }
    #expect(restored.windows.count == 2)
    for window in restored.windows {
        let store = window.store
        let target = try #require(targets[window.id])
        #expect(store.commandClickDestination == .dedicatedPane)
        #expect(store.selectedTab.id == target.tab)
        #expect(store.selectedTab.commandClickPaneID == target.destination)
        let source = try #require(store.selectedTab.pages.first { $0.id == target.source })
        store.controller(for: source).onNewLink?("browse://guide", true, true)
        #expect(store.selectedTab.pages.count == 2)
        #expect(store.selectedTab.focusedPane == target.destination)
        #expect(store.selectedTab.commandClickPaneID == target.destination)
    }
}
