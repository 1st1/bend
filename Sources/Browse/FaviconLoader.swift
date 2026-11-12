import AppKit
import WebKit

// @lat: [[lat.md/architecture/favicons#Page favicons]]
@MainActor
enum FaviconLoader {
    static let world = WKContentWorld.world(name: "BendFavicon")
    static let discoveryScript = #"""
    const links = Array.from(document.querySelectorAll('link[rel][href]'));
    const icons = links.filter(link => link.rel.toLowerCase().split(/\s+/).includes('icon'));
    const touchIcons = links.filter(link => link.rel.toLowerCase() === 'apple-touch-icon');
    return [...icons, ...touchIcons].slice(0, 32).map(link => link.href).filter(url => url.length <= 4096);
    """#

    // Image loading stays in the originating document: img-src, mixed content,
    // redirects, CORS, and WebKit content blocking apply to every request. The
    // isolated world prevents a page from replacing our DOM/canvas functions.
    // Cross-origin images without CORS permission fail closed, never retry natively.
    static let imageScript = #"""
    return await new Promise(resolve => {
        const image = new Image();
        let timer;
        const finish = result => {
            clearTimeout(timer);
            image.onload = image.onerror = null;
            image.removeAttribute('src');
            resolve(result);
        };
        timer = setTimeout(() => finish(null), 2000);
        image.crossOrigin = 'anonymous';
        image.referrerPolicy = 'no-referrer';
        image.onload = () => {
            try {
                const width = image.naturalWidth, height = image.naturalHeight;
                if (!width || !height || width > 4096 || height > 4096) return finish(null);
                const canvas = document.createElement('canvas');
                canvas.width = canvas.height = 64;
                const scale = Math.min(64 / width, 64 / height);
                canvas.getContext('2d').drawImage(image, (64 - width * scale) / 2,
                    (64 - height * scale) / 2, width * scale, height * scale);
                finish(canvas.toDataURL('image/png'));
            } catch { finish(null); }
        };
        image.onerror = () => finish(null);
        image.src = url;
    });
    """#

    static func candidates(in webView: WKWebView, pageURL: URL) async -> [URL] {
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return [] }
        let links = (try? await webView.callAsyncJavaScript(discoveryScript, arguments: [:], in: nil, contentWorld: world)) as? [String] ?? []
        return candidates(links: links, pageURL: pageURL)
    }

    static func candidates(links: [String], pageURL: URL) -> [URL] {
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return [] }
        let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        var seen = Set<URL>()
        let icons = links.prefix(32).filter { $0.utf8.count <= 4096 }
            .compactMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL }
            .filter { ["http", "https", "data"].contains($0.scheme?.lowercased() ?? "") && $0 != fallback && seen.insert($0).inserted }
        return Array(icons.prefix(7)) + [fallback].compactMap { $0 }
    }

    static func sameOrigin(_ first: URL?, _ second: URL?) -> Bool {
        guard let first, let second, let scheme = first.scheme?.lowercased(),
              ["http", "https"].contains(scheme), scheme == second.scheme?.lowercased(),
              let host = first.host?.lowercased(), host == second.host?.lowercased() else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (first.port ?? defaultPort) == (second.port ?? defaultPort)
    }

    static func load(_ urls: [URL], in webView: WKWebView) async -> NSImage? {
        let pageURL = webView.url
        for url in urls.prefix(8) {
            guard !Task.isCancelled, webView.url == pageURL else { return nil }
            let result = try? await webView.callAsyncJavaScript(imageScript,
                arguments: ["url": url.absoluteString], in: nil, contentWorld: world)
            guard !Task.isCancelled, webView.url == pageURL else { return nil }
            // Only a bounded, WebKit-rasterized PNG crosses into the host process.
            guard let encoded = result as? String, encoded.utf8.count <= 65536,
                  encoded.hasPrefix("data:image/png;base64,"),
                  let data = Data(base64Encoded: String(encoded.dropFirst(22))),
                  let image = NSImage(data: data), image.isValid else { continue }
            return image
        }
        return nil
    }
}
