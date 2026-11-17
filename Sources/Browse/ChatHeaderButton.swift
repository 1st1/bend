import AppKit
import SwiftUI
import Combine

struct ChatHeaderButton: NSViewRepresentable {
    let symbol: String
    let label: String
    var visibleTitle: String? = nil
    var controlWidth: CGFloat = 28
    var enabled = true
    var trailingInset: CGFloat = 10
    var onLeft = false
    var panelWidth: CGFloat = BrowserStore.defaultChatWidth
    var chat: TabChat? = nil
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
        anchor.observePresentation(store: chat?.store, tabID: chat?.tabID)
        anchor.placeButton()
    }
    static func dismantleNSView(_ anchor: ChatHeaderButtonAnchor, coordinator: ()) { anchor.button.removeFromSuperview() }
}

final class ChatHeaderNativeButton: NSButton {
    var callback: (() -> Void)?
    var presentationActive = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        presentationActive ? super.hitTest(point) : nil
    }
    private var hovered = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if isEnabled && presentationActive { highlight(true) } }
    override func mouseDragged(with event: NSEvent) {
        highlight(isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)))
    }
    override func mouseUp(with event: NSEvent) {
        let activate = presentationActive && isEnabled && isHighlighted && bounds.contains(convert(event.locationInWindow, from: nil))
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
    var controlWidth: CGFloat = 28
    private weak var observedStore: BrowserStore?
    private var observedTabID: UUID?
    private var presentationObservation: AnyCancellable?
    private var presented = true

    func observePresentation(store: BrowserStore?, tabID: UUID?) {
        guard observedStore !== store || observedTabID != tabID else { return }
        observedStore = store; observedTabID = tabID
        presentationObservation = nil
        guard let store, let tabID else { return }
        presentationObservation = store.$openChats.combineLatest(store.$session.map(\.selectedTab))
            .sink { [weak self] open, selected in
                self?.setPresented(open.contains(tabID) && selected == tabID, animated: selected == tabID)
            }
    }

    func setPresented(_ visible: Bool, animated: Bool) {
        guard presented != visible else { return }
        presented = visible
        button.presentationActive = visible
        button.highlight(false)
        if visible {
            button.layer?.removeAllAnimations()
            button.alphaValue = 1
            placeButton()
            reveal(animated: animated)
            return
        }
        button.layer?.removeAnimation(forKey: "chatReveal")
        let destination = NSPoint(x: button.frame.minX + (onLeft ? -24 : 24), y: button.frame.minY)
        guard animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            button.alphaValue = 0; button.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            button.animator().alphaValue = 0
            button.animator().setFrameOrigin(destination)
        } completionHandler: { [weak self] in
            guard let self, !self.presented else { return }
            self.button.isHidden = true
        }
    }

    private func reveal(animated: Bool) {
        button.wantsLayer = true
        button.alphaValue = 1
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        button.layer?.add(fade, forKey: "chatReveal")
    }

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
        guard presented else { return }
        guard let frameView = window?.contentView?.superview else { button.removeFromSuperview(); return }
        let newlyAttached = button.superview !== frameView
        if newlyAttached { frameView.addSubview(button, positioned: .above, relativeTo: nil) }
        // Pin to the configured chat edge, independent of transition transforms.
        let rightEdge = onLeft ? frameView.bounds.minX + panelWidth : frameView.bounds.maxX
        button.frame = NSRect(x: rightEdge - trailingInset - controlWidth,
                              y: frameView.bounds.maxY - Chrome.headerCenterY - 14,
                              width: controlWidth, height: 28)
        button.isHidden = isHiddenOrHasHiddenAncestor
        if newlyAttached { reveal(animated: true) }
    }
}
