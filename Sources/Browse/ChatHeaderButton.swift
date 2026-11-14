import AppKit
import SwiftUI

struct ChatHeaderButton: NSViewRepresentable {
    let symbol: String
    let label: String
    var visibleTitle: String? = nil
    var controlWidth: CGFloat = 28
    var enabled = true
    var trailingInset: CGFloat = 10
    var onLeft = false
    var panelWidth: CGFloat = BrowserStore.defaultChatWidth
    var topOffset: CGFloat = 0
    let action: () -> Void
    func makeNSView(context: Context) -> ChatHeaderButtonAnchor {
        let button = ChatHeaderNativeButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.target = button
        button.action = #selector(ChatHeaderNativeButton.invoke)
        return ChatHeaderButtonAnchor(button: button)
    }
    func updateNSView(_ anchor: ChatHeaderButtonAnchor, context: Context) {
        anchor.onLeft = onLeft
        anchor.panelWidth = panelWidth
        anchor.topOffset = topOffset
        anchor.trailingInset = trailingInset
        anchor.controlWidth = controlWidth
        let button = anchor.button
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        button.title = visibleTitle ?? ""
        button.font = .systemFont(ofSize: 12)
        button.imagePosition = visibleTitle == nil ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = enabled
        button.callback = action
        button.refreshAppearance()
        anchor.placeButton()
    }
    static func dismantleNSView(_ anchor: ChatHeaderButtonAnchor, coordinator: ()) { anchor.button.removeFromSuperview() }
}

final class ChatHeaderNativeButton: NSButton {
    var callback: (() -> Void)?
    private var hovered = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if isEnabled { highlight(true) } }
    override func mouseDragged(with event: NSEvent) {
        highlight(isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)))
    }
    override func mouseUp(with event: NSEvent) {
        let activate = isEnabled && isHighlighted && bounds.contains(convert(event.locationInWindow, from: nil))
        highlight(false)
        if activate { _ = sendAction(action, to: target) }
    }
    @objc func invoke() { callback?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshAppearance() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshAppearance() }
    func refreshAppearance() {
        contentTintColor = !isEnabled ? .tertiaryLabelColor : hovered ? .labelColor : .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = (hovered && isEnabled ? NSColor.labelColor.withAlphaComponent(0.06) : .clear).cgColor
    }
}

// The unified toolbar overlays SwiftUI content in this strip. Mount the actual
// control above it while the SwiftUI anchor owns its lifetime; the window owns its stable position.
final class ChatHeaderButtonAnchor: NSView {
    let button: ChatHeaderNativeButton
    var trailingInset: CGFloat = 10
    var onLeft = false
    var panelWidth: CGFloat = BrowserStore.defaultChatWidth
    var topOffset: CGFloat = 0
    var controlWidth: CGFloat = 28
    init(button: ChatHeaderNativeButton) { self.button = button; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResized), name: NSWindow.didResizeNotification, object: window)
        }
        placeButton()
    }
    @objc private func windowResized(_ notification: Notification) { placeButton() }
    override func layout() { super.layout(); placeButton() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); placeButton() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); placeButton() }
    func placeButton() {
        guard let frameView = window?.contentView?.superview else { button.removeFromSuperview(); return }
        if button.superview !== frameView { frameView.addSubview(button, positioned: .above, relativeTo: nil) }
        // Pin to the configured chat edge, independent of transition transforms.
        let rightEdge = onLeft ? frameView.bounds.minX + panelWidth : frameView.bounds.maxX
        button.frame = NSRect(x: rightEdge - trailingInset - controlWidth,
                              y: frameView.bounds.maxY - Chrome.headerCenterY - 14 - topOffset,
                              width: controlWidth, height: 28)
        button.isHidden = isHiddenOrHasHiddenAncestor
    }
}
