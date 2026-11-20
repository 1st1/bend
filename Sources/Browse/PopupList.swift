import AppKit

/// Shared measurements and placement for list popups such as the location popup and tab switcher.
enum PopupLayout {
    static let rowHeight: CGFloat = 42
    /// The location popup's fixed height outside its result rows.
    static let chromeHeight: CGFloat = 80
    /// Inset between the glass edge and the popup's content.
    static let inset: CGFloat = 6
    /// Minimum distance from the window's content edges.
    static let margin: CGFloat = 16

    /// Screen bounds of the window's content and the visible bounds of the pane a popup centers on.
    /// Falls back to the content bounds until the pane is mounted.
    @MainActor
    static func anchor(in window: NSWindow, pageID: UUID?, tabID: UUID) -> (window: NSRect, anchor: NSRect, pane: PaneDropHost?)? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let windowBounds = window.convertToScreen(content.convert(content.bounds, to: nil))
        let pane = pageID.flatMap { paneView(in: content, pageID: $0, tabID: tabID) }
        let anchor = pane.map { window.convertToScreen($0.convert($0.visibleRect, to: nil)) } ?? windowBounds
        return (windowBounds, anchor, pane)
    }

    /// Popups open with their top edge one-fifth down the anchor.
    static func top(of anchor: NSRect) -> CGFloat { (anchor.maxY - anchor.height / 5).rounded() }

    /// Room left for rows below `top`, after the popup's fixed `chrome` height.
    static func rowSpace(below top: CGFloat, anchor: NSRect, windowBounds: NSRect, chrome: CGFloat) -> CGFloat {
        max(0, top - max(anchor.minY, windowBounds.minY) - margin - chrome)
    }

    /// Centers a popup of `height` on the anchor, with a readable width kept inside the window.
    static func frame(top: CGFloat, height: CGFloat, anchor: NSRect, windowBounds: NSRect) -> NSRect {
        let width = min(480, max(280, anchor.width - 2 * margin), windowBounds.width - 2 * margin)
        let x = min(max(anchor.midX - width / 2, windowBounds.minX + margin), windowBounds.maxX - width - margin)
        return NSRect(x: x.rounded(), y: top - height, width: width, height: height)
    }

    @MainActor
    private static func paneView(in view: NSView, pageID: UUID, tabID: UUID) -> PaneDropHost? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let pane = view as? PaneDropHost, pane.pageID == pageID, pane.tabID == tabID, !pane.visibleRect.isEmpty {
            return pane
        }
        return view.subviews.lazy.compactMap { paneView(in: $0, pageID: pageID, tabID: tabID) }.first
    }
}

/// Wraps popup content in the shared Liquid Glass shell used by browser popups.
@MainActor
final class PopupGlassShell: NSView {
    let glass = NSGlassEffectView()

    init(content: NSView) {
        super.init(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = 18
        glass.contentView = content
        // Clip the complete glass compositor, including its outer decoration.
        // A bare glass view at the window edge can leave a rectangular rim.
        wantsLayer = true
        layer?.cornerRadius = glass.cornerRadius
        layer?.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A popup row with an icon, title, and detail line, plus optional remove and shortcut accessories.
final class PopupResultCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let remove = NSButton()
    let shortcut = NSTextField(labelWithString: "")
    var hasFavicon = false
    var titleMatches: [NSRange] = []
    var detailMatches: [NSRange] = []

    /// Fills and lays out the icon, title, and detail. A trailing `accessory`
    /// must already be a subview; the title and detail end before it.
    func configure(image: NSImage?, hasFavicon: Bool, title titleText: String, detail detailText: String,
                   before accessory: NSView? = nil) {
        self.hasFavicon = hasFavicon
        icon.image = image
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = Chrome.faviconCornerRadius
        icon.layer?.masksToBounds = true
        title.stringValue = titleText
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        detail.stringValue = detailText
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingMiddle
        for child in [icon, title, detail] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            accessory.map { title.trailingAnchor.constraint(equalTo: $0.leadingAnchor, constant: -8) }
                ?? title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        ])
        textField = title
    }

    func setSelected(_ selected: Bool) {
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let secondary = selected ? NSColor.alternateSelectedControlTextColor : .secondaryLabelColor
        detail.textColor = secondary
        shortcut.textColor = secondary
        icon.contentTintColor = hasFavicon ? nil : secondary
        remove.contentTintColor = secondary
        highlight(title, ranges: titleMatches, color: title.textColor!, selected: selected)
        highlight(detail, ranges: detailMatches, color: secondary, selected: selected)
    }

    private func highlight(_ field: NSTextField, ranges: [NSRange], color: NSColor, selected: Bool) {
        let font = NSFont.systemFont(ofSize: field === title ? 14 : 11)
        let baseColor = selected && (!titleMatches.isEmpty || !detailMatches.isEmpty) ? color.withAlphaComponent(0.8) : color
        let value = NSMutableAttributedString(string: field.stringValue, attributes: [.font: font, .foregroundColor: baseColor])
        for range in ranges where NSMaxRange(range) <= value.length {
            value.addAttributes([.font: NSFont.systemFont(ofSize: font.pointSize, weight: .bold),
                                 .foregroundColor: selected ? color : NSColor.controlAccentColor], range: range)
        }
        field.attributedStringValue = value
    }
}

/// Draws the rounded selection highlight and keeps its cell's colors in sync with selection.
final class PopupResultRow: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            needsDisplay = true
            for case let cell as PopupResultCell in subviews { cell.setSelected(isSelected) }
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? PopupResultCell)?.setSelected(isSelected)
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 12, yRadius: 12).fill()
    }
}
