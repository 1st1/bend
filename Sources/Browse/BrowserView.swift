import SwiftUI
import WebKit
import BrowseCore

// Use the property-wrapper type explicitly: some Command Line Tools SDKs
// expose a same-named State macro without shipping its macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

private enum Chrome {
    static let accent = Color(red: 0.66, green: 0.81, blue: 0.73)
    static let muted = Color.white.opacity(0.42)
}

struct BrowserView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                sidebar.frame(width: store.sidebarWidth)
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(store: store).frame(width: 8).offset(x: 4)
                    }
                    .zIndex(1)
            }
            MountedTabContent(store: store)
            .padding(6)
            .background {
                if #unavailable(macOS 26.0) {
                    WindowMaterial(material: .underWindowBackground).allowsHitTesting(false)
                }
            }
        }
        .background(PaneShadowPlane(store: store).allowsHitTesting(false).accessibilityHidden(true))
        .background {
            if #available(macOS 26.0, *) {
                Color.black.opacity(store.windowGlass.darkening).allowsHitTesting(false)
            }
        }
        .foregroundStyle(Color.white.opacity(0.88))
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Spacer()
                iconButton("plus", "New tab · ⌘T", prominent: true) { store.newTab() }
                iconButton("sidebar.left", "Toggle sidebar · ⌘⇧S", prominent: true) { store.sidebarVisible.toggle() }
            }.padding(.horizontal, 15).frame(height: 47)
                .padding(.top, store.sidebarWidth < 180 ? 33 : 0)
                .zIndex(1)

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(store.session.workspaces.flatMap(\.tabs)) { tab in
                        SidebarTabRow(store: store, tab: tab)
                    }

                }.padding(.horizontal, 10).padding(.top, 6)
            }
            .clipped()
            .contentShape(Rectangle())
            if let error = store.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange).padding(20)
            }
        }
        .background(PaneSidebarTarget(store: store, destination: .workspace(
            store.session.workspaces.first(where: { $0.tabs.contains { $0.id == store.session.selectedTab } })!.id)))
        .background {
            if #unavailable(macOS 26.0) {
                WindowMaterial(material: .sidebar).allowsHitTesting(false)
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
            Button { store.select(tab.id) } label: {
                HStack(spacing: 9) {
                    Image(systemName: tab.pages.count > 1 ? "rectangle.split.2x1" : "globe")
                        .font(.system(size: 13)).foregroundStyle(selected ? Chrome.accent : .white.opacity(0.5))
                    FadingTabTitle(title: tab.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                    if tab.pages.count > 1 && store.sidebarWidth >= 160 { Text("\(tab.pages.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Chrome.muted) }
                }.frame(maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .overlay {
                TabDragHandle(store: store, tabID: tab.id, title: tab.title, reduceMotion: reduceMotion)
                    .accessibilityHidden(true)
            }
            Button { store.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
                    .frame(width: 16, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Chrome.muted).help("Close tab · ⌘⇧W")
            .opacity(selected || hovered ? 1 : 0)
            .allowsHitTesting(selected || hovered)
            .accessibilityHidden(!selected && !hovered)
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
        .background(PaneSidebarTarget(store: store, destination: .tab(tab.id)))
        .contextMenu {
            Button("New tab") { store.newTab() }
            Button("Close tab") { store.closeTab(tab.id) }
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
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(geometry.panes) { placement in
                        if let page = tab.pages.first(where: { $0.id == placement.id }) {
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
private struct PaneChromeBackground: View {
    var cornerRadius: CGFloat = 0
    var roundsBottomCorners = true
    var appearance: GlassAppearance = .headerDefault

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: roundsBottomCorners ? cornerRadius : 0,
            bottomTrailingRadius: roundsBottomCorners ? cornerRadius : 0,
            topTrailingRadius: cornerRadius)
        Group {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(appearance.material, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        // Darken only the material, preserving foreground control contrast.
        .overlay { shape.fill(.black.opacity(appearance.darkening)) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PaneDivider: View {
    let placement: DividerPlacement
    let paneIDs: [UUID]
    let tabID: UUID
    let onResize: (Double) -> Void
    @ViewState<CGFloat?> private var dragStart: CGFloat?

    var body: some View {
        let horizontal = placement.axis == .horizontal
        Rectangle().fill(Color.clear).contentShape(Rectangle())
            .onHover { hovering in
                if hovering { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            // The divider moves as it resizes the panes. Measuring translation
            // in its local coordinates feeds that movement back into the drag.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                if dragStart == nil {
                    for pane in paneIDs { InputDiagnostics.transition(.dividerResize, .started, paneID: pane, tabID: tabID) }
                    dragStart = placement.firstLength
                }
                let delta = horizontal ? value.translation.width : value.translation.height
                onResize(placement.fraction(forLength: (dragStart ?? placement.firstLength) + delta))
            }.onEnded { _ in
                for pane in paneIDs { InputDiagnostics.transition(.dividerResize, .finished, paneID: pane, tabID: tabID) }
                dragStart = nil
            })
    }
}

private struct BrowserPane: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var controller: PageController
    let tab: BrowserTab
    let pageID: UUID
    @ViewState<CGFloat> private var headerHeight: CGFloat = 36
    @ViewState<Bool> private var titleHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    private var focused: Bool { tab.focusedPane == pageID }
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
        ClippedPaneContent(content: decoratedPane, store: store, tabID: tab.id, pageID: pageID)
            // Reserve the ring inside the pane's layout slot so it remains
            // visible at canvas edges and never overlaps a neighboring pane.
            .padding(store.paneHighlight.style == .outline ? store.paneHighlight.outlineWidth + 1 / max(1, displayScale) : 0)
            .overlay {
                PaneHighlightOverlay(appearance: store.paneHighlight, focused: focused)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private var decoratedPane: some View {
        paneContent
        .padding(1)
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
                       headerAppearance: store.paneHeaderGlass, activeHeaderTint: activeHeaderTint)
                .background(PaneChromeBackground(cornerRadius: 12))
                .overlay(alignment: .top) {
                    header
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
        } else {
            VStack(spacing: 0) {
                header
                    .background(PaneChromeBackground(cornerRadius: 11, roundsBottomCorners: false,
                                                    appearance: store.paneHeaderGlass))
                pageContent
                    .background(PaneChromeBackground())
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            if hostsWindowControls {
                Color.clear.frame(width: 66)
                iconButton("sidebar.left", "Show sidebar · ⌘⇧S") { store.sidebarVisible = true }
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
                        .foregroundStyle(.white.opacity(focused ? 0.9 : 0.55))
                }
                .padding(.horizontal, 7).frame(height: 24)
                .background(ChromeButtonStyle.highlightBackground.opacity(titleHovered ? 1 : 0), in: Capsule())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: titleHovered)
                .overlay(PaneDragHandle(store: store, tabID: tab.id, pageID: pageID, title: controller.title,
                    onHover: { titleHovered = $0 }))
                Spacer(minLength: 0)
                    .frame(maxHeight: .infinity)
                    .overlay(PaneDragHandle(store: store, tabID: tab.id, pageID: pageID, title: controller.title))
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 0) {
                if #available(macOS 15.4, *) {
                    PaneExtensionsMenu(manager: store.extensions, pageID: pageID) {
                        store.focus(pageID); store.onSettingsRequested?()
                    }
                }
                iconButton(controller.isLoading ? "xmark" : "arrow.clockwise", controller.isLoading ? "Stop loading" : "Reload · ⌘R") {
                    store.focus(pageID)
                    if controller.isLoading { controller.webView.stopLoading() }
                    else if !controller.isStartPage { controller.webView.reload() }
                }.disabled(controller.isStartPage)
                iconButton("rectangle.split.2x1", "Split this pane right") { store.focus(pageID); store.split(.horizontal) }
                iconButton(store.zoomedPane == pageID ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", "Zoom pane · ⌘⇧↩") { store.toggleZoom(pageID) }
                iconButton("xmark", "Close pane · ⌘W") { store.closePane(pageID) }
            }
        }.padding(.horizontal, 12).frame(height: 36)
        .background {
            store.paneHighlight.titleTintColor.color
                .opacity(!usesSharedHeader && focused && store.paneHighlight.style == .titleTint ? store.paneHighlight.titleTintIntensity : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: focused)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                if controller.isLoading {
                    GeometryReader { geo in Rectangle().fill(Chrome.accent).frame(width: geo.size.width * controller.progress, height: 2) }
                }
            }.frame(height: 2)
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
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> ClippedPaneHost {
        let host = ClippedPaneHost(content: AnyView(content.environment(\.self, environment)))
        host.store = store; host.tabID = tabID; host.pageID = pageID
        InputDiagnostics.transition(.paneRoot, .created, view: host, tabID: tabID)
        return host
    }

    static func dismantleNSView(_ host: ClippedPaneHost, coordinator: ()) {
        InputDiagnostics.transition(.paneRoot, .removed, view: host, tabID: host.tabID)
    }

    func updateNSView(_ host: ClippedPaneHost, context: Context) {
        host.store = store; host.tabID = tabID; host.pageID = pageID
        InputDiagnostics.transition(.paneRoot, .replaced, view: host, tabID: tabID)
        host.content.rootView = AnyView(content.environment(\.self, environment))
    }
}

final class ClippedPaneHost: PaneDropHost {
    let content: NSHostingView<AnyView>

    init(content rootView: AnyView) {
        content = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // Keep glass specular highlights and the page's edge antialiasing
        // behind an opaque neutral rim, on the same curve as the native clip.
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        content.sizingOptions = []
        content.safeAreaRegions = []
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct WebSurface: NSViewRepresentable {
    let webView: WKWebView
    var topContentInset: CGFloat = 0
    var headerAppearance: GlassAppearance?
    var activeHeaderTint: NSColor?

    func makeNSView(context: Context) -> WebSurfaceHost {
        let host = WebSurfaceHost()
        host.update(webView: webView, topContentInset: topContentInset, headerAppearance: headerAppearance, activeHeaderTint: activeHeaderTint)
        return host
    }

    func updateNSView(_ nsView: WebSurfaceHost, context: Context) {
        nsView.update(webView: webView, topContentInset: topContentInset, headerAppearance: headerAppearance, activeHeaderTint: activeHeaderTint)
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
