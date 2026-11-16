import AppKit
import Security
import Testing
import WebKit
@testable import Browse

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
    let page = PageController(address: address, configure: { $0.websiteDataStore = .nonPersistent() })
    defer { page.webView.stopLoading() }
    for _ in 0..<400 {
        if page.error != nil { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let failure = try #require(page.certificateFailure)
    #expect(failure.url.absoluteString == address)
    #expect(page.webView.title != "Router fixture")
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
    #expect(page.certificateFailure == nil)

    let other = PageController(address: address, configure: { $0.websiteDataStore = .nonPersistent() })
    defer { other.webView.stopLoading() }
    for _ in 0..<400 {
        if other.error != nil { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(other.certificateFailure != nil)
    page.navigate("bend://start")
    #expect(page.certificateFailure == nil)
    #expect(CertificateException.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)) == nil)
}
