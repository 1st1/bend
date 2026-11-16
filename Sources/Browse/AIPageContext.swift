import AppKit
import WebKit
import AI

// @lat: [[lat.md/architecture/ai#Selection and screenshots]]
extension PageController {
    func selectedPageText() async throws -> String {
        guard !isPrivate, !isStartPage, ["http", "https"].contains(webView.url?.scheme ?? "") else { return "" }
        let result = try await webView.callAsyncJavaScript(#"""
            const selection = getSelection();
            if (!selection || selection.isCollapsed) return '';
            for (const node of document.querySelectorAll('input, textarea, [contenteditable]:not([contenteditable="false"])')) {
                for (let i = 0; i < selection.rangeCount; i++) {
                    if (selection.getRangeAt(i).intersectsNode(node)) return '';
                }
            }
            const text = selection.toString().trim();
            if (text.length > 24000) throw new Error('Select less text (maximum 24000 characters).');
            return text;
            """#,
            arguments: [:], in: nil, contentWorld: .defaultClient)
        return result as? String ?? ""
    }

    func visiblePageScreenshot() async throws -> Data {
        guard !isPrivate, !isStartPage, let window = webView.window, window.isVisible,
              !window.isMiniaturized, !webView.isHiddenOrHasHiddenAncestor,
              !webView.visibleRect.isEmpty else { throw AIError.configuration("The webpage pane must be visible to share a screenshot.") }
        let config = WKSnapshotConfiguration()
        config.rect = webView.visibleRect
        config.snapshotWidth = NSNumber(value: min(1440, config.rect.width))
        let image = try await webView.takeSnapshot(configuration: config)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
              data.count <= 4_000_000 else { throw AIError.configuration("The screenshot could not be captured within the size limit.") }
        return data
    }
}
