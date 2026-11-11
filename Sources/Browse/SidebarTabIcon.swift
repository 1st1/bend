import AppKit
import SwiftUI
import BrowseCore

struct SidebarTabIcon: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: BrowserTab

    func makeNSView(context: Context) -> SidebarTabIconView { SidebarTabIconView() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarTabIconView, context: Context) -> CGSize? {
        SidebarTabIconView.slotSize
    }

    func updateNSView(_ view: SidebarTabIconView, context: Context) {
        let active = tab.pages.first { $0.id == tab.focusedPane } ?? tab.pages.first
        let other = tab.layout.paneIDs.first { $0 != active?.id }
            .flatMap { id in tab.pages.first { $0.id == id } }
        update(view.frontIcon, page: active)
        update(view.backIcon, page: other)
        view.updateStack(front: active?.id, back: other?.id, count: tab.pages.count,
                         animate: view.tabID == tab.id && !reduceMotion)
        view.tabID = tab.id
    }

    private func update(_ view: NSImageView, page: Page?) {
        let controller = page.flatMap { store.existingController(for: $0.id) }
        if let image = page.flatMap({ store.favicon(for: $0) }) {
            view.image = image
            view.contentTintColor = nil
        } else {
            let address = controller?.address ?? page?.address ?? "browse://start"
            let symbol = address.hasPrefix("browse://")
                ? (address == "browse://history" ? "clock" : "square.grid.2x2") : "globe"
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            view.contentTintColor = .secondaryLabelColor
        }
    }
}

final class SidebarTabIconView: NSView {
    static let slotSize = CGSize(width: 24, height: 28)
    var tabID: UUID?
    let frontIcon = NSImageView()
    let backIcon = NSImageView()
    private let frontShadow = SidebarIconContactShadow()
    private var frontPageID: UUID?
    private var backPageID: UUID?
    var paneCount = 1 {
        didSet {
            let stacked = paneCount > 1
            backIcon.isHidden = !stacked
            frontShadow.isHidden = !stacked
            frontIcon.layer?.backgroundColor = stacked ? NSColor(white: 0.16, alpha: 1).cgColor : nil
            needsLayout = true
        }
    }

    func updateStack(front: UUID?, back: UUID?, count: Int, animate: Bool) {
        let changedFront = frontPageID != front
        let changedBack = backPageID != back
        let shouldFade = animate && window != nil && frontPageID != nil && count > 1
        frontPageID = front
        backPageID = back
        paneCount = count
        for (view, changed) in [(frontIcon as NSView, changedFront), (backIcon, changedBack),
                                (frontShadow, changedBack)] {
            if !animate || count <= 1 { view.layer?.removeAnimation(forKey: "stackFade") }
            guard changed, shouldFade else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = view.alphaValue
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(fade, forKey: "stackFade")
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.slotSize }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        setAccessibilityElement(false)
        for icon in [backIcon, frontIcon] {
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.clipsToBounds = true
            icon.wantsLayer = true
            icon.layer?.cornerRadius = Chrome.faviconCornerRadius
            icon.layer?.masksToBounds = true
            icon.setAccessibilityElement(false)
            addSubview(icon)
        }
        frontShadow.wantsLayer = true
        frontShadow.setAccessibilityElement(false)
        addSubview(frontShadow, positioned: .below, relativeTo: frontIcon)
        frontShadow.isHidden = true
        backIcon.alphaValue = 0.65
        backIcon.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let stacked = paneCount > 1
        frontIcon.frame = NSRect(x: 4, y: stacked ? 8 : 6, width: 16, height: 16)
        backIcon.frame = NSRect(x: 6, y: 4, width: 12, height: 12)
        frontShadow.frame = backIcon.frame
        frontShadow.overlapY = frontIcon.frame.minY - backIcon.frame.minY
    }
}

// Paint the contact shadow onto the rear icon itself. A layer shadow outside
// the front image's small bounds is too faint at this scale.
private final class SidebarIconContactShadow: NSView {
    var overlapY: CGFloat = 4 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [NSColor.black.withAlphaComponent(0).cgColor,
                         NSColor.black.withAlphaComponent(0.22).cgColor] as CFArray,
                locations: [0, 1]) else { return }
        context.saveGState()
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: Chrome.faviconCornerRadius,
                               cornerHeight: Chrome.faviconCornerRadius, transform: nil))
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: 0),
            end: CGPoint(x: bounds.midX, y: max(1, overlapY)), options: [.drawsAfterEndLocation])
        context.restoreGState()
    }
}
