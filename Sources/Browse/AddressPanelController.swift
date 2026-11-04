import AppKit
import BrowseCore

private final class AddressEntryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// @lat: [[architecture#Location popup]]
@MainActor
final class AddressPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let store: BrowserStore
    private weak var parentWindow: NSWindow?
    private let panel = AddressEntryPanel(contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let input = NSTextField(string: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var targetPane: UUID?

    init(store: BrowserStore, parentWindow: NSWindow) {
        self.store = store
        self.parentWindow = parentWindow
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "Open Location"

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        // Mask the native backdrop and window shadow together, not only the backing layer.
        let radius: CGFloat = 18
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        background.maskImage = mask
        panel.contentView = background

        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        // The material mask does not clip subviews.
        shade.layer?.cornerRadius = radius
        shade.layer?.masksToBounds = true
        shade.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(shade)
        NSLayoutConstraint.activate([
            shade.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            shade.topAnchor.constraint(equalTo: background.topAnchor),
            shade.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        input.placeholderString = "Search or enter address"
        input.font = .systemFont(ofSize: 23)
        input.textColor = .labelColor
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.lineBreakMode = .byTruncatingHead
        input.delegate = self
        input.target = self
        input.action = #selector(submit)
        input.cell?.sendsActionOnEndEditing = false
        input.setAccessibilityLabel("Search or enter address")
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let go = NSButton(image: NSImage(systemSymbolName: "return", accessibilityDescription: "Open address")!,
                          target: self, action: #selector(submit))
        go.isBordered = false
        go.contentTintColor = .secondaryLabelColor
        go.toolTip = "Open · Return"
        let row = NSStackView(views: [icon, input, go])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        go.widthAnchor.constraint(equalToConstant: 26).isActive = true

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemOrange
        errorLabel.isHidden = true
        let content = NSStackView(views: [row, errorLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            content.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            row.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    func show(for paneID: UUID) {
        guard let parentWindow,
              let page = store.selectedTab.pages.first(where: { $0.id == paneID }) else { return }
        targetPane = paneID
        let controller = store.controller(for: page)
        input.stringValue = controller.isStartPage ? "" : controller.address
        errorLabel.isHidden = true
        let width = min(640, parentWindow.frame.width - 48)
        panel.setFrame(NSRect(x: parentWindow.frame.midX - width / 2,
                              y: parentWindow.frame.maxY - 190, width: width, height: 88), display: true)
        if panel.parent == nil { parentWindow.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        input.selectText(nil)
    }

    @objc private func submit() {
        guard let targetPane,
              let page = store.selectedTab.pages.first(where: { $0.id == targetPane }) else {
            dismiss(restoreFocus: true)
            return
        }
        guard AddressResolver.resolve(input.stringValue) != nil else {
            errorLabel.stringValue = "Enter a web address or search phrase."
            errorLabel.isHidden = false
            return
        }
        store.focus(targetPane)
        store.controller(for: page).navigate(input.stringValue)
        dismiss(restoreFocus: true)
    }

    private func dismiss(restoreFocus: Bool) {
        guard targetPane != nil else { return }
        targetPane = nil
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreFocus, let parentWindow {
            parentWindow.makeKeyAndOrderFront(nil)
            let page = store.selectedTab.pages.first { $0.id == store.selectedTab.focusedPane }!
            let controller = store.controller(for: page)
            parentWindow.makeFirstResponder(controller.isStartPage ? parentWindow.contentView : controller.webView)
        }
    }

    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }

    func controlTextDidChange(_ notification: Notification) { errorLabel.isHidden = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        dismiss(restoreFocus: true)
        return true
    }
}
