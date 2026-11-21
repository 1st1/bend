import Foundation
import Security
import WebKitFindSupport

// @lat: [[lat.md/architecture/web-pages#Web pages#Certificate exceptions]]
struct CertificateException: Hashable {
    let host: String
    let port: Int
    let certificate: Data

    init?(url: URL, trust: SecTrust) {
        guard url.scheme?.lowercased() == "https", let host = url.host,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        self.host = host.lowercased()
        port = url.port ?? 443
        certificate = SecCertificateCopyData(leaf) as Data
    }

    static func failure(_ error: NSError) -> (URL, CertificateException)? {
        guard error.domain == NSURLErrorDomain,
              [NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
               NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid].contains(error.code),
              let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
                ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:)),
              let trust = BendPeerTrust(error),
              let exception = CertificateException(url: url, trust: trust) else { return nil }
        return (url, exception)
    }
}
