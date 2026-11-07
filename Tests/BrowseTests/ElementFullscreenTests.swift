import AppKit
import Testing
import WebKit
@testable import Browse

// @lat: [[tests#Page fullscreen availability]]
@Test @MainActor func pageFullscreenAvailability() async throws {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start")
    let web = controller.webView
    defer { controller.media.detach(); web.stopLoading() }
    web.loadHTMLString("<title>Fullscreen fixture</title><video></video>",
                       baseURL: URL(string: "https://fullscreen.example"))
    for _ in 0..<100 {
        if (try? await web.evaluateJavaScript("document.title")) as? String == "Fullscreen fixture" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await web.evaluateJavaScript("document.fullscreenEnabled") as? Bool == true)
    #expect(try await web.evaluateJavaScript("typeof document.querySelector('video').requestFullscreen") as? String == "function")
    #expect(try await web.evaluateJavaScript("document.fullscreenElement === null") as? Bool == true)
}
