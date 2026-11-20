import AppKit

/// Shared measurements for list popups such as the location popup and tab switcher.
enum PopupLayout {
    static let rowHeight: CGFloat = 42
    /// The location popup's fixed height outside its result rows.
    static let chromeHeight: CGFloat = 80
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
