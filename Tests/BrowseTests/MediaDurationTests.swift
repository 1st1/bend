import AppKit
import Testing
import WebKit
@testable import Browse

@MainActor private func durationWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<150 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(predicate())
}

// @lat: [[lat.md/tests/media-tests#Short media filtering]]
@Test @MainActor func shortMediaFiltering() async throws {
    _ = NSApplication.shared
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    let web = FocusWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration)
    let page = PageController(address: "browse://start", webView: web)
    let music = PageController(address: "browse://start")
    let focus = MediaPlaybackFocus()
    focus.register(page.media); focus.register(music.media)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderFront(nil)
    defer { page.media.detach(); music.media.detach(); web.stopLoading(); music.webView.stopLoading(); window.close() }
    music.webView.loadHTMLString("""
        <script>
        navigator.mediaSession.setPositionState({duration:60});
        navigator.mediaSession.setActionHandler('pause', () => navigator.mediaSession.playbackState = 'paused');
        navigator.mediaSession.playbackState = 'playing';
        </script>
        """, baseURL: URL(string: "https://music.example"))
    try await durationWait { music.media.sessions.first?.playing == true }
    var reported: [MediaSessionState] = []
    let observation = page.media.$sessions.sink { reported.append(contentsOf: $0) }
    defer { observation.cancel() }
    web.loadHTMLString(#"""
        <title>Duration fixture</title><script>
        window.makeAudio = async (seconds, tag) => {
            const audio = document.createElement(tag); document.documentElement.append(audio);
            const buffer = new ArrayBuffer(44 + Math.round(8000 * seconds) * 2), data = new DataView(buffer);
            const text = (offset, value) => [...value].forEach((c, i) => data.setUint8(offset+i,c.charCodeAt(0)));
            text(0,'RIFF'); data.setUint32(4,buffer.byteLength-8,true); text(8,'WAVE'); text(12,'fmt ');
            data.setUint32(16,16,true); data.setUint16(20,1,true); data.setUint16(22,1,true);
            data.setUint32(24,8000,true); data.setUint32(28,16000,true); data.setUint16(32,2,true); data.setUint16(34,16,true);
            text(36,'data'); data.setUint32(40,buffer.byteLength-44,true);
            audio.src = URL.createObjectURL(new Blob([buffer], {type:'audio/wav'})); audio.loop = true;
            await audio.play(); return audio;
        };
        window.ready = true;
        </script>
        """#, baseURL: URL(string: "https://notification.example"))
    try await durationWait { web.title == "Duration fixture" }
    // Real metadata/load/play events must never briefly expose a short player.
    for tag in ["audio", "video"] {
        for duration in [1.0, 7.0] {
            _ = try await web.callAsyncJavaScript("window.short = await makeAudio(seconds, tag); return true",
                arguments: ["seconds": duration, "tag": tag], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(100))
            #expect(reported.isEmpty)
            #expect(music.media.sessions.first?.playing == true)
            #expect(try await web.evaluateJavaScript("short.duration") as? Double == duration)
            _ = try await web.evaluateJavaScript("short.pause(); short.remove(); short.removeAttribute('src'); short.load(); void 0")
        }
    }
    _ = try await web.callAsyncJavaScript("window.long = await makeAudio(7.125, 'audio'); return true",
        arguments: [:], in: nil, contentWorld: .page)
    try await durationWait { page.media.sessions.first?.timeline?.duration == 7.125 && music.media.sessions.first?.playing == false }
    let playerID = try #require(page.media.sessions.first?.playerID)
    _ = try await web.callAsyncJavaScript("window.short = await makeAudio(1, 'audio'); return true",
        arguments: [:], in: nil, contentWorld: .page)
    try await Task.sleep(for: .milliseconds(100))
    #expect(page.media.sessions.first?.playerID == playerID)
    #expect(page.media.sessions.first?.timeline?.duration == 7.125)
    #expect(reported.allSatisfy { $0.timeline?.duration == 7.125 })
}

// @lat: [[lat.md/tests/media-tests#Unknown media duration qualification]]
@Test(arguments: [false, true]) @MainActor func unknownMediaDurationQualification(live: Bool) async throws {
    _ = NSApplication.shared
    let page = PageController(address: "browse://start")
    defer { page.media.detach(); page.webView.stopLoading() }
    let web = page.webView
    web.loadHTMLString("""
        <title>Unknown duration</title><script>
        navigator.mediaSession.setActionHandler('pause', () => navigator.mediaSession.playbackState = 'paused');
        \(live ? "navigator.mediaSession.setPositionState({duration:Infinity});" : "")
        navigator.mediaSession.playbackState = 'playing';
        </script>
        """, baseURL: URL(string: "https://live.example"))
    try await durationWait { web.title == "Unknown duration" }
    try await Task.sleep(for: .milliseconds(300))
    #expect(page.media.sessions.isEmpty)
    // Waiting while paused must not qualify the player or leave a wakeup armed.
    _ = try await web.evaluateJavaScript("navigator.mediaSession.playbackState = 'paused'; void 0")
    try await Task.sleep(for: .seconds(7.1))
    #expect(page.media.sessions.isEmpty)
    _ = try await web.evaluateJavaScript("navigator.mediaSession.playbackState = 'playing'; void 0")
    try await Task.sleep(for: .milliseconds(100))
    #expect(page.media.sessions.isEmpty)
    for _ in 0..<400 where page.media.sessions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(page.media.sessions.first?.playing == true)
    #expect(page.media.sessions.first?.timeline == nil)
    // Known short duration overrides prior qualification; a longer track returns immediately.
    _ = try await web.evaluateJavaScript("navigator.mediaSession.setPositionState({duration:7}); void 0")
    try await durationWait { page.media.sessions.isEmpty }
    _ = try await web.evaluateJavaScript("navigator.mediaSession.setPositionState({duration:7.01}); void 0")
    try await durationWait { page.media.sessions.first?.timeline?.duration == 7.01 }
}

// @lat: [[lat.md/tests/media-tests#Media qualification lifecycle]]
@Test @MainActor func mediaQualificationLifecycle() async throws {
    _ = NSApplication.shared
    let page = PageController(address: "browse://start")
    defer { page.media.detach(); page.webView.stopLoading() }
    let web = page.webView
    // A controlled HTML media clock covers buffering and resource changes
    // without relying on network stalls or waiting through long wall-clock gaps.
    web.loadHTMLString("""
        <title>Qualification lifecycle</title><script>
        window.clock = 0;
        Object.defineProperty(performance, 'now', {value: () => clock * 1000});
        window.state = {duration:Infinity, paused:false};
        window.audio = document.createElement('audio');
        Object.defineProperties(audio, {
            duration:{get:()=>state.duration}, paused:{get:()=>state.paused},
            ended:{get:()=>false}, readyState:{get:()=>4}, networkState:{get:()=>2}
        });
        document.documentElement.append(audio);
        </script>
        """, baseURL: URL(string: "https://lifecycle.example"))
    try await durationWait { web.title == "Qualification lifecycle" }
    func event(_ script: String, _ name: String = "durationchange") async throws {
        _ = try await web.evaluateJavaScript("\(script); audio.dispatchEvent(new Event('\(name)')); void 0")
        try await Task.sleep(for: .milliseconds(50))
    }
    try await event("clock = 3; state.paused = true", "pause")
    try await event("clock = 40")
    #expect(page.media.sessions.isEmpty)
    try await event("state.paused = false", "playing")
    try await event("clock = 42", "waiting")
    try await event("clock = 80")
    #expect(page.media.sessions.isEmpty)
    try await event("clock = 80", "playing")
    try await event("clock = 82.1")
    try await durationWait { page.media.sessions.first?.playing == true }
    #expect(page.media.sessions.first?.timeline == nil)
    // A replacement resource cannot inherit the previous stream's eligibility.
    try await event("clock = 83", "emptied")
    #expect(page.media.sessions.isEmpty)
    try await event("clock = 100; state.duration = 7")
    #expect(page.media.sessions.isEmpty)
    try await event("state.duration = 7.1")
    try await durationWait { page.media.sessions.first?.timeline?.duration == 7.1 }
    // Losing timing after qualification should not make controls jump away.
    try await event("state.duration = NaN")
    #expect(page.media.sessions.first?.playing == true)
}
