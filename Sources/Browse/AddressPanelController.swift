import AppKit
import Combine
import BrowseCore

private final class AddressEntryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class AddressResultsTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

@available(macOS 26.0, *)
private final class AddressSelectionGlass: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class AddressResultRow: NSTableRowView {
    private let highlight: NSView

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = AddressSelectionGlass()
            glass.style = .clear
            glass.cornerRadius = 8
            highlight = glass
        } else {
            let background = NSView()
            background.wantsLayer = true
            background.layer?.cornerRadius = 8
            background.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            highlight = background
        }
        super.init(frame: frameRect)
        highlight.isHidden = true
        addSubview(highlight, positioned: .below, relativeTo: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isSelected: Bool {
        didSet { highlight.isHidden = !isSelected }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 0, dy: 2)
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

private struct AddressResult {
    let title: String
    let detail: String
    let address: String
    let history: HistorySuggestion?
}

// @lat: [[architecture#Location popup]]
@MainActor
final class AddressPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: BrowserStore
    private weak var parentWindow: NSWindow?
    private let panel = AddressEntryPanel(contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let input = NSTextField(string: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var targetPane: UUID?
    private let resultsTable = AddressResultsTable()
    private let resultsScroll = NSScrollView()
    private var resultsHeight: NSLayoutConstraint!
    private var resultsTop: NSLayoutConstraint!
    private var results: [AddressResult] = []
    private var typedQuery = ""
    private var selectedResult = -1
    private var suppressAutofill = false
    private var showingFrequent = false
    private var historyObservation: AnyCancellable?

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

        input.font = .systemFont(ofSize: 23)
        input.placeholderAttributedString = NSAttributedString(string: "Search or enter address", attributes: [
            .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1), .font: NSFont.systemFont(ofSize: 23)
        ])
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
        let row = NSStackView(views: [input, go])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        go.widthAnchor.constraint(equalToConstant: 26).isActive = true

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemOrange
        errorLabel.isHidden = true
        row.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        background.addSubview(errorLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        resultsTable.addTableColumn(column)
        resultsTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        resultsTable.style = .plain
        resultsTable.headerView = nil
        resultsTable.backgroundColor = .clear
        resultsTable.rowHeight = 50
        resultsTable.intercellSpacing = .zero
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.target = self
        resultsTable.action = #selector(chooseResult)
        resultsTable.setAccessibilityLabel("History and address suggestions")
        resultsScroll.documentView = resultsTable
        resultsScroll.drawsBackground = false
        resultsScroll.hasVerticalScroller = true
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(resultsScroll)
        resultsHeight = resultsScroll.heightAnchor.constraint(equalToConstant: 0)
        resultsTop = resultsScroll.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -24),
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            row.heightAnchor.constraint(equalToConstant: 34),
            errorLabel.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            errorLabel.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 4),
            resultsScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            resultsScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            resultsTop,
            resultsHeight
        ])
        historyObservation = store.historyPublisher.dropFirst().sink { [weak self] history in
            guard let self, self.targetPane != nil else { return }
            self.updateResults(history: history, preserveSelection: true)
        }

    }

    func show(for paneID: UUID) {
        guard let parentWindow,
              let page = store.selectedTab.pages.first(where: { $0.id == paneID }) else { return }
        if let targetPane, targetPane != paneID { store.finishNewTabEntry(for: targetPane) }
        targetPane = paneID
        InputDiagnostics.transition(.addressPanel, .shown, window: panel, paneID: paneID)
        let controller = store.controller(for: page)
        input.stringValue = controller.isStartPage ? "" : controller.address
        errorLabel.isHidden = true
        typedQuery = input.stringValue
        showingFrequent = true
        suppressAutofill = false
        updateResults()
        if panel.parent == nil { parentWindow.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        input.selectText(nil)
    }

    @objc private func submit() {
        InputDiagnostics.transition(.addressSubmit, .requested, window: panel, paneID: targetPane)
        guard let targetPane,
              let page = store.selectedTab.pages.first(where: { $0.id == targetPane }) else {
            dismiss(restoreFocus: true)
            return
        }
        let result = results.indices.contains(selectedResult) ? results[selectedResult] : nil
        let address = result?.address ?? input.stringValue
        guard AddressResolver.resolve(address) != nil else {
            errorLabel.stringValue = "Enter a web address or search phrase."
            errorLabel.isHidden = false
            layoutPanel()
            return
        }
        store.focus(targetPane)
        store.finishNewTabEntry(for: targetPane)
        if let suggestion = result?.history {
            store.recordHistoryChoice(url: suggestion.url, query: showingFrequent ? "" : typedQuery)
        }
        store.controller(for: page).navigate(address)
        dismiss(restoreFocus: true)
    }

    func dismiss(restoreFocus: Bool) {
        guard let targetPane else { return }
        InputDiagnostics.transition(.addressPanel, .hidden, window: panel, paneID: targetPane, flags: ["restoreFocus": restoreFocus])
        store.finishNewTabEntry(for: targetPane)
        self.targetPane = nil
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

    @discardableResult
    func cancelNewTabIfPresented() -> Bool {
        guard let targetPane, store.cancelNewTabEntry(for: targetPane) else { return false }
        dismiss(restoreFocus: true)
        return true
    }

    private func updateResults(history: BrowsingHistory? = nil, allowAutofill: Bool = false, preserveSelection: Bool = false) {
        let selectedAddress = preserveSelection && results.indices.contains(selectedResult) ? results[selectedResult].address : nil
        let query = showingFrequent ? "" : typedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestions = (history ?? store.history).suggestions(for: query)
        results = suggestions.map { AddressResult(title: $0.title, detail: $0.displayURL, address: $0.url, history: $0) }
        if let address = AddressResolver.resolve(query) {
            let isSearch = address.host == "www.google.com" && address.path == "/search" && !query.contains("://")
            results.insert(AddressResult(title: isSearch ? "Search for “\(query)”" : "Visit \(query)",
                detail: isSearch ? "Search with Google" : "Open address", address: query, history: nil), at: 0)
            selectedResult = 0
        } else { selectedResult = -1 }
        if allowAutofill, let suggestion = suggestions.first,
           let completion = suggestion.completion(for: typedQuery),
           let index = results.firstIndex(where: { $0.history?.url == suggestion.url }) {
            let topHit = results.remove(at: index)
            results.insert(topHit, at: 0)
            selectedResult = 0
            input.stringValue = completion
            if let editor = input.currentEditor() as? NSTextView {
                editor.string = completion
                editor.setSelectedRange(NSRange(location: (typedQuery as NSString).length,
                    length: (completion as NSString).length - (typedQuery as NSString).length))
            }
        }
        if let selectedAddress {
            if let index = results.firstIndex(where: { $0.address == selectedAddress }) {
                selectedResult = index
            } else {
                input.stringValue = typedQuery
                input.currentEditor()?.string = typedQuery
            }
        }
        resultsTable.reloadData()
        updateSelection()
        layoutPanel()
    }

    private func layoutPanel() {
        guard let parentWindow else { return }
        let errorHeight: CGFloat = errorLabel.isHidden ? 0 : 20
        resultsTop.constant = 8 + errorHeight
        let rowHeight = min(CGFloat(results.count) * 50, max(50, parentWindow.frame.height - 240))
        resultsHeight.constant = results.isEmpty ? 0 : rowHeight
        resultsScroll.isHidden = results.isEmpty
        let height: CGFloat = (results.isEmpty ? 64 : 64 + rowHeight) + errorHeight
        let width = min(640, parentWindow.frame.width - 48)
        panel.setFrame(NSRect(x: parentWindow.frame.midX - width / 2,
                              y: parentWindow.frame.maxY - 102 - height, width: width, height: height), display: true)
    }

    private func updateSelection() {
        if results.indices.contains(selectedResult) {
            resultsTable.selectRowIndexes(IndexSet(integer: selectedResult), byExtendingSelection: false)
            resultsTable.scrollRowToVisible(selectedResult)
        } else { resultsTable.deselectAll(nil) }
    }

    @objc private func chooseResult() {
        guard results.indices.contains(resultsTable.clickedRow) else { return }
        selectedResult = resultsTable.clickedRow
        submit()
    }

    @objc private func removeHistoryResult(_ sender: NSButton) {
        guard let url = sender.identifier?.rawValue else { return }
        store.removeHistory(url: url)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        AddressResultRow()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let result = results[row]
        let view = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: result.history == nil ? "magnifyingglass" : "clock",
                                             accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: result.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: result.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
            target: self, action: #selector(removeHistoryResult(_:)))
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.identifier = NSUserInterfaceItemIdentifier(result.address)
        remove.toolTip = "Remove from history"
        remove.setAccessibilityLabel("Remove \(result.title) from history")
        remove.isHidden = result.history == nil
        for child in [icon, title, detail, remove] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            remove.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            remove.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 24)
        ])
        view.textField = title
        return view
    }

    func controlTextDidChange(_ notification: Notification) {
        errorLabel.isHidden = true
        showingFrequent = false
        typedQuery = input.stringValue
        let editor = input.currentEditor() as? NSTextView
        let atEnd = editor?.selectedRange() == NSRange(location: (typedQuery as NSString).length, length: 0)
        updateResults(allowAutofill: !suppressAutofill && atEnd && editor?.hasMarkedText() != true)
        suppressAutofill = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !cancelNewTabIfPresented() { dismiss(restoreFocus: true) }
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            selectedResult = min(results.count - 1, max(-1, selectedResult + delta))
            input.stringValue = results.indices.contains(selectedResult) ? results[selectedResult].address : typedQuery
            textView.string = input.stringValue
            textView.setSelectedRange(NSRange(location: (input.stringValue as NSString).length, length: 0))
            updateSelection()
            return true
        }
        if NSStringFromSelector(commandSelector).hasPrefix("delete") { suppressAutofill = true }
        return false
    }
}
