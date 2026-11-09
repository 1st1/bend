import AppKit
import Testing
import WebKit
import BrowseCore
import SwiftUI
@testable import Browse

@MainActor private func mediaWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<150 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(predicate())
}

private let mediaSessionFixture = #"""
    <title>Page fallback</title><body>Media fixture<script>
    window.nextCount = 0;
    navigator.mediaSession.metadata = new MediaMetadata({title:'First track', artist:'An artist'});
    navigator.mediaSession.setActionHandler('play', () => navigator.mediaSession.playbackState = 'playing');
    navigator.mediaSession.setActionHandler('pause', () => navigator.mediaSession.playbackState = 'paused');
    navigator.mediaSession.setActionHandler('nexttrack', () => {
        nextCount++;
        navigator.mediaSession.metadata = new MediaMetadata({title:'Next track', artist:'Another artist'});
    });
    navigator.mediaSession.playbackState = 'playing';
    </script>
    """#

// @lat: [[tests#Media session commands and metadata]]
@Test @MainActor func mediaSessionCommandsAndMetadata() async throws {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start")
    let web = controller.webView
    defer { controller.media.reset(); web.stopLoading() }
    web.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://media.example"))
    try await mediaWait { controller.media.sessions.first?.title == "First track" }
    var state = try #require(controller.media.sessions.first)
    #expect(state.artist == "An artist")
    #expect(state.site == "media.example")
    #expect(state.playing)
    #expect(!state.actions.contains("previoustrack"))
    #expect(await controller.media.send("nexttrack", to: state))
    try await mediaWait { controller.media.sessions.first?.title == "Next track" }
    #expect(try await web.evaluateJavaScript("nextCount") as? Int == 1)
    state = try #require(controller.media.sessions.first)
    #expect(await controller.media.send("pause", to: state))
    try await mediaWait { controller.media.sessions.first?.playing == false }
    #expect(await controller.media.send("play", to: state))
    try await mediaWait { controller.media.sessions.first?.playing == true }
    // Catch updates made to an existing metadata object without assigning a new one.
    _ = try await web.evaluateJavaScript("navigator.mediaSession.metadata.title = 'Changed in place'; void 0")
    await controller.media.refresh()
    try await mediaWait { controller.media.sessions.first?.title == "Changed in place" }
    _ = try await web.evaluateJavaScript("navigator.mediaSession.setActionHandler('nexttrack', null); void 0")
    try await mediaWait { controller.media.sessions.first?.actions.contains("nexttrack") == false }
    #expect(!(await controller.media.send("nexttrack", to: state)))
    _ = try await web.evaluateJavaScript("navigator.mediaSession.metadata = null; void 0")
    try await mediaWait { controller.media.sessions.first?.title == "Page fallback" }
    // The original native API still validates unsupported actions.
    #expect(try await web.evaluateJavaScript("(() => { try { navigator.mediaSession.setActionHandler('bad-action', () => {}); return false; } catch { return true; } })()") as? Bool == true)
    _ = try await web.evaluateJavaScript("navigator.mediaSession.setActionHandler('nexttrack', () => new Promise(resolve => window.finishPendingMediaCommand = resolve)); void 0")
    try await mediaWait { controller.media.sessions.first?.actions.contains("nexttrack") == true }
    let unresponsive = try #require(controller.media.sessions.first)
    #expect(!(await controller.media.send("nexttrack", to: unresponsive)))
    _ = try await web.evaluateJavaScript("finishPendingMediaCommand(); void 0")
    let stale = try #require(controller.media.sessions.first)
    web.loadHTMLString("<title>Replacement</title>", baseURL: URL(string: "https://next.example"))
    try await mediaWait { controller.media.sessions.isEmpty }
    #expect(!(await controller.media.send("play", to: stale)))
    #expect(PageMediaController.clean("a\u{202E}b\n" + String(repeating: "x", count: 1000)).count <= 512)
}

// @lat: [[tests#Media playback progress]]
@Test @MainActor func mediaPlaybackProgress() async throws {
    _ = NSApplication.shared
    let page = PageController(address: "browse://start")
    defer { page.media.detach(); page.webView.stopLoading() }
    page.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://progress.example"))
    try await mediaWait { !page.media.sessions.isEmpty }
    #expect(page.media.sessions.first?.timeline == nil)
    _ = try await page.webView.evaluateJavaScript("""
        navigator.mediaSession.setPositionState({duration:240, position:30, playbackRate:2});
        navigator.mediaSession.setActionHandler('seekto', details => {
            window.lastSeek = details;
            navigator.mediaSession.setPositionState({duration:240, position:details.seekTime, playbackRate:2});
        }); void 0
        """)
    try await mediaWait { page.media.sessions.first?.timeline != nil }
    let moving = try #require(page.media.sessions.first?.timeline)
    #expect(moving.duration == 240)
    #expect(moving.rate == 2)
    #expect(abs(moving.position(at: moving.updatedAt + 2) - moving.position - 4) < 0.01)
    #expect(moving.position(at: moving.updatedAt + 1000) == 240)
    #expect(await page.media.send("pause", to: try #require(page.media.sessions.first)))
    try await mediaWait { page.media.sessions.first?.timeline?.rate == 0 }
    let paused = try #require(page.media.sessions.first)
    let stopped = try #require(paused.timeline)
    #expect(stopped.position(at: stopped.updatedAt + 10) == stopped.position)
    #expect(await page.media.send("seekto", to: paused, value: 75))
    try await mediaWait { page.media.sessions.first?.timeline?.position == 75 }
    #expect(try await page.webView.evaluateJavaScript("lastSeek.seekTime === 75 && lastSeek.action === 'seekto' && lastSeek.fastSeek === false") as? Bool == true)
    #expect(!(await page.media.send("seekto", to: paused, value: -1)))
    #expect(!(await page.media.send("seekto", to: paused, value: 241)))
    #expect(!(await page.media.send("seekto", to: paused, value: .nan)))
    #expect(try await page.webView.evaluateJavaScript("(() => { try { navigator.mediaSession.setPositionState({duration:-1}); return false; } catch { return true; } })()") as? Bool == true)
    _ = try await page.webView.evaluateJavaScript("navigator.mediaSession.setPositionState(); void 0")
    try await mediaWait { page.media.sessions.first?.timeline == nil }
    #expect(!(await page.media.send("seekto", to: try #require(page.media.sessions.first), value: 10)))
    for values in [["duration": Double.infinity, "position": 0, "rate": 1],
                   ["duration": 0, "position": 0, "rate": 1],
                   ["duration": 100, "position": -1, "rate": 1],
                   ["duration": 100, "position": 101, "rate": 1],
                   ["duration": 100, "position": 1, "rate": Double.nan]] {
        #expect(MediaTimeline(values, playing: true) == nil)
    }
}

// @lat: [[tests#Media progress layout]]
@Test @MainActor func mediaProgressLayout() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendProgressLayout-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let page = store.selectedTab.pages[0]
    let controller = store.controller(for: page)
    defer { store.closePage(page.id) }
    controller.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://progress.example"))
    try await mediaWait { store.mediaCoordinator.selected != nil }
    let preview = NSHostingView(rootView: SidebarMediaPlayer(coordinator: store.mediaCoordinator, store: store)
        .frame(width: 236).preferredColorScheme(.dark))
    preview.frame = NSRect(x: 0, y: 0, width: 236, height: 200)
    func geometry() async throws -> (height: CGFloat, bar: NSRect, enabled: Bool) {
        try await Task.sleep(for: .milliseconds(40))
        preview.layoutSubtreeIfNeeded()
        func slider(in view: NSView) -> NSSlider? {
            if let slider = view as? NSSlider { return slider }
            return view.subviews.lazy.compactMap { slider(in: $0) }.first
        }
        let bar = try #require(slider(in: preview))
        return (preview.fittingSize.height, bar.convert(bar.bounds, to: preview), bar.isEnabled)
    }
    let initial = try await geometry()
    #expect(!initial.enabled)
    for clipping in [0.0, 1.1, 16.0] {
        store.paneHeaderBottomRimClipping = clipping
        let current = try await geometry()
        #expect(abs(current.height - initial.height) < 0.5)
        #expect(current.bar == initial.bar)
    }
    for positionState in ["{duration:240, position:30}", "", "{duration:360, position:0}"] {
        _ = try await controller.webView.evaluateJavaScript("""
            navigator.mediaSession.setActionHandler('seekto', () => {});
            navigator.mediaSession.setPositionState(\(positionState)); void 0
            """)
        await controller.media.refresh()
        try await mediaWait { (store.mediaCoordinator.selected?.state.timeline == nil) == positionState.isEmpty }
        let current = try await geometry()
        #expect(abs(current.height - initial.height) < 0.5)
        #expect(current.bar == initial.bar)
        #expect(current.enabled == !positionState.isEmpty)
    }
}

// @lat: [[tests#Media slider interaction]]
@Test @MainActor func mediaSliderInteraction() async throws {
    _ = NSApplication.shared
    var position = 60.0
    var commits: [Double] = []
    let view = NSHostingView(rootView: MediaProgressSlider(
        value: Binding(get: { position }, set: { position = $0 }), duration: 240
    ) { editing in if !editing { commits.append(position) } }.frame(width: 220, height: 16))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 220, height: 40),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFront(nil)
    defer { window.close() }
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    view.layoutSubtreeIfNeeded()
    func findSlider(_ view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider { return slider }
        return view.subviews.lazy.compactMap(findSlider).first
    }
    let slider = try #require(findSlider(view))
    let bitmap = try #require(slider.bitmapImageRepForCachingDisplay(in: slider.bounds))
    slider.cacheDisplay(in: slider.bounds, to: bitmap)
    _ = window.makeFirstResponder(slider)
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
    slider.keyDown(with: key)
    #expect(position > 60)
    #expect(commits.count == 1)
    #expect(slider.accessibilityPerformDecrement())
    #expect(position == 60)
    #expect(commits.count == 2)
    #expect(commits.last == position)

}

// @lat: [[tests#Media frame routing and lifecycle]]
@Test @MainActor func mediaFrameRoutingAndLifecycle() async throws {
    _ = NSApplication.shared
    let shared = WKUserContentController()
    func make() -> PageController {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = shared
        configuration.websiteDataStore = .nonPersistent()
        return PageController(address: "browse://start", webView: FocusWebView(frame: .zero, configuration: configuration))
    }
    let first = make(), second = make()
    defer { first.media.reset(); second.media.reset(); first.webView.stopLoading(); second.webView.stopLoading() }
    // A sandboxed frame has an opaque origin and cannot be reached through the parent's DOM.
    let escaped = mediaSessionFixture.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    first.webView.loadHTMLString("<iframe sandbox='allow-scripts' srcdoc=\"\(escaped)\"></iframe>", baseURL: URL(string: "https://parent.example"))
    second.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://second.example"))
    try await mediaWait { first.media.sessions.count == 1 && second.media.sessions.count == 1 }
    let frameState = try #require(first.media.sessions.first)
    #expect(await first.media.send("nexttrack", to: frameState))
    try await mediaWait { first.media.sessions.first?.title == "Next track" }
    #expect(second.media.sessions.first?.title == "First track")
    #expect(try await second.webView.evaluateJavaScript("nextCount") as? Int == 0)
    _ = try await first.webView.evaluateJavaScript("document.querySelector('iframe').remove(); void 0")
    await first.media.refresh()
    try await mediaWait { first.media.sessions.isEmpty }
    #expect(!(await first.media.send("pause", to: frameState)))
    let old = try #require(second.media.sessions.first)
    second.webViewWebContentProcessDidTerminate(second.webView)
    #expect(second.media.sessions.isEmpty)
    #expect(!(await second.media.send("play", to: old)))
    #expect(shared.userScripts.filter { $0.source == MediaSessionBridge.script }.count == 1)
}

// @lat: [[tests#HTML media fallback controls]]
@Test(arguments: ["shadow", "detached audio", "detached element"])
@MainActor func htmlMediaFallbackControls(placement: String) async throws {
    _ = NSApplication.shared
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    let web = FocusWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration)
    let controller = PageController(address: "browse://start", webView: web)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    window.orderFront(nil)
    defer { controller.media.reset(); web.stopLoading(); window.close() }
    web.loadHTMLString(#"""
        <title>Audio fallback</title><script>
        const host = document.createElement('div'); document.documentElement.append(host);
        const shadow = host.attachShadow({mode:'open'});
        const audio = \#(placement == "detached audio" ? "new Audio()" : "document.createElement('audio')");
        if ('\#(placement)' === 'shadow') shadow.append(audio);
        window.audio = audio;
        // Eight seconds of silent PCM: exercise real media events without playing sound.
        const buffer = new ArrayBuffer(44 + 8000 * 8 * 2), data = new DataView(buffer);
        const text = (offset, value) => [...value].forEach((c, i) => data.setUint8(offset+i,c.charCodeAt(0)));
        text(0,'RIFF'); data.setUint32(4,buffer.byteLength-8,true); text(8,'WAVE'); text(12,'fmt ');
        data.setUint32(16,16,true); data.setUint16(20,1,true); data.setUint16(22,1,true);
        data.setUint32(24,8000,true); data.setUint32(28,16000,true); data.setUint16(32,2,true); data.setUint16(34,16,true);
        text(36,'data'); data.setUint32(40,buffer.byteLength-44,true);
        audio.src = URL.createObjectURL(new Blob([buffer], {type:'audio/wav'})); audio.loop = true;
        audio.play();
        </script>
        """#, baseURL: URL(string: "https://audio.example"))
    try await mediaWait { controller.media.sessions.first?.playing == true && controller.media.sessions.first?.actions.contains("seekto") == true }
    var state = try #require(controller.media.sessions.first)
    #expect(state.title == "Audio fallback")
    #expect(state.actions == ["play", "pause", "seekto"])
    #expect(state.timeline?.duration == 8)
    #expect(await controller.media.send("pause", to: state))
    try await mediaWait { controller.media.sessions.first?.playing == false }
    state = try #require(controller.media.sessions.first)
    #expect(await controller.media.send("seekto", to: state, value: 4))
    try await mediaWait { abs((controller.media.sessions.first?.timeline?.position ?? 0) - 4) < 0.1 }
    #expect(try await web.evaluateJavaScript("audio.currentTime") as? Double == 4)
    #expect(!(await controller.media.send("volume", to: state, value: 0.25)))
    #expect(try await web.evaluateJavaScript("audio.volume") as? Double == 1)
    #expect(await controller.media.send("play", to: state))
    try await mediaWait { controller.media.sessions.first?.playing == true }
    let focus = MediaPlaybackFocus()
    focus.register(controller.media)
    let other = PageController(address: "browse://start")
    focus.register(other.media)
    defer { other.media.detach(); other.webView.stopLoading() }
    other.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://interrupt.example"))
    try await mediaWait { other.media.sessions.first?.playing == true && controller.media.sessions.first?.playing == false }
    #expect(try await web.evaluateJavaScript("audio.paused") as? Bool == true)
    _ = try await web.evaluateJavaScript("audio.pause(); audio.remove(); audio.removeAttribute('src'); audio.load(); void 0")
    await controller.media.refresh()
    try await mediaWait { controller.media.sessions.isEmpty }
}

// @lat: [[tests#Exclusive media playback]]
@Test @MainActor func exclusiveMediaPlayback() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendMediaFocus-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let firstWindow = try #require(owner.active)
    let secondWindow = owner.newWindow(show: false)
    firstWindow.store.onAddressRequested = nil; secondWindow.store.onAddressRequested = nil
    defer { owner.prepareToQuit(); firstWindow.window.close(); secondWindow.window.close() }
    let first = firstWindow.store.controller(for: firstWindow.store.selectedTab.pages[0])
    first.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://first.example"))
    try await mediaWait { first.media.sessions.first?.playing == true }
    let oldFirst = try #require(first.media.sessions.first)
    // Start in another pane of the same window, then in another window.
    try #require(firstWindow.store.selectedTab.pages.count > 1)
    let second = firstWindow.store.controller(for: firstWindow.store.selectedTab.pages.last!)
    second.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://second.example"))
    try await mediaWait { second.media.sessions.first?.playing == true && first.media.sessions.first?.playing == false }
    let third = secondWindow.store.controller(for: secondWindow.store.selectedTab.pages[0])
    third.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://third.example"))
    try await mediaWait { third.media.sessions.first?.playing == true && second.media.sessions.first?.playing == false }
    #expect(first.media.sessions.first?.playing == false)
    // Returning to the old pane takes ownership, without automatically resuming anything else later.
    #expect(await first.media.send("play", to: oldFirst))
    try await mediaWait { first.media.sessions.first?.playing == true && third.media.sessions.first?.playing == false }
    let resumed = try #require(first.media.sessions.first)
    #expect(resumed.playbackRevision > oldFirst.playbackRevision)
    // Simulate a pause already queued for an older playback generation.
    await first.media.pauseForFocusLoss([oldFirst]) { true }
    #expect(first.media.sessions.first?.playing == true)
    #expect(try await first.webView.evaluateJavaScript("navigator.mediaSession.playbackState") as? String == "playing")
    #expect(await first.media.send("pause", to: resumed))
    try await mediaWait { first.media.sessions.first?.playing == false }
    #expect(second.media.sessions.first?.playing == false)
    #expect(third.media.sessions.first?.playing == false)
}

// @lat: [[tests#Sidebar media ownership]]
@Test @MainActor func sidebarMediaOwnership() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendMedia-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let first = try #require(owner.active)
    let second = owner.newWindow(show: false)
    first.store.onAddressRequested = nil; second.store.onAddressRequested = nil
    defer { owner.prepareToQuit(); first.window.close(); second.window.close() }
    let page = first.store.selectedTab.pages[0]
    let pageController = first.store.controller(for: page)
    pageController.isStartPage = false
    pageController.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://music.example"))
    try await mediaWait { first.store.mediaCoordinator.selected?.state.title == "First track" }
    if let path = ProcessInfo.processInfo.environment["BEND_MEDIA_SNAPSHOT"] {
        let alternate = PageController(address: "browse://start")
        let alternateID = UUID()
        alternate.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://second.example"))
        try await mediaWait { !alternate.media.sessions.isEmpty }
        first.store.mediaCoordinator.register(alternateID, controller: alternate.media)
        first.store.mediaCoordinator.select(try #require(first.store.mediaCoordinator.sources.first { $0.paneID == page.id }))
        defer {
            first.store.mediaCoordinator.unregister(alternateID)
            alternate.media.detach(); alternate.webView.stopLoading()
        }
        _ = try await pageController.webView.evaluateJavaScript("navigator.mediaSession.metadata.title = 'A long track title that should truncate inside the glass header'; navigator.mediaSession.setPositionState({duration:240,position:75}); navigator.mediaSession.setActionHandler('seekto', () => {}); void 0")
        await pageController.media.refresh()
        pageController.favicon = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: nil)
        for width in [100.0, 236.0, 300.0] {
            first.store.resizeSidebar(to: width)
            let preview = NSHostingView(rootView: SidebarMediaPlayer(coordinator: first.store.mediaCoordinator, store: first.store)
                .frame(width: width).preferredColorScheme(.dark))
            let previewWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 150),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
            previewWindow.isReleasedWhenClosed = false
            previewWindow.contentView = preview; previewWindow.orderFront(nil)
            for _ in 0..<5 { preview.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
            let bitmap = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            let destination = width == 236 ? path : path + "-\(Int(width)).png"
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: destination))
            previewWindow.close()
        }
        first.store.resizeSidebar(to: 236)
        first.window.setFrame(NSRect(x: -10000, y: -10000, width: 1100, height: 720), display: true)
        first.window.orderFront(nil)
        let content = try #require(first.window.contentView)
        for _ in 0..<5 { content.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-window.png"))
        _ = try await pageController.webView.evaluateJavaScript("navigator.mediaSession.metadata.title = 'First track'; void 0")
        await pageController.media.refresh()
    }
    let sourceTab = first.store.selectedTab.id
    first.store.newTab()
    #expect(first.store.selectedTab.id != sourceTab)
    await first.store.mediaCoordinator.send("nexttrack")
    try await mediaWait { first.store.mediaCoordinator.selected?.state.title == "Next track" }
    let source = try #require(first.store.mediaCoordinator.selected)
    first.store.revealPage(source.paneID)
    #expect(first.store.selectedTab.id == sourceTab)
    let originalWeb = pageController.webView
    let target = second.store.selectedTab.id
    #expect(first.store.transfer(tab: sourceTab, pane: page.id, to: second.store, at: .insert(relativeTo: target, after: true)))
    #expect(first.store.mediaCoordinator.selected == nil)
    #expect(second.store.mediaCoordinator.selected?.state.title == "Next track")
    #expect(second.store.existingController(for: page.id)?.webView === originalWeb)
    await second.store.mediaCoordinator.send("pause")
    try await mediaWait { second.store.mediaCoordinator.selected?.state.playing == false }
    second.store.mediaCoordinator.dismiss()
    await pageController.media.refresh()
    #expect(second.store.mediaCoordinator.selected == nil)
    let state = try #require(pageController.media.sessions.first)
    #expect(await pageController.media.send("play", to: state))
    try await mediaWait { second.store.mediaCoordinator.selected != nil }
    second.store.closePage(page.id)
    #expect(second.store.mediaCoordinator.sources.isEmpty)
}

// @lat: [[tests#Media track transitions]]
@Test @MainActor func mediaTrackTransitions() async throws {
    _ = NSApplication.shared
    let first = PageController(address: "browse://start"), second = PageController(address: "browse://start")
    let coordinator = WindowMediaCoordinator()
    let firstID = UUID(), secondID = UUID()
    coordinator.register(firstID, controller: first.media)
    coordinator.register(secondID, controller: second.media)
    defer { coordinator.removeAll(); first.media.detach(); second.media.detach() }
    first.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://first.example"))
    try await mediaWait { coordinator.selected?.paneID == firstID }
    second.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://second.example"))
    try await mediaWait { coordinator.selected?.paneID == secondID }
    let selectedID = try #require(coordinator.selectedID)
    var selections: [String?] = []
    let observation = coordinator.$selectedID.sink { selections.append($0) }
    defer { observation.cancel() }
    // A pause between tracks must not prefer an older source still reporting playback.
    _ = try await second.webView.evaluateJavaScript("navigator.mediaSession.playbackState = 'paused'; void 0")
    try await mediaWait { second.media.sessions.first?.playing == false }
    #expect(coordinator.selectedID == selectedID)
    // Some players briefly clear their entire Media Session during track replacement.
    let clear = "navigator.mediaSession.metadata = null; navigator.mediaSession.playbackState = 'none'; void 0"
    _ = try await second.webView.evaluateJavaScript(clear)
    try await mediaWait { coordinator.selected?.state.actions.isEmpty == true }
    #expect(coordinator.sources.count == 2)
    #expect(coordinator.selectedID == selectedID)
    try await Task.sleep(for: .milliseconds(200))
    _ = try await second.webView.evaluateJavaScript("""
        navigator.mediaSession.metadata = new MediaMetadata({title:'Replacement track'});
        navigator.mediaSession.playbackState = 'playing'; void 0
        """)
    try await mediaWait { coordinator.selected?.state.title == "Replacement track" }
    #expect(selections.allSatisfy { $0 == selectedID })
    // A real stop expires; navigation bypasses the transition delay entirely.
    _ = try await second.webView.evaluateJavaScript(clear)
    try await mediaWait { coordinator.selected?.paneID == firstID }
    _ = try await second.webView.evaluateJavaScript("navigator.mediaSession.playbackState = 'playing'; void 0")
    try await mediaWait { coordinator.selected?.paneID == secondID }
    _ = try await second.webView.evaluateJavaScript(clear)
    try await mediaWait { coordinator.selected?.state.actions.isEmpty == true }
    second.navigate("browse://start")
    #expect(coordinator.selected?.paneID == firstID)
    #expect(second.media.sessions.isEmpty)
}

// @lat: [[tests#Media source menu images]]
@Test @MainActor func mediaSourceMenuImages() throws {
    _ = NSApplication.shared
    let source = SidebarMediaSource(paneID: UUID(), state: MediaSessionState(
        id: "one", playerID: "session", title: "First track", artist: "Artist", site: "first.example",
        playing: true, playbackRevision: 1, actions: [], timeline: nil))
    let other = SidebarMediaSource(paneID: UUID(), state: MediaSessionState(
        id: "two", playerID: "session", title: "Second track", artist: "Artist", site: "second.example",
        playing: false, playbackRevision: 1, actions: [], timeline: nil))
    let favicon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor.systemGreen.setFill(); rect.fill(); return true
    }
    let presenter = MediaSourceMenu()
    var selected: String?
    let menu = presenter.makeMenu(sources: [source, other], selectedID: source.id,
        favicon: { $0 == source.paneID ? favicon : nil }, onSelect: { selected = $0 })
    #expect(menu.items.map { $0.representedObject as? String } == [source.id, other.id])
    #expect(menu.items.map(\.state) == [.on, .off])
    for item in menu.items {
        #expect(item.image?.size == NSSize(width: 16, height: 16))
        if #available(macOS 27.0, *) {
            #expect((item.value(forKey: "preferredImageVisibility") as? NSNumber)?.intValue == 1)
        }
    }
    #expect(favicon.size == NSSize(width: 32, height: 32))
    let item = menu.items[1]
    #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    #expect(selected == other.id)
}

// @lat: [[tests#Media source selection]]
@Test @MainActor func mediaSourceSelection() async throws {
    _ = NSApplication.shared
    let first = PageController(address: "browse://start"), second = PageController(address: "browse://start")
    let coordinator = WindowMediaCoordinator()
    let firstID = UUID(), secondID = UUID()
    coordinator.register(firstID, controller: first.media)
    coordinator.register(secondID, controller: second.media)
    defer { coordinator.removeAll(); first.media.detach(); second.media.detach() }
    first.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://first.example"))
    try await mediaWait { coordinator.selected?.paneID == firstID }
    let firstSource = try #require(coordinator.selected)
    second.webView.loadHTMLString(mediaSessionFixture, baseURL: URL(string: "https://second.example"))
    try await mediaWait { coordinator.sources.count == 2 && coordinator.selected?.paneID == secondID }
    #expect(coordinator.sources.map(\.paneID) == [secondID, firstID])
    coordinator.select(firstSource)
    await second.media.refresh()
    #expect(coordinator.selected?.paneID == firstID)
    #expect(coordinator.sources.map(\.paneID) == [firstID, secondID])
    let secondSource = try #require(coordinator.sources.first { $0.paneID == secondID })
    coordinator.select(secondSource)
    // An already-clicked control retains its source even if selection changes before dispatch.
    await coordinator.send("pause", to: firstSource)
    try await mediaWait { first.media.sessions.first?.playing == false }
    #expect(second.media.sessions.first?.playing == true)
    #expect(coordinator.sources.map(\.paneID) == [secondID, firstID])
    coordinator.select(firstSource)
    #expect(coordinator.selected?.paneID == firstID)
    coordinator.dismiss()
    #expect(coordinator.selected == nil)
    #expect(coordinator.sources.count == 2)
    #expect(second.media.sessions.first?.playing == true)
    await first.media.refresh()
    await second.media.refresh()
    #expect(coordinator.selected == nil)
    #expect(coordinator.sources.map(\.paneID) == [firstID, secondID])
    _ = try await second.webView.evaluateJavaScript("navigator.mediaSession.metadata.title = 'Updated title'; void 0")
    await second.media.refresh()
    #expect(coordinator.selected == nil)
    // New playback reopens the panel with all players still available.
    #expect(await first.media.send("play", to: firstSource.state))
    try await mediaWait { coordinator.selected?.paneID == firstID }
    #expect(coordinator.sources.count == 2)
    first.navigate("browse://start")
    #expect(first.media.sessions.isEmpty)
    #expect(coordinator.selected?.paneID == secondID)
    coordinator.unregister(secondID)
    #expect(coordinator.sources.isEmpty)
}

// @lat: [[tests#Live media session smoke test]]
@Test(.enabled(if: ProcessInfo.processInfo.environment["BEND_MEDIA_SMOKE_URL"] != nil))
@MainActor func liveMediaSessionSmoke() async throws {
    _ = NSApplication.shared
    let address = try #require(ProcessInfo.processInfo.environment["BEND_MEDIA_SMOKE_URL"])
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.applicationNameForUserAgent = PageController.websiteApplicationName
    let web = FocusWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderFront(nil)
    let page = PageController(address: address, webView: web)
    defer { page.media.reset(); web.stopLoading(); window.close() }
    for _ in 0..<120 {
        _ = try? await web.evaluateJavaScript("""
            (() => {
                const media = document.querySelector('video,audio');
                if (media && !window.bendSmokeStarted) {
                    window.bendSmokeStarted = true; media.muted = true; media.play().catch(() => {});
                }
            })()
            """)
        if page.media.sessions.contains(where: { $0.playing }) { break }
        try await Task.sleep(for: .milliseconds(250))
    }
    let state = try #require(page.media.sessions.first { $0.playing })
    let title = try #require(try await web.evaluateJavaScript("navigator.mediaSession?.metadata?.title") as? String)
    #expect(!title.isEmpty)
    #expect(state.title == PageMediaController.clean(title))
    #expect(await page.media.send("pause", to: state))
    try await mediaWait { page.media.sessions.first?.playing == false }
    let paused = try #require(page.media.sessions.first)
    #expect(await page.media.send("play", to: paused))
    try await mediaWait { page.media.sessions.first?.playing == true }
    _ = await page.media.send("pause", to: state)
    print("LIVE_MEDIA: metadata title matched; pause/resume succeeded; actions=\(state.actions.sorted())")
}
