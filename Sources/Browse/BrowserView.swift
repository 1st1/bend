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
    @ViewState<String> private var workspaceName = ""
    @ViewState<Bool> private var addingWorkspace = false

    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible { sidebar.frame(width: 236) }
            GeometryReader { geometry in
                PaneCanvas(store: store, tab: store.selectedTab, viewport: geometry.size)
                    .id(store.selectedTab.id)
            }
            .padding(8)
            .background {
                if #unavailable(macOS 26.0) {
                    WindowMaterial(material: .underWindowBackground).allowsHitTesting(false)
                }
            }
        }
        .foregroundStyle(Color.white.opacity(0.88))
        .preferredColorScheme(.dark)
        .alert("New workspace", isPresented: $addingWorkspace) {
            TextField("Workspace name", text: $workspaceName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { store.newWorkspace(name: workspaceName); workspaceName = "" }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Spacer()
                iconButton("plus", "New workspace") { addingWorkspace = true }
                iconButton("sidebar.left", "Toggle sidebar · ⌘⇧S") { store.sidebarVisible.toggle() }
            }.padding(.horizontal, 15).frame(height: 47)

            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    ForEach(store.session.workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(workspace.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Chrome.muted)
                                Spacer()
                                Button { store.newTab(in: workspace.id) } label: { Image(systemName: "plus").font(.system(size: 10)) }
                                    .buttonStyle(.plain).foregroundStyle(Chrome.muted).help("New tab in \(workspace.name)")
                            }.padding(.horizontal, 12)
                            ForEach(workspace.tabs) { tab in
                                tabRow(tab)
                            }
                        }
                    }
                    Button { store.newTab() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus"); Text("New tab"); Spacer(); Text("⌘T").font(.system(size: 10))
                        }.font(.system(size: 12)).foregroundStyle(Chrome.muted).padding(.horizontal, 12)
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 10).padding(.top, 14)
            }
            if let error = store.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange).padding(20)
            }
        }.background {
            if #unavailable(macOS 26.0) {
                WindowMaterial(material: .sidebar).allowsHitTesting(false)
            }
        }
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        let selected = tab.id == store.session.selectedTab
        return HStack(spacing: 8) {
            Button { store.select(tab.id) } label: {
                HStack(spacing: 9) {
                    Image(systemName: tab.pages.count > 1 ? "rectangle.split.2x1" : "globe")
                        .font(.system(size: 13)).foregroundStyle(selected ? Chrome.accent : .white.opacity(0.5))
                    Text(tab.title).font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                    if tab.pages.count > 1 { Text("\(tab.pages.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Chrome.muted) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if selected {
                Button { store.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(Chrome.muted).help("Close tab · ⌘⇧W")
            }
        }
        .padding(.horizontal, 11).frame(height: 34)
        .modifier(TabSelectionMaterial(selected: selected))
        .contextMenu {
            Button("New tab") { store.newTab() }
            Button("Close tab") { store.closeTab(tab.id) }
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
        let layout = store.zoomedPane.map(PaneLayout.pane) ?? tab.layout
        let geometry = PaneGeometry(layout: layout, viewport: viewport)
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(geometry.panes) { placement in
                        if let page = tab.pages.first(where: { $0.id == placement.id }) {
                            BrowserPane(store: store, controller: store.controller(for: page), pageID: page.id)
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
                        PaneDivider(placement: divider) { store.resize(divider.id, fraction: $0) }
                            .frame(width: divider.frame.width, height: divider.frame.height)
                            .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(animation, value: tab.pages.count)
            }
            .scrollIndicators(.hidden)
            .onChange(of: tab.pages.map(\.id)) { previous, current in
                guard current.count > previous.count,
                      let added = current.first(where: { !previous.contains($0) }) else { return }
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
private struct PaneMaterial: ViewModifier {
    func body(content: Content) -> some View {
        content.background(PaneChromeBackground(cornerRadius: 12))
    }
}

private struct PaneChromeBackground: View {
    var cornerRadius: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        Group {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        // Darken only the material, preserving foreground control contrast.
        .overlay { shape.fill(.black.opacity(0.5)) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PaneDivider: View {
    let placement: DividerPlacement
    let onResize: (Double) -> Void
    @ViewState<CGFloat?> private var dragStart: CGFloat?

    var body: some View {
        let horizontal = placement.axis == .horizontal
        Rectangle().fill(Color.clear).contentShape(Rectangle())
            .overlay(Capsule().fill(.white.opacity(0.12))
                .frame(width: horizontal ? 2 : 30, height: horizontal ? 30 : 2))
            .onHover { hovering in
                if hovering { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragStart == nil { dragStart = placement.firstLength }
                let delta = horizontal ? value.translation.width : value.translation.height
                onResize(placement.fraction(forLength: (dragStart ?? placement.firstLength) + delta))
            }.onEnded { _ in dragStart = nil })
    }
}

private struct BrowserPane: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var controller: PageController
    let pageID: UUID
    @ViewState<CGFloat> private var headerHeight: CGFloat = 36
    private var focused: Bool { store.selectedTab.focusedPane == pageID }
    private var hostsWindowControls: Bool {
        !store.sidebarVisible && pageID == (store.zoomedPane ?? store.selectedTab.layout.paneIDs.first)
    }

    var body: some View {
        paneContent
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .padding(1)
        .modifier(PaneMaterial())
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .fill(.black)
                .opacity(focused ? 0 : 0.08)
                .animation(.easeInOut(duration: 0.1), value: focused)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        if #available(macOS 26.0, *), !controller.isStartPage, controller.error == nil {
            WebSurface(webView: controller.webView, topContentInset: headerHeight)
                .overlay(alignment: .top) {
                    header
                        .background(PaneChromeBackground())
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
        } else {
            VStack(spacing: 0) {
                header
                pageContent
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if hostsWindowControls {
                    Color.clear.frame(width: 66)
                    iconButton("sidebar.left", "Show sidebar · ⌘⇧S") { store.sidebarVisible = true }
                }
                Circle().fill(.white.opacity(focused ? 0.8 : 0.2)).frame(width: 5, height: 5)
                pageIcon.frame(width: 14, height: 14).accessibilityHidden(true)
                Text(controller.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(focused ? 0.9 : 0.55))
                Spacer(minLength: 0)
                iconButton(controller.isLoading ? "xmark" : "arrow.clockwise", controller.isLoading ? "Stop loading" : "Reload · ⌘R") {
                    store.focus(pageID)
                    if controller.isLoading { controller.webView.stopLoading() }
                    else if !controller.isStartPage { controller.webView.reload() }
                }.disabled(controller.isStartPage)
                iconButton("rectangle.split.2x1", "Split this pane right") { store.focus(pageID); store.split(.horizontal) }
                iconButton(store.zoomedPane == pageID ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", "Zoom pane · ⌘⇧↩") { store.toggleZoom(pageID) }
                iconButton("xmark", "Close pane · ⌘W") { store.closePane(pageID) }
            }.padding(.horizontal, 12).frame(height: 34)

            ZStack(alignment: .topLeading) {
                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
                if controller.isLoading {
                    GeometryReader { geo in Rectangle().fill(Chrome.accent).frame(width: geo.size.width * controller.progress, height: 2) }
                }
            }.frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focus(pageID) }
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
            StartPage(isGuide: controller.address == "browse://guide", navigate: controller.navigate,
                      split: { store.focus(pageID); store.split(.horizontal) }, focusAddress: { store.requestAddress(for: pageID) })
                .onTapGesture { store.focus(pageID) }
        } else {
            WebSurface(webView: controller.webView)
        }
    }
}

private struct WebSurface: NSViewRepresentable {
    let webView: WKWebView
    var topContentInset: CGFloat = 0

    func makeNSView(context: Context) -> WebSurfaceHost {
        let host = WebSurfaceHost()
        host.update(webView: webView, topContentInset: topContentInset)
        return host
    }

    func updateNSView(_ nsView: WebSurfaceHost, context: Context) {
        nsView.update(webView: webView, topContentInset: topContentInset)
    }
}

// SwiftUI's shape clip does not reliably clip WebKit's native composited layers.
// Keep the clip on an AppKit ancestor, outside WebKit's own layer management.
private final class WebSurfaceHost: NSView {
    private weak var hostedWebView: WKWebView?

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
            hostedWebView?.removeFromSuperview()
            hostedWebView = webView
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
        // In the stacked layout the page only touches the pane's bottom corners.
        layer?.maskedCorners = topContentInset > 0
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        if #available(macOS 26.0, *) {
            // Reserve the visible viewport for the page while allowing its
            // scrolled content to render behind the overlaid glass header.
            let inset = max(0, topContentInset)
            if webView.obscuredContentInsets.top != inset {
                webView.obscuredContentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
            }
        }
    }
}

private struct StartPage: View {
    let isGuide: Bool
    let navigate: (String) -> Void
    let split: () -> Void
    let focusAddress: () -> Void

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: isGuide ? "rectangle.split.2x1" : "circle.hexagongrid")
                        Text(isGuide ? "MAKE SPACE" : "A QUIETER INTERNET").tracking(2)
                    }.font(.system(size: 9, weight: .medium)).foregroundStyle(Chrome.accent)
                    .padding(.bottom, 27)

                    Text(isGuide ? "Side by side.\nIn your flow." : "Room for\nyour curiosity.")
                        .font(.system(size: geo.size.width < 420 ? 33 : 43, weight: .medium, design: .serif))
                        .tracking(-1.5).lineSpacing(-2).fixedSize(horizontal: false, vertical: true)
                    Text(isGuide ? "One tab. A whole workspace. Keep the pages you need together, right where you need them." : "Your browser, arranged around you.\nOpen a page and make yourself at home.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.46)).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 17).padding(.bottom, 30)

                    if isGuide {
                        shortcut("rectangle.split.2x1", "Split right", "⌘D")
                        shortcut("rectangle.split.1x2", "Split below", "⌘⇧D")
                        shortcut("arrow.up.left.and.arrow.down.right", "Focus one pane", "⌘⇧↩")
                        shortcut("sidebar.left", "Toggle sidebar", "⌘⇧S")
                        Button(action: split) {
                            HStack { Text("Make another split"); Spacer(); Image(systemName: "arrow.right") }
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Chrome.accent)
                                .padding(14).background(Chrome.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).padding(.top, 22)
                    } else {
                        Button(action: focusAddress) {
                            HStack {
                                Image(systemName: "magnifyingglass"); Text("Where to?"); Spacer(); Text("⌘L").font(.system(size: 10))
                            }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                                .padding(14).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)))
                        }.buttonStyle(.plain).padding(.bottom, 26)
                        Text("A FEW GOOD PLACES").font(.system(size: 8, weight: .semibold)).tracking(1.7).foregroundStyle(Chrome.muted).padding(.bottom, 10)
                        destination("swift", "Swift", "Build something native", "https://www.swift.org")
                        destination("book.closed", "Wikipedia", "Follow a rabbit hole", "https://en.wikipedia.org")
                        destination("chevron.left.forwardslash.chevron.right", "Hacker News", "See what’s happening", "https://news.ycombinator.com")
                    }
                    HStack(spacing: 6) {
                        Circle().fill(Chrome.accent.opacity(0.65)).frame(width: 4, height: 4)
                        Text(isGuide ? "Drag any divider to find your balance." : "Native macOS. Powered by WebKit.")
                    }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.27)).padding(.top, 35)
                }
                .padding(.horizontal, geo.size.width < 420 ? 27 : 44)
                .padding(.vertical, max(35, min(85, geo.size.height * 0.1)))
                .frame(maxWidth: 590, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
    }

    private func shortcut(_ symbol: String, _ name: String, _ key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 17).foregroundStyle(Chrome.muted)
            Text(name); Spacer()
            Text(key).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 7).padding(.vertical, 4).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
        }.font(.system(size: 12)).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.055)).frame(height: 1) }
    }

    private func destination(_ symbol: String, _ title: String, _ subtitle: String, _ url: String) -> some View {
        Button { navigate(url) } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Chrome.accent)
                    .frame(width: 35, height: 35).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Chrome.muted)
                }
                Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Chrome.muted)
            }.padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

@MainActor
private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 17, height: 20).contentShape(Rectangle()) }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).help(help).accessibilityLabel(help)
}
