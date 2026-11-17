import WebKit

// @lat: [[lat.md/architecture/link-navigation#Back from a link-created tab]]
/// A real, inert history entry beneath the first document of a link-created tab or pane.
@MainActor final class CloseHistoryPage: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "close" else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let data = Data("<!doctype html><meta name='color-scheme' content='light dark'><title></title>".utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
