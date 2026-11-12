import AppKit
import WebKit

// @lat: [[lat.md/architecture/link-navigation#Link hover preview]]
@MainActor
final class LinkHoverObserver: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "BendLinkHover")
    static let script = #"""
    (() => {
        let previous = '';
        const send = (url, force = false) => {
            if (!force && url === previous) return;
            previous = url;
            window.webkit.messageHandlers.bendLinkHover.postMessage(url.slice(0, 4096));
        };
        const linkURL = elements => {
            for (const element of elements) {
                if (element instanceof Element && element.matches('a[href], area[href]')) {
                    try { return new URL(element.getAttribute('href'), element.baseURI).href; }
                    catch { return ''; }
                }
            }
            return '';
        };
        const hover = event => send(linkURL(event.composedPath()), event.type === 'pointerover');
        document.addEventListener('pointerover', hover, true);
        document.addEventListener('pointermove', hover, true);
        document.addEventListener('pointerout', event => {
            if (!event.relatedTarget) send('');
        }, true);
        // Clear immediately on scrolling, clicking, or leaving the document.
        // The next pointer movement resolves the new element under the cursor.
        document.addEventListener('scroll', () => send(''), true);
        document.addEventListener('pointerdown', () => send(''), true);
        window.addEventListener('blur', () => send(''));
        window.addEventListener('pagehide', () => send(''));
    })();
    """#

    static func install(in controller: WKUserContentController) {
        // Extension configurations can share their content controller. One
        // stateless handler routes messages using WebKit's originating web view.
        guard !controller.userScripts.contains(where: { $0.source == script }) else { return }
        controller.add(LinkHoverObserver(), contentWorld: world, name: "bendLinkHover")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let web = message.webView as? FocusWebView, let url = message.body as? String else { return }
        web.hoveredLink = Self.displayURL(url)
    }

    static func displayURL(_ url: String) -> String {
        // Keep URLs encoded and remove invisible direction/control characters;
        // page-supplied text must not visually reorder the destination.
        let visible = url.prefix(4096).unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) &&
            ![0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
              0x2066, 0x2067, 0x2068, 0x2069].contains($0.value)
        }
        return String(String.UnicodeScalarView(visible))
    }
}

@MainActor
final class LinkHoverPreview: NSView {
    private let label = NSTextField(labelWithString: "")
    var url: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            isHidden = newValue.isEmpty
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 0.5
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(white: 0.94, alpha: 1)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(false)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func place(in bounds: NSRect, avoiding pointer: NSPoint? = nil) {
        let available = bounds.insetBy(dx: min(8, bounds.width / 2), dy: 0)
        // The cell includes internal text-layout padding that neither the
        // attributed string width nor drawingRect reports. Round up so a
        // fractional fitting width cannot trigger middle truncation.
        let fittingWidth = label.cell?.cellSize.width ?? label.intrinsicContentSize.width
        let width = min(ceil(fittingWidth) + 14, available.width)
        var placement = NSRect(x: available.minX, y: bounds.minY + 8, width: width, height: 22)
        let clearance: CGFloat = 12
        // Always compare against the preferred left position, not the current
        // frame, so a stationary cursor cannot make the preview bounce sides.
        if let pointer, placement.insetBy(dx: -clearance, dy: -clearance).contains(pointer) {
            placement.origin.x = available.maxX - width
            if placement.insetBy(dx: -clearance, dy: -clearance).contains(pointer) {
                // A long URL may span both corners. Truncate into whichever
                // side has more room, keeping a gap around the cursor.
                let leftSpace = max(0, pointer.x - clearance - available.minX)
                let rightSpace = max(0, available.maxX - pointer.x - clearance)
                if rightSpace >= leftSpace {
                    placement.size.width = min(width, rightSpace)
                    placement.origin.x = available.maxX - placement.width
                } else {
                    placement.size.width = min(width, leftSpace)
                    placement.origin.x = available.minX
                }
            }
        }
        frame = placement
        label.frame = NSRect(x: 7, y: 3, width: max(0, placement.width - 14), height: 16)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
