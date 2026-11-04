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
final class MountedTabHost: NSView {
    private(set) var mounted: [UUID: NSHostingView<AnyView>] = [:]
    private(set) var selectedID: UUID?

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
        if movingFocus { window?.makeFirstResponder(nil) }

        for id in Array(mounted.keys) where !ids.contains(id) {
            mounted.removeValue(forKey: id)?.removeFromSuperview()
        }
        for tab in tabs where tab.id == nextID || mounted[tab.id] != nil {
            let root = AnyView(TabCanvasRoot(store: store, tab: tab).environment(\.self, environment))
            let host: NSHostingView<AnyView>
            if let existing = mounted[tab.id] {
                host = existing
                host.rootView = root
            } else {
                host = NSHostingView(rootView: root)
                host.sizingOptions = []
                // The window shell supplies the pane margins. A nested host
                // must not add the unified titlebar's safe-area inset again.
                host.safeAreaRegions = []
                host.frame = bounds
                mounted[tab.id] = host
                addSubview(host)
            }
            // Native hiding also excludes the inactive tree from hit testing,
            // keyboard traversal, accessibility, and WebKit's visible rendering.
            host.isHidden = tab.id != nextID
        }
        selectedID = nextID
        layoutSelectedHost()
        if movingFocus, let web = store.existingController(for: store.selectedTab.focusedPane)?.webView,
           let selectedHost = mounted[nextID], web.isDescendant(of: selectedHost) {
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
