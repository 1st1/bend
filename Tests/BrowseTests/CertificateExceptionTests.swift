import AppKit
import Security
import Testing
import BrowseCore
import WebKit
@testable import Browse

@Test @MainActor func rememberedHTTPFallback() async throws {
    _ = NSApplication.shared
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("settings.db")
    let settings = WebsiteSettingsStore(file: file)
    let path = "127.0.0.1:\(server.port)/test?q=1"
    let page = PageController(address: "https://\(path)", websiteSettings: settings)
    for _ in 0..<600 where page.error == nil { try await Task.sleep(for: .milliseconds(25)) }
    #expect(try #require(page.httpFallbackURL, "WebKit error: \(page.error ?? "none"), URL: \(String(describing: page.webView.url))").absoluteString == "http://\(path)")
    settings.setPreference(\.warnHTTP, true)
    page.proceedWithoutTLS()
    for _ in 0..<200 where page.committedSiteURL?.scheme != "http" || page.webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }
    #expect(try await page.webView.evaluateJavaScript("document.body.innerText") as? String == "Fixture")
    #expect(page.webView.url?.absoluteString == "http://\(path)")
    #expect(WebsiteSettingsStore(file: file).values.allowsHTTP(try #require(page.webView.url)))

    let address = "100.91.15.25:9000"
    settings.allowHTTP(for: try #require(URL(string: "http://\(address)")))
    let reopened = WebsiteSettingsStore(file: file)
    func scheme(_ input: String) -> String? {
        reopened.values.locationURL(input, searchEngine: .google, customSearchEngine: nil)?.scheme
    }
    #expect(scheme("\(address)/status") == "http")
    #expect(scheme("100.91.15.25:9001") == "https")
    #expect(scheme("https://\(address)") == "https")
    reopened.forgetHTTP("http://\(address)")
    #expect(scheme(address) == "https")
}

@MainActor private final class CertificateTestWebView: FocusWebView {
    var omitsServerTrust = false
    override var serverTrust: SecTrust? { omitsServerTrust ? nil : super.serverTrust }
}

// @lat: [[lat.md/tests/settings-tests#Settings tests#Certificate exceptions]]
@Test @MainActor func certificateExceptions() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-c", #"""
import http.server, ssl, subprocess, sys, pathlib
root = pathlib.Path(sys.argv[1])
subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(root/'key'), '-out', str(root/'cert'), '-days', '1', '-subj', '/CN=localhost'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'<title>Router fixture</title>Router settings')
    def log_message(self, *args): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(str(root/'cert'), str(root/'key'))
server.socket = context.wrap_socket(server.socket, server_side=True)
(root/'port').write_text(str(server.server_port))
server.serve_forever()
"""#, directory.path]
    try server.run()
    defer { server.terminate(); server.waitUntilExit() }
    let portFile = directory.appendingPathComponent("port")
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: portFile.path) { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let port = try String(contentsOf: portFile, encoding: .utf8)
    let address = "https://127.0.0.1:\(port)/"
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let webView = CertificateTestWebView(frame: .zero, configuration: configuration)
    let page = PageController(address: address, webView: webView)
    defer { page.webView.stopLoading() }
    for _ in 0..<400 {
        if page.error != nil { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let failure = try #require(page.certificateFailure)
    #expect(failure.url.absoluteString == address)
    #expect(page.webView.title != "Router fixture")
    #expect(!page.usesCertificateException)
    let certificate = try #require(SecCertificateCreateWithData(nil, failure.exception.certificate as CFData))
    var trust: SecTrust?
    #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
    let peerTrust = try #require(trust)
    #expect(CertificateException(url: URL(string: address + "settings")!, trust: peerTrust) == failure.exception)
    #expect(CertificateException(url: URL(string: "https://localhost:\(port)/")!, trust: peerTrust) != failure.exception)
    #expect(CertificateException(url: URL(string: "https://127.0.0.1:1/")!, trust: peerTrust) != failure.exception)
    #expect(CertificateException(url: URL(string: "http://127.0.0.1:\(port)/")!, trust: peerTrust) == nil)
    var changedBytes = failure.exception.certificate
    changedBytes[changedBytes.count - 1] ^= 1
    let changedCertificate = try #require(SecCertificateCreateWithData(nil, changedBytes as CFData))
    var changedTrust: SecTrust?
    #expect(SecTrustCreateWithCertificates(changedCertificate, SecPolicyCreateBasicX509(), &changedTrust) == errSecSuccess)
    #expect(CertificateException(url: URL(string: address)!, trust: try #require(changedTrust)) != failure.exception)
    // No exception is inferred from a retry.
    page.navigate(address)
    for _ in 0..<400 {
        if page.error != nil { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(page.certificateFailure != nil)
    page.continueDespiteCertificateError()
    for _ in 0..<400 {
        if page.webView.title == "Router fixture" || page.error != nil { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(page.error == nil)
    #expect(page.webView.title == "Router fixture")
    #expect(page.usesCertificateException)
    #expect(page.certificateFailure == nil)
    for _ in 0..<100 where page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
    let nativeTrust = try #require(page.certificateTrust)
    webView.omitsServerTrust = true
    #expect(webView.serverTrust == nil)
    let observedTrust = try #require(page.certificateTrust)
    #expect(CertificateException(url: URL(string: address)!, trust: observedTrust)
        == CertificateException(url: URL(string: address)!, trust: nativeTrust))
    // A challenge for another origin must never supply this page's certificate.
    let unrelated = WebsiteCertificates()
    unrelated.record(observedTrust, for: URL(string: "https://localhost:\(port)/")!)
    #expect(unrelated.trust(for: webView, committedURL: URL(string: address)) == nil)
    let committed = page.committedSiteURL
    page.committedSiteURL = URL(string: "https://localhost:\(port)/")
    #expect(page.certificateTrust == nil)
    page.committedSiteURL = committed
    page.isLoading = true
    #expect(page.certificateTrust == nil)
    page.isLoading = false
    page.error = "Navigation failed"
    #expect(page.certificateTrust == nil)
    page.error = nil
    #expect(page.certificateTrust != nil)
    // Real native inspection uses the same fallback as the menu, with no reload.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = webView
    window.orderFront(nil)
    page.showCertificates()
    #expect(window.attachedSheet != nil)
    page.certificates.cancel()
    for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(window.attachedSheet == nil)
    window.contentView = nil
    window.close()
    page.certificates.reset()
    #expect(page.certificateTrust == nil)
    webView.omitsServerTrust = false
    #expect(page.certificateTrust != nil)

    let other = PageController(address: address, configure: { $0.websiteDataStore = .nonPersistent() })
    defer { other.webView.stopLoading() }
    for _ in 0..<400 {
        if other.error != nil { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(other.certificateFailure != nil)
    #expect(!other.usesCertificateException)
    page.navigate("bend://start")
    #expect(!page.usesCertificateException)
    #expect(page.certificateFailure == nil)
    #expect(CertificateException.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)) == nil)
}
