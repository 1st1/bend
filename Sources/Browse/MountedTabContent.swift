import AppKit
import SwiftUI
import BrowseCore

// @lat: [[architecture#Mounted tab views]]
struct MountedTabContent: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> MountedTabHost { MountedTabHost() }

    func updateNSView(_ host: MountedTabHost, context: Context) {
        host.update(store: store, environment: environment)
    }
}

@MainActor
final class TabHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // SwiftUI can return its hosting root while it is hidden after a tab
        // switch. Reject it before entering SwiftUI's hit testing so it cannot
        // intercept the visible page's presses, drags, or releases.
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class MountedTabHost: NSView {
    private(set) var mounted: [UUID: NSHostingView<AnyView>] = [:]
    private(set) var selectedID: UUID?
    private var paneIDs: [UUID: [UUID]] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(store: BrowserStore, environment: EnvironmentValues) {
        let tabs = store.session.workspaces.flatMap(\.tabs)
        let ids = Set(tabs.map(\.id))
        let nextID = store.session.selectedTab
        let previousHost = selectedID.flatMap { mounted[$0] }
        let changingTabs = selectedID != nextID
        let movingFocus = changingTabs && (window?.firstResponder as? NSView).map {
            guard let previousHost else { return false }
            return $0.isDescendant(of: previousHost)
        } == true
        if movingFocus {
            InputDiagnostics.transition(.mountedTabFocus, .detached, view: window?.firstResponder as? NSView)
            window?.makeFirstResponder(nil)
        }

        for id in Array(mounted.keys) where !ids.contains(id) {
            for pane in paneIDs.removeValue(forKey: id) ?? [] {
                InputDiagnostics.transition(.mountedTab, .removed, view: mounted[id], paneID: pane, tabID: id)
            }
            mounted.removeValue(forKey: id)?.removeFromSuperview()
        }
        for tab in tabs where tab.id == nextID || mounted[tab.id] != nil {
            let previousPanes = paneIDs[tab.id] ?? []
            paneIDs[tab.id] = tab.pages.map(\.id)
            let root = AnyView(TabCanvasRoot(store: store, tab: tab).environment(\.self, environment))
            let host: NSHostingView<AnyView>
            if let existing = mounted[tab.id] {
                host = existing
                for page in tab.pages {
                    InputDiagnostics.transition(.mountedTabRoot, .replaced, view: host, paneID: page.id, tabID: tab.id)
                }
                host.rootView = root
            } else {
                host = TabHostingView(rootView: root)
                host.sizingOptions = []
                // The window shell supplies the pane margins. A nested host
                // must not add the unified titlebar's safe-area inset again.
                host.safeAreaRegions = []
                host.frame = bounds
                mounted[tab.id] = host
                addSubview(host)
                for page in tab.pages {
                    InputDiagnostics.transition(.mountedTab, .created, view: host, paneID: page.id, tabID: tab.id)
                }
            }
            // Keep inactive trees mounted but hidden. TabHostingView explicitly
            // excludes them from hit testing before SwiftUI can claim an event.
            let hidden = tab.id != nextID
            let visibilityChanged = host.isHidden != hidden
            host.isHidden = hidden
            for page in tab.pages where visibilityChanged || !previousPanes.contains(page.id) {
                InputDiagnostics.transition(.mountedTabVisibility, hidden ? .hidden : .shown,
                                            view: host, paneID: page.id, tabID: tab.id)
            }
            for pane in previousPanes where !tab.pages.contains(where: { $0.id == pane }) {
                InputDiagnostics.transition(.mountedTab, .removed, view: host, paneID: pane, tabID: tab.id)
            }
        }
        selectedID = nextID
        layoutSelectedHost()
        if movingFocus, let web = store.existingController(for: store.selectedTab.focusedPane)?.webView,
           let selectedHost = mounted[nextID], web.isDescendant(of: selectedHost) {
            InputDiagnostics.transition(.mountedTabFocus, .requested, view: web, tabID: nextID)
            window?.makeFirstResponder(web)
        }
    }

    override func layout() {
        super.layout()
        layoutSelectedHost()
    }

    private func layoutSelectedHost() {
        guard let id = selectedID, let host = mounted[id], host.frame != bounds else { return }
        // Hidden tabs keep their last viewport until selected again.
        host.frame = bounds
    }
}
