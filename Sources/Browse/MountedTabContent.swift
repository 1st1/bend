import AppKit
import SwiftUI
import BrowseCore

// @lat: [[lat.md/architecture/session#Mounted tab views]]
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
    private var canvases: [UUID: TabCanvasState] = [:]
    private var renderEnvironment: TabCanvasEnvironment?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(store: BrowserStore, environment: EnvironmentValues) {
        let environmentState = TabCanvasEnvironment(environment)
        let environmentChanged = renderEnvironment != environmentState
        renderEnvironment = environmentState
        let chrome = TabCanvasChrome(store: store)
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

        var removed = Set(mounted.keys)
        for workspace in store.session.workspaces {
            for tab in workspace.tabs where tab.id == nextID || mounted[tab.id] != nil {
                removed.remove(tab.id)
                let selected = tab.id == nextID
                let canvas = TabCanvasState(tab: tab, chrome: chrome, selected: selected,
                    zoomedPane: selected ? store.zoomedPane : nil,
                    hasLeftChat: chrome.sidebarSide == .right && !store.isPrivate &&
                        store.openChats.contains(tab.id) && store.chats[tab.id] != nil)
                updateCanvas(canvas, store: store, environment: environment, environmentChanged: environmentChanged)
            }
        }
        for id in removed {
            for page in canvases.removeValue(forKey: id)?.pages ?? [] {
                InputDiagnostics.transition(.mountedTab, .removed, view: mounted[id], paneID: page.id, tabID: id)
            }
            mounted.removeValue(forKey: id)?.removeFromSuperview()
        }
        selectedID = nextID
        layoutSelectedHost()
        if movingFocus, let web = store.existingController(for: store.selectedTab.focusedPane)?.webView,
           let selectedHost = mounted[nextID], web.isDescendant(of: selectedHost) {
            InputDiagnostics.transition(.mountedTabFocus, .requested, view: web, tabID: nextID)
            window?.makeFirstResponder(web)
        }
    }

    private func updateCanvas(_ canvas: TabCanvasState, store: BrowserStore,
                              environment: EnvironmentValues, environmentChanged: Bool) {
        let previous = canvases[canvas.id]
        guard previous != canvas || environmentChanged else { return }
        canvases[canvas.id] = canvas
        let root = AnyView(TabCanvasRoot(store: store, canvas: canvas).environment(\.self, environment))
        let host: NSHostingView<AnyView>
        if let existing = mounted[canvas.id] {
            host = existing
            for page in canvas.pages {
                InputDiagnostics.transition(.mountedTabRoot, .replaced, view: host, paneID: page.id, tabID: canvas.id)
            }
            #if DEBUG
            TabPerformanceCounters.record(\.mountedRootReplacements, store: store)
            #endif
            host.rootView = root
        } else {
            host = TabHostingView(rootView: root)
            host.sizingOptions = []
            // The window shell supplies the pane margins.
            host.safeAreaRegions = []
            host.frame = bounds
            mounted[canvas.id] = host
            addSubview(host)
            for page in canvas.pages {
                InputDiagnostics.transition(.mountedTab, .created, view: host, paneID: page.id, tabID: canvas.id)
            }
        }
        let hidden = !canvas.selected
        let visibilityChanged = host.isHidden != hidden
        if visibilityChanged { host.isHidden = hidden }
        let previousPanes = previous?.pages ?? []
        for page in canvas.pages where visibilityChanged || !previousPanes.contains(where: { $0.id == page.id }) {
            InputDiagnostics.transition(.mountedTabVisibility, hidden ? .hidden : .shown,
                                        view: host, paneID: page.id, tabID: canvas.id)
        }
        for page in previousPanes where !canvas.pages.contains(where: { $0.id == page.id }) {
            InputDiagnostics.transition(.mountedTab, .removed, view: host, paneID: page.id, tabID: canvas.id)
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

// Preserve the SwiftUI appearance and motion settings across the native
// hosting boundary without treating every window update as an environment change.
private struct TabCanvasEnvironment: Equatable {
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let differentiateWithoutColor: Bool
    let locale: Locale
    let layoutDirection: LayoutDirection
    let isEnabled: Bool

    init(_ environment: EnvironmentValues) {
        colorScheme = environment.colorScheme
        contrast = environment.colorSchemeContrast
        reduceMotion = environment.accessibilityReduceMotion
        reduceTransparency = environment.accessibilityReduceTransparency
        differentiateWithoutColor = environment.accessibilityDifferentiateWithoutColor
        locale = environment.locale
        layoutDirection = environment.layoutDirection
        isEnabled = environment.isEnabled
    }
}
