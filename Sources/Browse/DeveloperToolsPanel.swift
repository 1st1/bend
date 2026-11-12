import AppKit
import WebKit

// @lat: [[lat.md/architecture/developer-tools#Developer tools]]
@MainActor
final class DeveloperToolsPanel: NSView {
    enum Dock { case bottom, right }
    var onFocus: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onFrontendDisplaced: (() -> Void)?
    var dock: Dock = .bottom {
        didSet {
            divider.dock = dock
            needsLayout = true
            window?.invalidateCursorRects(for: divider)
        }
    }
    private let divider = DeveloperToolsDivider()
    private(set) var frontend: WKWebView?

    // Inspector chrome must never start a native window-background drag.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onFocus?() }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        divider.onResize = { [weak self] delta in self?.onResize?(delta) }
        addSubview(divider)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(_ webView: WKWebView) {
        if frontend !== webView || webView.superview !== self {
            frontend?.removeFromSuperview()
            frontend = webView
            webView.autoresizingMask = []
            addSubview(webView, positioned: .below, relativeTo: divider)
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        window?.makeFirstResponder(webView)
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard subview === frontend, let onFrontendDisplaced else { return }
        // Wait until WebKit finishes its reparenting before restoring ownership.
        // Closure releases this panel; a queued recovery then becomes a no-op.
        // AppKit can also call this during deallocation; use the already-created
        // weak callback rather than forming a new weak reference to this view.
        Task { @MainActor in onFrontendDisplaced() }
    }

    override func layout() {
        super.layout()
        let leftInset: CGFloat = dock == .right ? 5 : 0
        divider.frame = dock == .bottom
            ? NSRect(x: 0, y: max(0, bounds.height - 5), width: bounds.width, height: 5)
            : NSRect(x: 0, y: 0, width: 5, height: bounds.height)
        let topInset: CGFloat = dock == .bottom ? 5 : 0
        frontend?.frame = NSRect(x: leftInset, y: 0, width: max(0, bounds.width - leftInset), height: max(0, bounds.height - topInset))
    }
}

private final class DeveloperToolsDivider: NSView {
    var onResize: ((CGFloat) -> Void)?
    var dock: DeveloperToolsPanel.Dock = .bottom
    private var previousPoint: NSPoint?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: dock == .bottom ? .resizeUpDown : .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { previousPoint = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let previousPoint else { return }
        self.previousPoint = event.locationInWindow
        onResize?(dock == .bottom ? event.locationInWindow.y - previousPoint.y : previousPoint.x - event.locationInWindow.x)
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        previousPoint = nil
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        (dock == .bottom ? NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 1)
            : NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height)).fill()
    }
}
