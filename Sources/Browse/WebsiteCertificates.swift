import AppKit
import WebKit
import BrowseCore
import SecurityInterface

@MainActor
final class WebsiteCertificates: NSObject {
    private var panel: SFCertificatePanel?
    private var sheet: NSWindow?
    private var observedTrust: [String: SecTrust] = [:]

    // WebKit can omit serverTrust on a committed HTTPS document (for example
    // x.com). Keep the trust supplied by its TLS challenges for inspection only.
    func record(_ trust: SecTrust, for url: URL) {
        guard url.scheme == "https", let origin = WebsitePermission.origin(for: url) else { return }
        observedTrust[origin] = trust
    }

    func reset() {
        cancel()
        observedTrust.removeAll()
    }

    func trust(for webView: WKWebView, committedURL: URL?) -> SecTrust? {
        guard !webView.isLoading, Self.matchesSite(webView.url, committed: committedURL),
              let committedURL, let origin = WebsitePermission.origin(for: committedURL) else { return nil }
        return webView.serverTrust ?? observedTrust[origin]
    }

    static func matchesSite(_ current: URL?, committed: URL?) -> Bool {
        guard let current, let committed, committed.scheme == "https",
              let origin = WebsitePermission.origin(for: committed) else { return false }
        return WebsitePermission.origin(for: current) == origin
    }

    func show(_ trust: SecTrust, for webView: WKWebView) {
        guard let window = webView.window,
              window.attachedSheet == nil else { return }
        let panel = SFCertificatePanel()
        self.panel = panel
        panel.title = "HTTPS Certificates — \(webView.url?.host ?? "")"
        panel.setDefaultButtonTitle("Done")
        panel.setAlternateButtonTitle(nil)
        panel.beginSheet(for: window, modalDelegate: self,
                         didEnd: #selector(didEnd(_:returnCode:contextInfo:)), contextInfo: nil,
                         trust: trust, showGroup: true)
        // SecurityInterface may create a separate panel for the actual sheet.
        sheet = window.attachedSheet
        panel.certificateView().setEditableTrust(false)
    }

    @objc private func didEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        if panel === sheet || self.sheet === sheet || self.sheet?.sheetParent === sheet {
            panel = nil
            self.sheet = nil
        }
    }

    func cancel() {
        guard let panel else { return }
        // Dismiss through SecurityInterface's Done action on the actual sheet,
        // retaining its controller until the action has completed.
        sheet?.defaultButtonCell?.performClick(nil)
        sheet?.orderOut(nil)
        self.sheet = nil
        self.panel = nil
        withExtendedLifetime(panel) {}
    }
}
