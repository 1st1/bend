import SwiftUI
import WebKit
import BrowseCore

// Use the property-wrapper type explicitly: some Command Line Tools SDKs
// expose a same-named State macro without shipping its macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum Chrome {
    // Match the fixed centerline of the native unified-toolbar traffic lights.
    static let headerCenterY: CGFloat = 26
    static let paneInset: CGFloat = PaneGeometry.gap
    static let paneHeaderHeight = 2 * (headerCenterY - paneInset)
    static let sidebarControlSpacing: CGFloat = 2
    static let sidebarHorizontalInset: CGFloat = 10
    static let accent = Color(red: 0.66, green: 0.81, blue: 0.73)
    static let muted = Color.white.opacity(0.42)
}

struct BrowserView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                sidebar(floating: false).frame(width: store.sidebarWidth)
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(store: store).frame(width: 8)
                            .background(WindowDragArea(excluded: true)).offset(x: 4)
                    }
                    .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
            }
            MountedTabContent(store: store)
            .padding(Chrome.paneInset)
            .background {
                if #unavailable(macOS 26.0) {
                    WindowMaterial(material: .underWindowBackground).allowsHitTesting(false)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.sidebarVisible)
        .overlay(alignment: .topLeading) {
            if !store.sidebarVisible && store.sidebarFloating {
                sidebar(floating: true)
                    .frame(width: store.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(PaneChromeBackground(cornerRadius: 14, appearance: store.windowGlass))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.35), radius: 14, x: 4, y: 4)
                    .padding(.leading, FloatingSidebarTrackingView.inset)
                    .padding(.top, FloatingSidebarTrackingView.inset)
                    .padding(.bottom, FloatingSidebarTrackingView.inset)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.sidebarFloating)
        .overlay { FloatingSidebarTracking(store: store).accessibilityHidden(true) }
        .background(PaneShadowPlane(store: store).allowsHitTesting(false).accessibilityHidden(true))
        .background {
            if #available(macOS 26.0, *) {
                Color.black.opacity(store.windowGlass.darkening).allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $store.favoriteCustomization) { request in
            FavoriteCustomizationView(store: store, request: request)
        }
    }

    private func sidebar(floating: Bool) -> some View {
        // The docked canvas contributes its own gap after the sidebar.
        let trailingInset = Chrome.sidebarHorizontalInset - (floating ? 0 : Chrome.paneInset)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Chrome.sidebarControlSpacing) {
                if floating && !store.isFullScreen { Color.clear.frame(width: 66) }
                Spacer(minLength: 0)
                DownloadsButton(downloads: store.downloads)
                iconButton("sidebar.left", floating ? "Keep sidebar open · ⌘⇧S" : "Toggle sidebar · ⌘⇧S", prominent: true) { store.sidebarVisible.toggle() }
                    .background(WindowDragArea(excluded: true))
            }.padding(.leading, Chrome.sidebarHorizontalInset).padding(.trailing, trailingInset)
                .frame(height: 2 * (Chrome.headerCenterY - (floating ? FloatingSidebarTrackingView.inset : 0)))
                .padding(.top, !floating && store.sidebarWidth < 180 && !store.isFullScreen ? 33 : 0)
                .zIndex(1)

            if !store.favorites.isEmpty {
                SidebarFavorites(store: store)
                    .padding(.leading, Chrome.sidebarHorizontalInset).padding(.trailing, trailingInset)
                    .padding(.top, 6).padding(.bottom, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(store.sidebarTabs) { tab in
                        SidebarTabRow(store: store, tab: tab)
                    }

                }.padding(.leading, Chrome.sidebarHorizontalInset).padding(.trailing, trailingInset).padding(.top, 6)
            }
            .clipped()
            .contentShape(Rectangle())
            SidebarMediaPlayer(coordinator: store.mediaCoordinator, store: store)
            if let error = store.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange).padding(20)
            }
        }
        .overlay(WindowDragArea())
        .background(PaneSidebarTarget(store: store, destination: .workspace(
            store.session.workspaces.first(where: { $0.tabs.contains { $0.id == store.session.selectedTab } })!.id)))
        .background {
            if #unavailable(macOS 26.0) {
                if !floating { WindowMaterial(material: .sidebar).allowsHitTesting(false) }
            }
        }
    }

}

private struct SidebarTabRow: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    @ViewState<Bool> private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let selected = tab.id == store.session.selectedTab
        return HStack(spacing: 8) {
            Button {
                if OptionKeyState.optionAtClick { store.toggleTabPinned(tab.id) }
                else { store.select(tab.id) }
            } label: {
                HStack(spacing: 9) {
                    SidebarTabIcon(store: store, tab: tab).frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    FadingTabTitle(title: tab.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                    if tab.pages.count > 1 && store.sidebarWidth >= 160 { Text("\(tab.pages.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Chrome.muted) }
                }.frame(maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .overlay {
                TabDragHandle(store: store, tabID: tab.id, title: tab.title, reduceMotion: reduceMotion)
                    .accessibilityHidden(true)
            }
            if selected || hovered || tab.isPinned {
                PinCloseButton(pinned: tab.isPinned, tab: true,
                               setPinned: { store.setTabPinned(tab.id, pinned: $0) },
                               close: { store.closeTab(tab.id) })
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 11).frame(height: 34)
        .background {
            Capsule().fill(ChromeButtonStyle.highlightBackground)
                .opacity(hovered && !selected ? 1 : 0)
        }
        .modifier(TabSelectionMaterial(selected: selected))
        .contentShape(Capsule())
        .onHover { hovered = $0 }
        .onDisappear { hovered = false }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
        .background(WindowDragArea(excluded: true))
        .background(PaneSidebarTarget(store: store, destination: .tab(tab.id)))
        .contextMenu {
            Button("New tab") { store.newTab() }
            if let favorite = store.favorite(for: tab) {
                Button("Remove from Favorites") { store.removeFavorite(favorite.id) }
            } else {
                Button(store.favorites.count >= SidebarFavorite.limit ? "Add to Favorites (9 maximum)" : "Add to Favorites") {
                    store.requestFavorite(tab.id)
                }.disabled(!store.canFavorite(tab))
            }
            Button(tab.isPinned ? "Unpin tab" : "Pin tab") { store.toggleTabPinned(tab.id) }
            Button("Close tab") { store.closeTab(tab.id) }.disabled(tab.isPinned)
        }
    }

}

private struct FadingTabTitle: View {
    let title: String
    @ViewState<CGFloat> private var textWidth = 0

    var body: some View {
        GeometryReader { geometry in
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .clipped()
                .mask {
                    if textWidth > geometry.size.width {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: min(24, geometry.size.width))
                        }
                    } else {
                        Rectangle()
                    }
                }
        }
        .frame(height: 18)
    }
}

struct TabCanvasRoot: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab

    var body: some View {
        GeometryReader { geometry in
            PaneCanvas(store: store, tab: tab, viewport: geometry.size)
        }
    }
}

private struct PaneCanvas: View {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab
    let viewport: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }

    var body: some View {
        let zoomed = tab.id == store.session.selectedTab ? store.zoomedPane : nil
        let layout = zoomed.map(PaneLayout.pane) ?? tab.layout
        let geometry = PaneGeometry(layout: layout, viewport: viewport)
        let livePages = Set(store.session.workspaces.flatMap(\.tabs).first { $0.id == tab.id }?.pages.map(\.id) ?? [])
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(geometry.panes) { placement in
                        if livePages.contains(placement.id), let page = tab.pages.first(where: { $0.id == placement.id }) {
                            BrowserPane(store: store, controller: store.controller(for: page), tab: tab, pageID: page.id)
                                .frame(width: placement.frame.width, height: placement.frame.height)
                                .transition(reduceMotion ? .identity : .asymmetric(
                                    insertion: .modifier(active: PaneReveal(progress: 0, axis: placement.insertionAxis),
                                                         identity: PaneReveal(progress: 1, axis: placement.insertionAxis)),
                                    removal: .identity))
                                .position(x: placement.frame.midX, y: placement.frame.midY)
                                .id(page.id)
                        }
                    }
                    ForEach(geometry.dividers) { divider in
                        PaneDivider(placement: divider, paneIDs: tab.pages.map(\.id), tabID: tab.id) { store.resize(divider.id, fraction: $0) }
                            .frame(width: divider.frame.width, height: divider.frame.height)
                            .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(animation, value: tab.pages.count)
                .animation(animation, value: store.paneMoveRevision)
            }
            .scrollIndicators(.hidden)
            .onChange(of: tab.pages.map(\.id)) { previous, current in
                guard current.count > previous.count,
                      let added = current.first(where: { !previous.contains($0) }) else { return }
                InputDiagnostics.transition(.canvasScroll, .requested, paneID: added, tabID: tab.id)
                withAnimation(animation) { proxy.scrollTo(added, anchor: .bottomTrailing) }
            }
        }
    }
}

private struct PaneReveal: AnimatableModifier {
    nonisolated var progress: CGFloat
    let axis: SplitAxis
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask(alignment: .topLeading) {
            GeometryReader { geometry in
                Rectangle().frame(width: geometry.size.width * (axis == .horizontal ? progress : 1),
                                  height: geometry.size.height * (axis == .vertical ? progress : 1))
            }
        }
        .opacity(progress)
    }
}

private struct WindowMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

private struct TabSelectionMaterial: ViewModifier {
    let selected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(selected ? .regular.interactive() : .identity, in: Capsule())
        } else if selected {
            content.background(.regularMaterial, in: Capsule())
        } else {
            content
        }
    }
}

// @lat: [[architecture#Pane materials]]
struct PaneChromeBackground: View {
    var cornerRadius: CGFloat = 0
    var roundsTopCorners = true
    var roundsBottomCorners = true
    var topRimClipping: CGFloat = 0
    var bottomRimClipping: CGFloat = 0
    var appearance: GlassAppearance = .headerDefault

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: roundsTopCorners ? cornerRadius : 0,
            bottomLeadingRadius: roundsBottomCorners ? cornerRadius : 0,
            bottomTrailingRadius: roundsBottomCorners ? cornerRadius : 0,
            topTrailingRadius: roundsTopCorners ? cornerRadius : 0)
        Group {
            if appearance.style == .solid {
                shape.fill(LinearGradient(colors: [appearance.solidColor.headerGradientTop.color,
                                                    appearance.solidColor.headerGradientBottom.color],
                                          startPoint: .top, endPoint: .bottom))
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(appearance.material, in: shape)
                    .padding(.top, -topRimClipping)
                    .padding(.bottom, -bottomRimClipping)
                    .clipped()
            } else {
                shape.fill(.regularMaterial)
            }
        }
        // Darken only the material, preserving foreground control contrast.
        .overlay { if appearance.style != .solid { shape.fill(.black.opacity(appearance.darkening)) } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// A stacked body must not contribute a second rim at the header boundary.
// Move its glass top behind the entire header; the body clip hides that edge.
struct PaneBodyBackground: View {
    var cornerRadius: CGFloat = 0

    var body: some View {
        PaneChromeBackground(cornerRadius: cornerRadius, roundsTopCorners: false,
                             topRimClipping: Chrome.paneHeaderHeight)
    }
}

private struct BrowserPane: View {
    // The 24-point buttons have a 36-point center pitch across group boundaries.
    private static let controlGroupSpacing: CGFloat = 12
    @ObservedObject var store: BrowserStore
    @ObservedObject var controller: PageController
    let tab: BrowserTab
    let pageID: UUID
    @ViewState<CGFloat> private var headerHeight: CGFloat = Chrome.paneHeaderHeight
    @ViewState<Bool> private var titleHovered = false
    @ViewState<Bool> private var paneHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var focused: Bool { tab.focusedPane == pageID }
    private var pinned: Bool { tab.pages.first { $0.id == pageID }?.isPinned == true }
    private var activeHeaderTint: NSColor? {
        guard focused, store.paneHighlight.style == .titleTint else { return nil }
        return store.paneHighlight.titleTintColor.nsColor.withAlphaComponent(store.paneHighlight.titleTintIntensity)
    }
    private var usesSharedHeader: Bool {
        if #available(macOS 26.0, *) { return !controller.isStartPage && controller.error == nil }
        return false
    }
    private var hostsWindowControls: Bool {
        let zoomed = tab.id == store.session.selectedTab ? store.zoomedPane : nil
        return !store.sidebarVisible && pageID == (zoomed ?? tab.layout.paneIDs.first)
    }

    var body: some View {
        ClippedPaneContent(content: decoratedPane, store: store, tabID: tab.id, pageID: pageID,
                           onHover: { paneHovered = $0 })
    }

    private var decoratedPane: some View {
        paneContent
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .fill(.black)
                .opacity(focused || store.paneHighlight.style != .transparency ? 0 : store.inactivePaneDimAmount)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: focused)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        if #available(macOS 26.0, *), !controller.isStartPage, controller.error == nil {
            WebSurface(webView: controller.webView, topContentInset: headerHeight,
                       headerAppearance: store.paneHeaderGlass, topRimClipping: store.paneHeaderTopRimClipping,
                       bottomRimClipping: store.paneHeaderBottomRimClipping,
                       activeHeaderTint: activeHeaderTint)
                .background(PaneChromeBackground(cornerRadius: 12, topRimClipping: store.paneHeaderTopRimClipping))
                .overlay(alignment: .top) {
                    header
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
        } else {
            VStack(spacing: 0) {
                header
                    .background(PaneChromeBackground(cornerRadius: 11, roundsBottomCorners: false,
                                                    topRimClipping: store.paneHeaderTopRimClipping,
                                                    bottomRimClipping: store.paneHeaderBottomRimClipping,
                                                    appearance: store.paneHeaderGlass))
                pageContent
                    .background(PaneBodyBackground())
            }
        }
    }

    private var header: some View {
        HStack(spacing: Self.controlGroupSpacing) {
            if hostsWindowControls {
                if !store.isFullScreen { Color.clear.frame(width: 66) }
                HStack(spacing: Chrome.sidebarControlSpacing) {
                    if tab.id == store.session.selectedTab { DownloadsButton(downloads: store.downloads) }
                    iconButton("sidebar.left", "Show sidebar · ⌘⇧S", prominent: true) { store.sidebarVisible = true }
                        .background(WindowDragArea(excluded: true))
                }
            }
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    ZStack {
                        pageIcon.opacity(titleHovered ? 0 : 1)
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .opacity(titleHovered ? 1 : 0)
                    }.frame(width: 14, height: 14).accessibilityHidden(true)
                    Text(controller.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white.opacity(focused ? 0.9 : 0.55))
                }
                .padding(.horizontal, 7).frame(height: 24)
                .background(ChromeButtonStyle.highlightBackground.opacity(titleHovered ? 1 : 0), in: Capsule())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: titleHovered)
                .overlay(PaneDragHandle(store: store, tabID: tab.id, pageID: pageID, title: controller.title,
                    onHover: { titleHovered = $0 }))
                .layoutPriority(1)
                Spacer(minLength: 0)
                    .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                HStack(spacing: Self.controlGroupSpacing) {
                    HStack(spacing: 0) {
                        iconButton("chevron.left", "Back · ⌘[") {
                            store.focus(pageID); controller.webView.goBack()
                        }.disabled(controller.isStartPage || !controller.canGoBack)
                        iconButton("chevron.right", "Forward · ⌘]") {
                            store.focus(pageID); controller.webView.goForward()
                        }.disabled(controller.isStartPage || !controller.canGoForward)
                    }
                    iconButton(controller.isLoading ? "xmark" : "arrow.clockwise", controller.isLoading ? "Stop loading" : "Reload · ⌘R") {
                        store.focus(pageID)
                        if controller.isLoading { controller.webView.stopLoading() }
                        else if !controller.isStartPage { controller.webView.reload() }
                    }.disabled(controller.isStartPage)
                    HStack(spacing: 0) {
                        if #available(macOS 15.4, *) {
                            PaneExtensionsMenu(manager: store.extensions, pageID: pageID) {
                                store.focus(pageID); store.onSettingsRequested?(.extensions)
                            }
                        }
                        iconButton(store.zoomedPane == pageID ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", "Zoom pane · ⌘⇧↩") { store.toggleZoom(pageID) }
                    }
                }
                .opacity(focused || paneHovered ? 1 : 0)
                .allowsHitTesting(focused || paneHovered)
                .accessibilityHidden(!focused && !paneHovered)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: focused || paneHovered)
                .background {
                    if focused || paneHovered { WindowDragArea(excluded: true) }
                }
                PinCloseButton(pinned: pinned, setPinned: { store.setPanePinned(pageID, pinned: $0) },
                               close: { store.closePane(pageID) })
                    .opacity(pinned || focused || paneHovered ? 1 : 0)
                    .allowsHitTesting(pinned || focused || paneHovered)
                    .accessibilityHidden(!pinned && !focused && !paneHovered)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: pinned || focused || paneHovered)
                    .background {
                        if pinned || focused || paneHovered { WindowDragArea(excluded: true) }
                    }
            }.fixedSize()
        }.padding(.horizontal, 12).frame(height: Chrome.paneHeaderHeight)
        .background(WindowDragArea(onPress: { store.focus(pageID) }))
        .background {
            store.paneHighlight.titleTintColor.color
                .opacity(!usesSharedHeader && focused && store.paneHighlight.style == .titleTint ? store.paneHighlight.titleTintIntensity : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: focused)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            if controller.isLoading {
                GeometryReader { geo in
                    Rectangle().fill(Color(nsColor: .controlAccentColor))
                        .frame(width: geo.size.width * controller.progress, height: 2)
                }.frame(height: 2).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var pageIcon: some View {
        if controller.isStartPage {
            Image(systemName: controller.address == "browse://history" ? "clock" : "square.grid.2x2")
                .font(.system(size: 11)).foregroundStyle(Chrome.muted)
        } else if let favicon = controller.favicon {
            Image(nsImage: favicon).resizable().scaledToFit()
        } else {
            Text(String((URL(string: controller.address)?.host ?? controller.title).prefix(1)).uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(Chrome.muted)
                .frame(width: 14, height: 14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        if let error = controller.error {
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 27)).foregroundStyle(Chrome.accent)
                Text("Couldn’t open this page").font(.system(size: 18, weight: .medium))
                Text(error).font(.system(size: 12)).foregroundStyle(Chrome.muted).multilineTextAlignment(.center)
                Button("Try again") { controller.navigate(controller.address) }.buttonStyle(.bordered)
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if controller.address == "browse://history" {
            HistoryView(store: store, navigate: controller.navigate)
        } else if controller.isStartPage {
            StartPage()
                .onTapGesture { store.focus(pageID) }
        } else {
            WebSurface(webView: controller.webView, activeHeaderTint: activeHeaderTint)
        }
    }
}

// Clip the completed pane, including both glass backgrounds and their compositing
// layers. Applying the pane background outside this host leaves it unmasked.
private struct ClippedPaneContent<Content: View>: NSViewRepresentable {
    let content: Content
    let store: BrowserStore
    let tabID: UUID
    let pageID: UUID
    var onHover: ((Bool) -> Void)?
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> ClippedPaneHost {
        let host = ClippedPaneHost(content: AnyView(content.environment(\.self, environment)))
        host.store = store; host.tabID = tabID; host.pageID = pageID
        host.onPaneHover = onHover
        InputDiagnostics.transition(.paneRoot, .created, view: host, tabID: tabID)
        return host
    }

    static func dismantleNSView(_ host: ClippedPaneHost, coordinator: ()) {
        host.stopHoverTracking()
        InputDiagnostics.transition(.paneRoot, .removed, view: host, tabID: host.tabID)
    }

    func updateNSView(_ host: ClippedPaneHost, context: Context) {
        host.store = store; host.tabID = tabID; host.pageID = pageID
        host.onPaneHover = onHover
        InputDiagnostics.transition(.paneRoot, .replaced, view: host, tabID: tabID)
        host.content.rootView = AnyView(content.environment(\.self, environment))
    }
}

// @lat: [[architecture#Pane navigation controls]]
final class ClippedPaneHost: PaneDropHost {
    let content: NSHostingView<AnyView>
    var onPaneHover: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    private(set) var isPaneHovered = false

    init(content rootView: AnyView) {
        content = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        content.sizingOptions = []
        content.safeAreaRegions = []
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { setPaneHovered(false) }
    override func layout() { super.layout(); refreshHover() }
    override func viewDidHide() { super.viewDidHide(); setPaneHovered(false) }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshHover() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: name, object: window)
            }
        }
        refreshHover()
    }

    @objc private func windowFocusChanged(_ notification: Notification) { refreshHover() }

    private func refreshHover() {
        let hovered = window.map { window in
            window.isKeyWindow && !isHiddenOrHasHiddenAncestor && store?.session.selectedTab == tabID &&
                visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } ?? false
        setPaneHovered(hovered)
    }

    private func setPaneHovered(_ hovered: Bool) {
        guard hovered != isPaneHovered else { return }
        isPaneHovered = hovered
        // Native layout/hiding may occur during a SwiftUI update. Deliver only
        // the latest hover state on the next turn to avoid reentrant updates.
        Task { @MainActor [weak self] in
            guard let self, self.isPaneHovered == hovered else { return }
            self.onPaneHover?(hovered)
        }
    }

    func stopHoverTracking() {
        NotificationCenter.default.removeObserver(self)
        if let hoverTracking { removeTrackingArea(hoverTracking); self.hoverTracking = nil }
        setPaneHovered(false)
        onPaneHover = nil
    }
}

private struct WebSurface: NSViewRepresentable {
    let webView: WKWebView
    var topContentInset: CGFloat = 0
    var headerAppearance: GlassAppearance?
    var topRimClipping: CGFloat = BrowserStore.defaultHeaderTopRimClipping
    var bottomRimClipping: CGFloat = BrowserStore.defaultHeaderBottomRimClipping
    var activeHeaderTint: NSColor?

    func makeNSView(context: Context) -> WebSurfaceHost {
        let host = WebSurfaceHost()
        host.update(webView: webView, topContentInset: topContentInset, headerAppearance: headerAppearance,
                    topRimClipping: topRimClipping, bottomRimClipping: bottomRimClipping, activeHeaderTint: activeHeaderTint)
        return host
    }

    func updateNSView(_ nsView: WebSurfaceHost, context: Context) {
        nsView.update(webView: webView, topContentInset: topContentInset, headerAppearance: headerAppearance,
                      topRimClipping: topRimClipping, bottomRimClipping: bottomRimClipping, activeHeaderTint: activeHeaderTint)
    }
}

// @lat: [[architecture#Application shell]]
private struct StartPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var showsMore = false
    @ViewState private var moreButtonHovered = false

    private static let shortcutGroups: [[(String, String)]] = [
        [
            ("Open location", "⌘L"),
            ("New tab", "⌘T"),
            ("New window", "⌘N"),
            ("Close pane", "⌘W"),
            ("Close tab", "⇧⌘W"),
            ("Reopen closed pane or tab", "⇧⌘T")
        ],
        [
            ("Split right", "⌘D"),
            ("Split below", "⇧⌘D"),
            ("Zoom pane", "⇧⌘↩"),
            ("Toggle sidebar", "⇧⌘S")
        ],
        [
            ("Back", "⌘["),
            ("Forward", "⌘]"),
            ("Reload page", "⌘R"),
            ("Find in page", "⌘F"),
            ("Find next", "⌘G"),
            ("Find previous", "⇧⌘G"),
            ("Zoom in", "⌘+"),
            ("Zoom out", "⌘−"),
            ("Actual size", "⌘0")
        ],
        [
            ("Show history", "⌘Y"),
            ("Settings", "⌘,")
        ]
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    ForEach(0..<(showsMore ? Self.shortcutGroups.count : 2), id: \.self) { group in
                        VStack(spacing: 10) {
                            ForEach(Self.shortcutGroups[group].indices, id: \.self) { index in
                                let shortcut = Self.shortcutGroups[group][index]
                                HStack(alignment: .firstTextBaseline, spacing: 24) {
                                    Text(shortcut.0)
                                    Spacer(minLength: 0)
                                    Text(shortcut.1)
                                        .monospaced()
                                        .fixedSize()
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -8)))
                    }
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                            showsMore.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            // Keep both labels mounted so their width and local
                            // position stay stable while the whole pill moves.
                            ZStack {
                                Text("See more").opacity(showsMore ? 0 : 1)
                                Text("See less").opacity(showsMore ? 1 : 0)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(showsMore ? "See less" : "See more")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .rotationEffect(.degrees(showsMore ? 180 : 0))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(moreButtonHovered ? 0.65 : 0.48))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(moreButtonHovered ? 0.08 : 0.045), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    // Animate the capsule and its contents in one coordinate space.
                    .geometryGroup()
                    .onHover { moreButtonHovered = $0 }
                    .accessibilityValue(showsMore ? "Expanded" : "Collapsed")
                    .frame(maxWidth: .infinity)
                }
                .font(.system(size: 13))
                .foregroundStyle(Chrome.muted)
                .frame(maxWidth: 320)
                .padding(28)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                .contentShape(Rectangle())
            }
        }
    }
}

@MainActor
private func iconButton(_ symbol: String, _ help: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol) }
        .buttonStyle(ChromeButtonStyle(prominent: prominent)).help(help).accessibilityLabel(help)
}
