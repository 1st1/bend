import AppKit
import WebKit
import WebKitFindSupport

// SwiftUI's shape clip does not reliably clip WebKit's native composited layers.
// Keep the clip on an AppKit ancestor, outside WebKit's own layer management.
// @lat: [[architecture#Find in page]]
final class WebSurfaceHost: NSView, NSSearchFieldDelegate {
    private weak var hostedWebView: WKWebView?
    private var topContentInset: CGFloat = 0
    private(set) var isFindBarVisible = false
    private(set) var foundMatch: Bool?
    private(set) var matchCount: Int?
    private(set) var findBarView: NSView?
    private let searchField = FindSearchField()
    private var statusLabel: NSTextField { searchField.matchCountLabel }
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var searchGeneration = 0
    private var searchQuery: String?
    private var findSupport: BendFindSupport?

    func performFindAction(_ action: NSTextFinder.Action) {
        guard let web = hostedWebView else { return }
        InputDiagnostics.transition(.findAction, .requested, view: web, flags: [
            "show": action == .showFindInterface, "hide": action == .hideFindInterface,
            "next": action == .nextMatch, "previous": action == .previousMatch
        ])
        switch action {
        case .showFindInterface:
            showFindBar()
        case .hideFindInterface:
            hideFindBar()
        case .nextMatch, .previousMatch:
            if searchField.stringValue.isEmpty { showFindBar() }
            else {
                if !isFindBarVisible { showFindBar(refreshSearch: false) }
                search(backwards: action == .previousMatch)
            }
        default: break
        }
    }

    private func showFindBar(refreshSearch: Bool = true) {
        if findBarView == nil { makeFindBar() }
        if let findBarView { addSubview(findBarView) }
        isFindBarVisible = true
        InputDiagnostics.transition(.findBar, .shown, view: hostedWebView)
        needsLayout = true
        layoutSubtreeIfNeeded()
        searchField.selectText(nil)
        if refreshSearch, !searchField.stringValue.isEmpty { search(backwards: false) }
    }

    func hideFindBar(restoreFocus: Bool = true) {
        guard isFindBarVisible else { return }
        let fieldHadFocus = searchField.currentEditor().map { $0 === window?.firstResponder } ?? false
        searchGeneration += 1
        findSupport?.clearSearch()
        updateSearchStatus(nil)
        isFindBarVisible = false
        findBarView?.removeFromSuperview()
        InputDiagnostics.transition(.findBar, .hidden, view: hostedWebView)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if restoreFocus || fieldHadFocus, let web = hostedWebView, !isHiddenOrHasHiddenAncestor {
            window?.makeFirstResponder(web)
        }
    }

    private func makeFindBar() {
        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 38))
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.state = .active
        searchField.placeholderString = "Find in page"
        searchField.setAccessibilityLabel("Find in page")
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previousButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match")!,
                                  target: self, action: #selector(previousMatch))
        nextButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match")!,
                              target: self, action: #selector(nextMatch))
        previousButton.toolTip = "Previous match · ⇧⌘G"
        nextButton.toolTip = "Next match · ⌘G"
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close find bar")!,
                             target: self, action: #selector(closeFindBar))
        close.toolTip = "Close find bar · Escape"
        for button in [previousButton!, nextButton!, close] {
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let stack = NSStackView(views: [searchField, previousButton, nextButton, close])
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        findBarView = bar
        updateSearchStatus(nil)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        (hostedWebView as? FocusWebView)?.onFocus?()
    }

    func controlTextDidChange(_ notification: Notification) { search(backwards: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hideFindBar()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            search(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        return false
    }

    private func search(backwards: Bool) {
        (hostedWebView as? FocusWebView)?.onFocus?()
        InputDiagnostics.transition(.findAction, .started, view: hostedWebView, flags: ["previous": backwards])
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchField.stringValue
        // Moving to another match does not invalidate the displayed total.
        // Refresh it in place when the new count arrives (the page may change).
        if query != searchQuery || query.isEmpty { updateSearchStatus(nil) }
        searchQuery = query
        guard let web = hostedWebView else { return }
        if query.isEmpty { findSupport?.clearSearch(); return }
        if findSupport == nil { findSupport = BendFindSupport(webView: web) }
        let options = WKFindConfiguration()
        options.backwards = backwards
        options.caseSensitive = false
        options.wraps = true
        web.find(query, configuration: options) { [weak self] result in
            guard let self, self.searchGeneration == generation else { return }
            guard result.matchFound else { self.updateSearchStatus(false, count: 0); return }
            self.foundMatch = true
            self.findSupport?.countMatches(query) { [weak self] count in
                MainActor.assumeIsolated {
                    guard let self, self.searchGeneration == generation else { return }
                    self.updateSearchStatus(true, count: count?.intValue)
                }
            }
        }
    }

    private func updateSearchStatus(_ found: Bool?, count: Int? = nil) {
        foundMatch = found
        matchCount = count
        if let count {
            statusLabel.stringValue = count > 10000 ? "10,000+ matches" : "\(count) \(count == 1 ? "match" : "matches")"
        } else { statusLabel.stringValue = found == false ? "Not found" : "" }
        previousButton?.isEnabled = !searchField.stringValue.isEmpty
        nextButton?.isEnabled = !searchField.stringValue.isEmpty
    }

    @objc private func previousMatch() { search(backwards: true) }
    @objc private func nextMatch() { search(backwards: false) }
    @objc private func closeFindBar() { hideFindBar() }

    override func cancelOperation(_ sender: Any?) {
        if isFindBarVisible { hideFindBar() }
        // NSView does not implement this optional responder action. An Escape
        // with no find bar is a no-op, not a call to super.cancelOperation.
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(webView: WKWebView, topContentInset: CGFloat) {
        if hostedWebView !== webView {
            hideFindBar(restoreFocus: false)
            findSupport?.invalidate()
            findSupport = nil
            searchGeneration += 1
            updateSearchStatus(nil)
            if let old = hostedWebView { InputDiagnostics.transition(.surfaceAttachment, .detached, view: old) }
            hostedWebView?.removeFromSuperview()
            hostedWebView = webView
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
            InputDiagnostics.transition(.surfaceAttachment, .attached, view: webView)
        }
        self.topContentInset = max(0, topContentInset)
        // In the stacked layout the page only touches the pane's bottom corners.
        layer?.maskedCorners = topContentInset > 0
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let webView = hostedWebView else { return }
        let barHeight = isFindBarVisible ? (findBarView?.frame.height ?? 0) : 0
        findBarView?.frame.origin = NSPoint(x: 0, y: bounds.height - topContentInset - barHeight)
        findBarView?.frame.size.width = bounds.width
        if #available(macOS 26.0, *) {
            webView.frame = bounds
            // Reserve the visible viewport for the page while allowing its
            // scrolled content to render behind the overlaid glass header.
            let inset = topContentInset + barHeight
            if webView.obscuredContentInsets.top != inset {
                InputDiagnostics.transition(.surfaceInset, .changed, view: webView, flags: ["obscured": inset > 0])
                webView.obscuredContentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
            }
        } else {
            webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
        }
    }
}


// Keep the native search-field bezel and clear button, with a trailing count
// inside the field. The cell reserves the same space for drawing and editing.
private final class FindSearchFieldCell: NSSearchFieldCell {
    var countWidth: CGFloat = 0

    func countRect(forBounds bounds: NSRect) -> NSRect {
        let text = super.searchTextRect(forBounds: bounds)
        let width = min(countWidth, text.width * 0.6)
        return NSRect(x: text.maxX - width, y: text.minY, width: width, height: text.height)
    }

    override func searchTextRect(forBounds bounds: NSRect) -> NSRect {
        var text = super.searchTextRect(forBounds: bounds)
        text.size.width = max(0, countRect(forBounds: bounds).minX - text.minX - 6)
        return text
    }
}

private final class FindSearchField: NSSearchField {
    let matchCountLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let searchCell = FindSearchFieldCell(textCell: "")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        searchCell.countWidth = ceil(("10,000+ matches" as NSString).size(withAttributes: [.font: font]).width) + 2
        cell = searchCell
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        drawsBackground = true
        matchCountLabel.font = font
        matchCountLabel.textColor = .secondaryLabelColor
        matchCountLabel.alignment = .right
        matchCountLabel.lineBreakMode = .byTruncatingTail
        addSubview(matchCountLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let searchCell = cell as? FindSearchFieldCell else { return }
        let rect = searchCell.countRect(forBounds: bounds)
        let height = matchCountLabel.intrinsicContentSize.height
        matchCountLabel.frame = NSRect(x: rect.minX, y: (bounds.height - height) / 2,
                                      width: rect.width, height: height)
        // AppKit's field-editor clip view otherwise uses the full native text
        // area, ignoring the custom searchTextRect when editing begins.
        if let editor = currentEditor(), let clip = editor.superview as? NSClipView {
            clip.frame = searchCell.searchTextRect(forBounds: bounds)
        }
    }
}
