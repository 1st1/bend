import AppKit
import BrowseCore

/// Never becomes key, so Control-Tab, Control release, and Escape keep reaching the browser window.
private final class TabSwitcherWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Chooses rows on mouse-down, regardless of modifiers: Control stays held during a switch,
/// and a Control-click must not become a context-menu gesture.
final class TabSwitcherTable: NSTableView {
    var onChoose: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onChoose?(row) }
    }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
}

// @lat: [[lat.md/architecture/session#Session lifecycle#Recent tab switching#Tab switcher popup]]
@MainActor
final class TabSwitcherPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// A quick Control-Tab tap switches without flashing the popup.
    static let presentationDelay: TimeInterval = 0.12
    private static let maxVisibleRows = 10
    /// Fixed height around the rows: the glass insets.
    private static let chromeHeight = 2 * PopupLayout.inset

    private let store: BrowserStore
    private weak var parentWindow: NSWindow?
    private let panel = TabSwitcherWindow(contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let table = TabSwitcherTable()
    private let scroll = NSScrollView()
    private var tabs: [BrowserTab] = []
    private var pendingPresentation: DispatchWorkItem?

    var isVisible: Bool { panel.isVisible }
    var rowTabIDs: [UUID] { tabs.map(\.id) }
    var highlightedRow: Int { table.selectedRow }
    func owns(_ window: NSWindow) -> Bool { window === panel }

    init(store: BrowserStore, parentWindow: NSWindow) {
        self.store = store
        self.parentWindow = parentWindow
        super.init()
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "Switch Tabs"

        let background = NSView()
        panel.contentView = PopupGlassShell(content: background)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab")))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = PopupLayout.rowHeight
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Recent tabs")
        table.onChoose = { [weak self] row in self?.choose(row) }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        let inset = PopupLayout.inset
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -inset),
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: inset),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -inset)
        ])
    }

    /// Follows the store's cycle: shows after a short hold, tracks the highlight, hides on commit or cancel.
    func update() {
        guard let cycle = store.tabCycle else {
            pendingPresentation?.cancel(); pendingPresentation = nil
            dismiss()
            return
        }
        let byID = Dictionary(store.session.workspaces.flatMap(\.tabs).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let next = cycle.order.compactMap { byID[$0] }
        if next.map(\.id) != tabs.map(\.id) { tabs = next; table.reloadData(); if panel.isVisible { layout() } }
        table.selectRowIndexes(IndexSet(integer: cycle.index), byExtendingSelection: false)
        table.scrollRowToVisible(cycle.index)
        guard !panel.isVisible, pendingPresentation == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPresentation = nil
            if self.store.tabCycle != nil { self.present() }
        }
        pendingPresentation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.presentationDelay, execute: work)
    }

    func present() {
        guard let parentWindow, store.tabCycle != nil else { return }
        pendingPresentation?.cancel(); pendingPresentation = nil
        layout()
        if panel.parent == nil { parentWindow.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        if let row = store.tabCycle?.index { table.scrollRowToVisible(row) }
    }

    func dismiss() {
        guard panel.isVisible || panel.parent != nil else { return }
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func choose(_ row: Int) {
        guard tabs.indices.contains(row) else { return }
        store.highlightTabInCycle(at: row)
        store.endTabCycle()
    }

    /// Matches the location popup: centered on the focused pane, top edge one-fifth down it.
    private func layout() {
        guard let parentWindow, let placement = PopupLayout.anchor(in: parentWindow,
            pageID: store.selectedTab.focusedPane, tabID: store.selectedTab.id) else { return }
        let top = PopupLayout.top(of: placement.anchor)
        let rows = CGFloat(min(tabs.count, Self.maxVisibleRows)) * PopupLayout.rowHeight
        let height = min(rows, PopupLayout.rowSpace(below: top, anchor: placement.anchor,
            windowBounds: placement.window, chrome: Self.chromeHeight)) + Self.chromeHeight
        panel.setFrame(PopupLayout.frame(top: top, height: height, anchor: placement.anchor,
            windowBounds: placement.window), display: true)
        panel.invalidateShadow()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PopupResultRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tab = tabs[row]
        let page = tab.pages.first { $0.id == tab.focusedPane } ?? tab.pages[0]
        let controller = store.existingController(for: page.id)
        let view = PopupResultCell()
        let favicon = store.favicon(for: page)
        let address = controller?.isStartPage == true ? "Start Page" : (controller?.address ?? page.address)
        view.configure(image: favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil),
            hasFavicon: favicon != nil, title: tab.title,
            detail: tab.pages.count > 1 ? "\(address) · \(tab.pages.count) panes" : address)
        view.setSelected(row == store.tabCycle?.index)
        return view
    }
}
