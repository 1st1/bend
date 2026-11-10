import AppKit
import SwiftUI
import WebKit
import WebKitFindSupport
import BrowseCore

// SwiftUI's shape clip does not reliably clip WebKit's native composited layers.
// Keep the clip on an AppKit ancestor, outside WebKit's own layer management.
// @lat: [[architecture#Find in page]]
final class WebSurfaceHost: NSView, NSSearchFieldDelegate {
    private weak var hostedWebView: WKWebView?
    private(set) var developerToolsPanel: DeveloperToolsPanel?
    private var developerToolsHeight: CGFloat = 260
    private var developerToolsWidth: CGFloat = 360
    private var developerToolsDock: DeveloperToolsPanel.Dock = .bottom
    var isDeveloperToolsVisible: Bool { developerToolsPanel != nil }

    func showDeveloperTools(console: Bool) -> Bool {
        guard let web = hostedWebView as? FocusWebView else { return false }
        if developerToolsPanel == nil {
            let panel = DeveloperToolsPanel()
            panel.dock = developerToolsDock
            panel.onFocus = { [weak web] in web?.onFocus?() }
            panel.onFrontendDisplaced = { [weak web, weak panel] in
                guard let panel, panel.window != nil, let frontend = panel.frontend,
                      frontend.superview !== panel else { return }
                web?.inspector.restoreEmbedding()
            }
            panel.onResize = { [weak self] delta in
                guard let self else { return }
                if developerToolsDock == .bottom {
                    developerToolsHeight = max(100, min(bounds.height - topContentInset - 72,
                        (developerToolsPanel?.frame.height ?? developerToolsHeight) + delta))
                } else {
                    developerToolsWidth = max(160, min(bounds.width - 100,
                        (developerToolsPanel?.frame.width ?? developerToolsWidth) + delta))
                }
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
            developerToolsPanel = panel
            addSubview(panel)
        }
        web.inspector.dockedToRight = developerToolsDock == .right
        guard web.inspector.showConsole(console) else { removeDeveloperTools(); return false }
        needsLayout = true
        layoutSubtreeIfNeeded()
        return true
    }

    func dockDeveloperTools(_ dock: DeveloperToolsPanel.Dock) {
        guard let panel = developerToolsPanel else { return }
        developerToolsDock = dock
        panel.dock = dock
        (hostedWebView as? FocusWebView)?.inspector.dockedToRight = dock == .right
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func installInspectorFrontend(_ frontend: WKWebView) {
        developerToolsPanel?.install(frontend)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func removeDeveloperTools() {
        guard let panel = developerToolsPanel else { return }
        panel.onFrontendDisplaced = nil
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: panel) {
            window?.makeFirstResponder(hostedWebView)
        }
        panel.removeFromSuperview()
        developerToolsPanel = nil
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    let linkPreview = LinkHoverPreview()
    private var linkTrackingArea: NSTrackingArea?
    private var titlePreviewURL = ""

    func showTitlePreview(_ url: String) {
        titlePreviewURL = LinkHoverObserver.displayURL(url)
        showLinkPreview((hostedWebView as? FocusWebView)?.hoveredLink ?? "")
    }

    private var linkPreviewPointer: NSPoint? {
        window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    }

    func showLinkPreview(_ url: String) {
        guard let web = hostedWebView, web.superview === self else { return }
        let pointer = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let content = NSRect(x: web.frame.minX, y: web.frame.minY, width: web.frame.width,
                             height: max(0, web.frame.height - topContentInset - (isFindBarVisible ? 38 : 0)))
        let visible = window?.isVisible == true && !isHiddenOrHasHiddenAncestor
        if content.contains(pointer) { titlePreviewURL = "" }
        linkPreview.url = visible ? (!titlePreviewURL.isEmpty ? titlePreviewURL : (content.contains(pointer) ? url : "")) : ""
        linkPreview.place(in: web.frame, avoiding: linkPreviewPointer)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkTrackingArea { removeTrackingArea(linkTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        linkTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if !linkPreview.isHidden {
            linkPreview.place(in: hostedWebView?.frame ?? bounds, avoiding: convert(event.locationInWindow, from: nil))
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        titlePreviewURL = ""
        (hostedWebView as? FocusWebView)?.hoveredLink = ""
        linkPreview.url = ""
        super.mouseExited(with: event)
    }

    override func viewDidHide() {
        super.viewDidHide()
        titlePreviewURL = ""
        linkPreview.url = ""
    }

    private var topContentInset: CGFloat = 0
    private var headerGlass: NSView?
    private var headerContent: NSView?
    let activeHeaderTintView: NSView = HeaderScrim()
    private var findBarContainer: NSView { headerContent ?? self }
    private(set) var isFindBarVisible = false
    private(set) var foundMatch: Bool?
    private(set) var matchCount: Int?
    private(set) var findBarView: NSView?
    private let searchField = FindSearchField()
    private var statusLabel: NSTextField { searchField.matchCountLabel }
    private var findButtonsView: NSHostingView<FindToolbarButtons>?
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
        if let findBarView { findBarContainer.addSubview(findBarView) }
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
        let bar: NSView
        if headerGlass != nil {
            bar = NSView()
        } else {
            let material = NSVisualEffectView()
            material.material = .headerView
            material.blendingMode = .withinWindow
            material.state = .active
            bar = material
        }
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 38)
        if headerGlass == nil {
            activeHeaderTintView.frame = bar.bounds
            bar.addSubview(activeHeaderTintView)
        }
        searchField.placeholderString = "Find in page"
        searchField.setAccessibilityLabel("Find in page")
        searchField.controlSize = .small
        searchField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSHostingView(rootView: FindToolbarButtons(canNavigate: false,
            previous: { [weak self] in self?.search(backwards: true) },
            next: { [weak self] in self?.search(backwards: false) },
            close: { [weak self] in self?.hideFindBar() }))
        buttons.sizingOptions = []
        buttons.safeAreaRegions = []
        buttons.widthAnchor.constraint(equalToConstant: 72).isActive = true
        buttons.heightAnchor.constraint(equalToConstant: 24).isActive = true
        findButtonsView = buttons
        let stack = NSStackView(views: [searchField, buttons])
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
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
        let canNavigate = !searchField.stringValue.isEmpty
        if findButtonsView?.rootView.canNavigate != canNavigate {
            findButtonsView?.rootView.canNavigate = canNavigate
        }
    }

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
        addSubview(linkPreview)
        activeHeaderTintView.wantsLayer = true
        activeHeaderTintView.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(webView: WKWebView, topContentInset: CGFloat, headerAppearance: GlassAppearance? = nil,
                topRimClipping: CGFloat = BrowserStore.defaultHeaderTopRimClipping,
                bottomRimClipping: CGFloat = BrowserStore.defaultHeaderBottomRimClipping,
                activeHeaderTint: NSColor? = nil) {
        if let layer = activeHeaderTintView.layer, layer.backgroundColor != activeHeaderTint?.cgColor {
            let previous = layer.presentation()?.backgroundColor ?? layer.backgroundColor ?? NSColor.clear.cgColor
            layer.backgroundColor = activeHeaderTint?.cgColor
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = previous
                fade.toValue = activeHeaderTint?.cgColor ?? NSColor.clear.cgColor
                fade.duration = 0.1
                layer.add(fade, forKey: "activeHeaderTint")
            }
        }
        if hostedWebView !== webView {
            titlePreviewURL = ""
            (hostedWebView as? FocusWebView)?.closeInspector()
            if webView.superview !== self { (webView as? FocusWebView)?.closeInspector() }
            linkPreview.url = ""
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
            addSubview(webView, positioned: .below, relativeTo: headerGlass)
            InputDiagnostics.transition(.surfaceAttachment, .attached, view: webView)
        }
        if #available(macOS 26.0, *), let headerAppearance {
            let glass: PaneHeaderGlass
            if let existing = headerGlass as? PaneHeaderGlass { glass = existing }
            else {
                glass = PaneHeaderGlass()
                headerGlass = glass
                headerContent = glass.chromeContent
                glass.chromeContent.addSubview(activeHeaderTintView)
                addSubview(glass)
            }
            glass.apply(headerAppearance, topRimClipping: topRimClipping, bottomRimClipping: bottomRimClipping)
        }
        addSubview(linkPreview, positioned: .above, relativeTo: nil)
        self.topContentInset = max(0, topContentInset)
        // In the stacked layout the page only touches the pane's bottom corners.
        layer?.maskedCorners = topContentInset > 0
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // Page pixels visible below overlaid chrome, in WebKit's coordinates.
    // A drag thumbnail must not recapture the web content hidden by the header
    // and stretch it into the shorter visible body.
    var snapshotContentRect: NSRect {
        guard let webView = hostedWebView else { return .zero }
        var rect = webView.bounds
        if #available(macOS 26.0, *) {
            let inset = min(rect.height, topContentInset + (isFindBarVisible ? (findBarView?.frame.height ?? 0) : 0))
            if webView.isFlipped { rect.origin.y += inset }
            rect.size.height -= inset
        }
        return rect
    }

    override func layout() {
        super.layout()
        guard let webView = hostedWebView, webView.superview === self else { return }
        let barHeight = isFindBarVisible ? (findBarView?.frame.height ?? 0) : 0
        let chromeHeight = topContentInset + barHeight
        let toolsHeight = developerToolsPanel == nil || developerToolsDock != .bottom ? 0
            : min(developerToolsHeight, max(0, bounds.height - chromeHeight - 72))
        let toolsWidth = developerToolsPanel == nil || developerToolsDock != .right ? 0
            : min(developerToolsWidth, max(0, bounds.width - 100))
        let pageWidth = max(0, bounds.width - toolsWidth)
        developerToolsPanel?.frame = developerToolsDock == .bottom
            ? NSRect(x: 0, y: 0, width: bounds.width, height: toolsHeight)
            : NSRect(x: pageWidth, y: 0, width: toolsWidth, height: max(0, bounds.height - chromeHeight))
        headerGlass?.frame = NSRect(x: 0, y: bounds.height - chromeHeight, width: bounds.width, height: chromeHeight)
        headerGlass?.layoutSubtreeIfNeeded()
        if let headerContent { activeHeaderTintView.frame = headerContent.bounds }
        findBarView?.frame.origin = NSPoint(x: 0, y: headerGlass == nil ? bounds.height - chromeHeight : 0)
        findBarView?.frame.size.width = bounds.width
        if #available(macOS 26.0, *) {
            webView.frame = NSRect(x: 0, y: toolsHeight, width: pageWidth, height: max(0, bounds.height - toolsHeight))
            // Reserve the visible viewport for the page while allowing its
            // scrolled content to render behind the overlaid glass header.
            let inset = topContentInset + barHeight
            if webView.obscuredContentInsets.top != inset {
                InputDiagnostics.transition(.surfaceInset, .changed, view: webView, flags: ["obscured": inset > 0])
                webView.obscuredContentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
            }
            updateWebKitHeaderEffect(webView)
        } else {
            webView.frame = NSRect(x: 0, y: toolsHeight, width: pageWidth, height: max(0, bounds.height - barHeight - toolsHeight))
        }
        linkPreview.place(in: webView.frame, avoiding: linkPreviewPointer)
    }

    // @lat: [[architecture#Pane materials]]
    private func updateWebKitHeaderEffect(_ webView: WKWebView) {
        // WebKit's obscured inset creates its own scroll-pocket blur. Moving
        // between windows can turn that effect opaque beneath our glass,
        // producing a second, frosted material. Bend supplies the header
        // effect, so suppress only this redundant native view, not page pixels.
        // There is no public macOS WKWebView API for it. Keep the optional SPI
        // guarded and reapply during layout in case WebKit replaces the view.
        let selector = NSSelectorFromString("_topScrollPocket")
        guard webView.responds(to: selector),
              let pocket = webView.perform(selector)?.takeUnretainedValue() as? NSView else { return }
        pocket.isHidden = headerGlass != nil
    }
}


// Keep the native search-field editing and clear button, with a trailing count
// inside the field. The cell reserves the same space for drawing and editing.
private final class FindSearchFieldCell: NSSearchFieldCell {
    var countWidth: CGFloat = 0

    static func bezelPath(in bounds: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let path = Self.bezelPath(in: cellFrame)
        NSColor.controlBackgroundColor.withAlphaComponent(0.6).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        // Preserve native bezeled-field geometry; customize only the bezel drawing.
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }

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
        drawsBackground = false
        focusRingType = .exterior
        matchCountLabel.font = font
        matchCountLabel.textColor = .secondaryLabelColor
        matchCountLabel.alignment = .right
        matchCountLabel.lineBreakMode = .byTruncatingTail
        addSubview(matchCountLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSColor.black.setFill()
        FindSearchFieldCell.bezelPath(in: bounds).fill()
    }

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

@available(macOS 26.0, *)
private final class PaneHeaderGlass: NSView {
    private let glass = NSGlassEffectView()
    private let solid = SolidHeaderBackground()
    let chromeContent = NSView()
    private let scrim = HeaderScrim()
    private var topRimClipping: CGFloat = BrowserStore.defaultHeaderTopRimClipping
    private var bottomRimClipping: CGFloat = BrowserStore.defaultHeaderBottomRimClipping

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        // Move the top and bottom glass edges beyond this clip while keeping
        // side highlights. Controls retain the visible header's coordinates.
        glass.cornerRadius = 0
        glass.contentView = NSView()
        addSubview(glass)
        addSubview(solid)
        // Keep controls in one stable parent when switching between materials.
        addSubview(chromeContent)
        scrim.wantsLayer = true
        scrim.autoresizingMask = [.width, .height]
        chromeContent.addSubview(scrim)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ appearance: GlassAppearance, topRimClipping: CGFloat, bottomRimClipping: CGFloat) {
        glass.isHidden = appearance.style == .solid
        solid.isHidden = appearance.style != .solid
        solid.color = appearance.solidColor
        scrim.isHidden = appearance.style == .solid
        glass.style = appearance.clear ? .clear : .regular
        glass.tintColor = appearance.tint?.nsColor
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(appearance.darkening).cgColor
        if self.topRimClipping != topRimClipping || self.bottomRimClipping != bottomRimClipping {
            self.topRimClipping = topRimClipping
            self.bottomRimClipping = bottomRimClipping
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let bleed = bottomRimClipping
        glass.frame = NSRect(x: 0, y: -bleed, width: bounds.width, height: bounds.height + bleed + topRimClipping)
        glass.layoutSubtreeIfNeeded()
        solid.frame = bounds
        chromeContent.frame = bounds
        scrim.frame = chromeContent.bounds
    }
}

private final class HeaderScrim: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
