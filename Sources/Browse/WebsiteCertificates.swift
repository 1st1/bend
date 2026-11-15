import AppKit
import WebKit
import BrowseCore
import SecurityInterface

@MainActor
final class WebsiteCertificates: NSObject {
    private var panel: SFCertificatePanel?

    static func matchesSite(_ current: URL?, committed: URL?) -> Bool {
        guard let current, let committed, committed.scheme == "https",
              let origin = WebsitePermission.origin(for: committed) else { return false }
        return WebsitePermission.origin(for: current) == origin
    }

    func show(for webView: WKWebView) {
        guard !webView.isLoading, webView.url?.scheme == "https",
              let trust = webView.serverTrust, let window = webView.window,
              window.attachedSheet == nil else { return }
        let panel = SFCertificatePanel()
        self.panel = panel
        panel.title = "HTTPS Certificates — \(webView.url?.host ?? "")"
        panel.setDefaultButtonTitle("Done")
        panel.setAlternateButtonTitle(nil)
        panel.beginSheet(for: window, modalDelegate: self,
                         didEnd: #selector(didEnd(_:returnCode:contextInfo:)), contextInfo: nil,
                         trust: trust, showGroup: true)
        panel.certificateView().setEditableTrust(false)
    }

    @objc private func didEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        if panel === sheet { panel = nil }
    }

    func cancel() {
        guard let panel else { return }
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        self.panel = nil
    }
}
