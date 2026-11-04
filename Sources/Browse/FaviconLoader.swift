import AppKit
import WebKit

@MainActor
enum FaviconLoader {
    static let discoveryScript = #"""
    (() => {
        const links = Array.from(document.querySelectorAll('link[rel][href]'));
        const icons = links.filter(link => link.rel.toLowerCase().split(/\s+/).includes('icon'));
        const touchIcons = links.filter(link => link.rel.toLowerCase() === 'apple-touch-icon');
        return [...icons, ...touchIcons].map(link => link.href);
    })()
    """#

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0)
        return URLSession(configuration: configuration)
    }()
    nonisolated private static let maximumBytes = 1024 * 1024

    static func candidates(in webView: WKWebView, pageURL: URL) async -> [URL] {
        let links: [String] = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(discoveryScript) { result, _ in
                continuation.resume(returning: result as? [String] ?? [])
            }
        }
        return candidates(links: links, pageURL: pageURL)
    }

    static func candidates(links: [String], pageURL: URL) -> [URL] {
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return [] }
        let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        var seen = Set<URL>()
        return (links.compactMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL } + [fallback].compactMap { $0 })
            .filter { ["http", "https", "data"].contains($0.scheme?.lowercased() ?? "") && seen.insert($0).inserted }
    }

    static func load(_ urls: [URL], fetch: (URL) async throws -> Data = fetchData) async -> NSImage? {
        for url in urls {
            guard !Task.isCancelled else { return nil }
            guard let data = try? await fetch(url), !Task.isCancelled,
                  data.count <= maximumBytes, let image = NSImage(data: data), image.isValid else { continue }
            return image
        }
        return nil
    }

    nonisolated private static func fetchData(_ url: URL) async throws -> Data {
        if url.scheme == "data" {
            guard url.absoluteString.utf8.count <= maximumBytes * 2 else { throw URLError(.dataLengthExceedsMaximum) }
            return try Data(contentsOf: url)
        }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= maximumBytes else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes, !Task.isCancelled else {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return data
    }
}
