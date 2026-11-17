import AppKit
import WebKit

// @lat: [[lat.md/architecture/link-navigation#Back from a link-created tab]]
/// Suppress only an unavailable sentinel destination, before WebKit creates its preview.
@MainActor final class HistorySwipeGuard {
    private weak var webView: WKWebView?
    private let blocked: () -> Bool
    private var monitor: Any?
    private var observing = false
    private var directionChosen = false
    private var blocksThisGesture = false

    init(webView: WKWebView, blocked: @escaping () -> Bool) {
        self.webView = webView
        self.blocked = blocked
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
            return event
        }
    }
    deinit {
        MainActor.assumeIsolated { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    private func receive(_ event: NSEvent) {
        guard let webView, let window = webView.window, event.window === window else { return }
        if event.phase == .began {
            guard let content = window.contentView,
                  let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                  hit === webView || hit.isDescendant(of: webView) else { observing = false; return }
            observing = true
        }
        if observing { observe(event) }
    }
    func observe(_ event: NSEvent) {
        guard let webView, event.momentumPhase.isEmpty else { return }
        if event.phase == .began {
            blocksThisGesture = blocked()
            directionChosen = false
            webView.allowsBackForwardNavigationGestures = true
        }
        guard event.phase == .began || event.phase == .changed,
              blocksThisGesture, !directionChosen else { return }
        let delta = event.scrollingDeltaX * (webView.userInterfaceLayoutDirection == .rightToLeft ? -1 : 1)
        guard delta != 0 else { return }
        directionChosen = true
        if delta > 0 { webView.allowsBackForwardNavigationGestures = false }
        // Leave it disabled through release and momentum: asynchronous unhandled
        // wheel replies must not restart this rejected swipe. The next gesture
        // reevaluates eligibility, and real navigation restores snapshot recording.
    }
    func historyDidChange() {
        if !blocked() { webView?.allowsBackForwardNavigationGestures = true }
    }
}
