import AppKit
import SwiftUI
import WebKit
import BrowseCore

private typealias ViewState<Value> = SwiftUI.State<Value>

// @lat: [[lat.md/architecture/extensions/catalog#Extension settings]]
@MainActor
final class SettingsWindowController {
    let window: NSWindow
    private let navigation = SettingsNavigation()
    init(store: BrowserStore) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "\(AppProfile.current.name) Settings"
        window.titleVisibility = .hidden
        if #available(macOS 15.0, *) {
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "BendSettingsTitlebar")
        window.setFrameAutosaveName(AppProfile.current.frameName("BrowseSettings"))
        let hosting = NSHostingController(rootView: BrowserSettingsView(store: store, navigation: navigation, onScrollUnderHeader: { [weak window] scrolled in
            window?.titlebarAppearsTransparent = !scrolled
            window?.titlebarSeparatorStyle = scrolled ? .automatic : .none
        })
            .frame(width: 880)
            .frame(minHeight: 480)
            .defaultAppStorage(AppProfile.current.defaults))
        // Derive both native bounds from the fixed-width layout so SwiftUI's
        // sizing updates preserve the constraint after every section change.
        hosting.sizingOptions = [.minSize, .maxSize]
        hosting.sceneBridgingOptions = .all
        window.contentViewController = hosting
        window.minSize = NSSize(width: 880, height: 480)
        window.maxSize = NSSize(width: 880, height: window.maxSize.height)
    }
    func show(section: SettingsSection? = nil, centeredOn screen: NSScreen? = nil) {
        if let section { navigation.selection = section }
        let screen = screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        center(on: screen)
        // The first SwiftUI toolbar/layout pass can still change the frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.isVisible else { return }
            if let content = self.window.contentView { FixedSettingsSidebar.lockWidth(in: content) }
            self.window.contentView?.layoutSubtreeIfNeeded()
            self.center(on: screen)
        }
    }

    private func center(on screen: NSScreen?) {
        guard let screen else { return }
        let available = screen.visibleFrame
        var frame = window.frame
        frame.size.height = min(frame.height, available.height)
        frame.origin = NSPoint(x: (available.midX - frame.width / 2).rounded(),
            y: (available.midY - frame.height / 2).rounded())
        window.setFrame(frame, display: false)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case ui = "UI"
    case search = "Search"
    case websites = "Websites"
    case privacy = "Privacy"
    case extensions = "Extensions"
    case development = "Development"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .ui: "slider.horizontal.3"
        case .search: "magnifyingglass"
        case .websites: "globe"
        case .privacy: "hand.raised.fill"
        case .extensions: "puzzlepiece.extension.fill"
        case .development: "hammer.fill"
        }
    }
    var color: Color {
        switch self {
        case .ui: .blue
        case .search: .orange
        case .websites: .teal
        case .privacy: .green
        case .extensions: .purple
        case .development: .gray
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection? = .ui
}

struct BrowserSettingsView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var navigation: SettingsNavigation
    var onScrollUnderHeader: (Bool) -> Void = { _ in }
    @ViewState<Bool> private var contentUnderHeader = false
    private var selection: SettingsSection? { navigation.selection }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                HStack(spacing: 10) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(section.color.gradient, in: RoundedRectangle(cornerRadius: 5))
                    Text(section.rawValue)
                }
                .padding(.vertical, 2)
                .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .background(FixedSettingsSidebar(selection: selection?.rawValue ?? "UI"))
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection ?? .ui {
                case .ui:
                    UISettingsView(store: store)
                case .search:
                    SearchSettingsView(store: store)
                case .websites:
                    WebsiteSettingsView(settings: store.websiteSettings)
                case .privacy:
                    PrivacySettingsView(settings: store.websiteSettings, dataStore: store.websiteDataStore)
                case .extensions:
                    if #available(macOS 15.4, *) {
                        ExtensionSettingsView(manager: store.extensions)
                    } else {
                        Text("Web extensions require macOS 15.4 or later.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .development:
                    DevelopmentSettingsView()
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.visible)
            .modifier(SettingsScrollEdge(contentUnderHeader: $contentUnderHeader))
            .navigationTitle((selection ?? .ui).rawValue)
            .toolbarBackground(headerBackgroundVisibility, for: .windowToolbar)
            .toolbar {
                if #available(macOS 26.0, *) {
                    sectionTitle.sharedBackgroundVisibility(.hidden)
                } else {
                    sectionTitle
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: contentUnderHeader) { _, scrolled in onScrollUnderHeader(scrolled) }
        .onChange(of: selection) { _, _ in contentUnderHeader = false }
    }

    private var sectionTitle: some ToolbarContent {
        ToolbarItem(id: "settings.sectionTitle", placement: .navigation) {
            Text((selection ?? .ui).rawValue)
                .font(.system(size: 17, weight: .semibold))
                .padding(.leading, selection == .extensions ? 14 : 10)
        }
    }

    private var headerBackgroundVisibility: Visibility {
        if #available(macOS 15.0, *) {
            contentUnderHeader ? .visible : .hidden
        } else {
            .automatic
        }
    }
}

// Enforce the native column bounds as well as the SwiftUI content width.
private struct FixedSettingsSidebar: NSViewRepresentable {
    var selection: String

    static func lockWidth(in view: NSView) {
        if let split = view as? NSSplitView,
           let controller = split.delegate as? NSSplitViewController,
           let sidebar = controller.splitViewItems.first {
            if sidebar.minimumThickness != 200 { sidebar.minimumThickness = 200 }
            if sidebar.maximumThickness != 200 { sidebar.maximumThickness = 200 }
            if sidebar.canCollapse { sidebar.canCollapse = false }
            return
        }
        for child in view.subviews { lockWidth(in: child) }
    }

    func makeNSView(context: Context) -> SidebarConstraintView { SidebarConstraintView() }
    func updateNSView(_ view: SidebarConstraintView, context: Context) {
        // SwiftUI updates the native split items when selection changes.
        DispatchQueue.main.async { [weak view] in view?.lockWidth() }
    }

    final class SidebarConstraintView: NSView {
        private weak var sidebar: NSSplitViewItem?
        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.lockWidth() }
        }

        func lockWidth() {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView,
                   split.delegate is NSSplitViewController {
                    if let item = (split.delegate as? NSSplitViewController)?.splitViewItems.first,
                       sidebar !== item {
                        sidebar = item
                        // SwiftUI can reset these properties after its initial layout.
                        // Keep the native constraint in sync for the split item's lifetime.
                        observations = [
                            item.observe(\.minimumThickness, options: [.new]) { [weak self] _, _ in
                                MainActor.assumeIsolated { self?.lockWidth() }
                            },
                            item.observe(\.maximumThickness, options: [.new]) { [weak self] _, _ in
                                MainActor.assumeIsolated { self?.lockWidth() }
                            },
                            item.observe(\.canCollapse, options: [.new]) { [weak self] _, _ in
                                MainActor.assumeIsolated { self?.lockWidth() }
                            },
                        ]
                    }
                    FixedSettingsSidebar.lockWidth(in: split)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct SettingsScrollEdge: ViewModifier {
    @Binding var contentUnderHeader: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            tracked(content)
                .scrollEdgeEffectStyle(.hard, for: .top)
                .scrollEdgeEffectHidden(!contentUnderHeader, for: .top)
        } else if #available(macOS 15.0, *) {
            tracked(content)
        } else {
            content.toolbarBackground(.automatic, for: .windowToolbar)
        }
    }

    @available(macOS 15.0, *)
    private func tracked(_ content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 0.5
        } action: { _, underHeader in
            withAnimation(.easeOut(duration: 0.12)) {
                contentUnderHeader = underHeader
            }
        }
    }
}

private struct DevelopmentSettingsView: View {
    @AppStorage(InputDiagnostics.enabledPreferenceKey) private var loggingEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Input and pane logging", isOn: $loggingEnabled)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Records mouse event routing and pane activity in separate logs, each rotating at 500 KiB. Typed text and page content are excluded.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: loggingEnabled) { _, _ in InputDiagnostics.applyPreferences() }
    }
}

private struct UISettingsView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        Form {
            DefaultBrowserSettingsSection()
            Section("Sidebar") {
                Picker("Position", selection: $store.sidebarSide) {
                    Text("Left").tag(SidebarSide.left)
                    Text("Right").tag(SidebarSide.right)
                }
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Save files to")
                        Text(store.downloadDirectory.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(store.downloadDirectory.path)
                    }
                    Spacer()
                    Button("Change…") { chooseDownloadDirectory() }
                    Button("Use Downloads") { store.downloadDirectory = BrowserDownloads.defaultDirectory }
                        .disabled(store.downloadDirectory.path == BrowserDownloads.defaultDirectory.path)
                }
            } header: {
                Text("Downloads")
            }
            Section {
                Picker("Command-click a link", selection: $store.commandClickDestination) {
                    Text("Always open a new pane").tag(CommandClickDestination.newPane)
                    Text("Reuse one dedicated pane per tab").tag(CommandClickDestination.dedicatedPane)
                    Text("Open in a new tab").tag(CommandClickDestination.newTab)
                }
                Picker("Option-click a link", selection: $store.optionClickDestination) {
                    Text("Open in a new tab").tag(LinkOpenDestination.newTab)
                    Text("Open in a new pane").tag(LinkOpenDestination.newPane)
                    Text("Open in a new window").tag(LinkOpenDestination.newWindow)
                }
                Picker("Command-Shift-click a link", selection: $store.commandShiftClickDestination) {
                    Text("Open in a new tab").tag(LinkOpenDestination.newTab)
                    Text("Open in a new pane").tag(LinkOpenDestination.newPane)
                    Text("Open in a new window").tag(LinkOpenDestination.newWindow)
                }
            } header: {
                Text("Links")
            }
            Section {
                Picker("Active pane highlight", selection: $store.paneHighlight.style) {
                    Text("None").tag(PaneHighlight.Style.none)
                    Text("Transparency").tag(PaneHighlight.Style.transparency)
                    Text("Outline").tag(PaneHighlight.Style.outline)
                    Text("Outline glow").tag(PaneHighlight.Style.glow)
                    Text("Title tint").tag(PaneHighlight.Style.titleTint)
                }
                if store.paneHighlight.style == .transparency {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Inactive pane dimming")
                            Spacer()
                            Text(store.inactivePaneDimAmount, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $store.inactivePaneDimAmount, in: 0...1) {
                            Text("Inactive pane dimming")
                        }.labelsHidden().frame(maxWidth: .infinity)
                        HStack {
                            Text("None")
                            Spacer()
                            Text("Fully dimmed")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                } else if store.paneHighlight.style == .outline {
                    ColorPicker("Outline color", selection: Binding(
                        get: { store.paneHighlight.outlineColor.color },
                        set: { if let color = GlassAppearance.Tint(color: $0) { store.paneHighlight.outlineColor = color } }
                    ), supportsOpacity: false)
                    VStack(spacing: 10) {
                        HStack {
                            Text("Outline thickness")
                            Spacer()
                            Text("\(store.paneHighlight.outlineWidth, specifier: "%.1f") pt")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $store.paneHighlight.outlineWidth, in: PaneHighlight.outlineWidthRange) {
                            Text("Outline thickness")
                        }.labelsHidden()
                    }
                    VStack(spacing: 10) {
                        HStack {
                            Text("Gap from pane")
                            Spacer()
                            Text("\(store.paneHighlight.outlineGap, specifier: "%.1f") pt")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $store.paneHighlight.outlineGap, in: PaneHighlight.outlineGapRange) {
                            Text("Gap from pane")
                        }.labelsHidden()
                    }
                } else if store.paneHighlight.style == .glow {
                    ColorPicker("Glow color", selection: Binding(
                        get: { store.paneHighlight.glowColor.color },
                        set: { if let color = GlassAppearance.Tint(color: $0) { store.paneHighlight.glowColor = color } }
                    ), supportsOpacity: false)
                    VStack(spacing: 10) {
                        HStack {
                            Text("Glow intensity")
                            Spacer()
                            Text(store.paneHighlight.glowIntensity, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $store.paneHighlight.glowIntensity, in: 0...1) {
                            Text("Glow intensity")
                        }.labelsHidden()
                    }
                    VStack(spacing: 10) {
                        HStack {
                            Text("Glow spread")
                            Spacer()
                            Text("\(store.paneHighlight.glowSpread, specifier: "%.0f") pt")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $store.paneHighlight.glowSpread, in: 0...24, step: 1) {
                            Text("Glow spread")
                        }.labelsHidden()
                    }
                } else if store.paneHighlight.style == .titleTint {
                    ColorPicker("Tint color", selection: Binding(
                        get: { store.paneHighlight.titleTintColor.color },
                        set: { if let color = GlassAppearance.Tint(color: $0) { store.paneHighlight.titleTintColor = color } }
                    ), supportsOpacity: false)
                    VStack(spacing: 10) {
                        HStack {
                            Text("Tint intensity")
                            Spacer()
                            Text(store.paneHighlight.titleTintIntensity, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $store.paneHighlight.titleTintIntensity, in: 0...1) {
                            Text("Tint intensity")
                        }.labelsHidden()
                    }
                }
                Button("Reset to Defaults") {
                    store.paneHighlight = PaneHighlight()
                    store.inactivePaneDimAmount = BrowserStore.defaultInactivePaneDimAmount
                }
                .disabled(store.paneHighlight == PaneHighlight()
                    && store.inactivePaneDimAmount == BrowserStore.defaultInactivePaneDimAmount)
            } header: {
                Text("Panes")
            }
            if #available(macOS 26.0, *) {
                GlassSettingsSection(title: "Browser window", appearance: $store.windowGlass, defaults: .windowDefault)
                GlassSettingsSection(title: "Pane headers", appearance: $store.paneHeaderGlass, defaults: .headerDefault, allowsSolid: true,
                                     topRimClipping: $store.paneHeaderTopRimClipping,
                                     bottomRimClipping: $store.paneHeaderBottomRimClipping)
            }
        }.formStyle(.grouped)
    }

    private func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.downloadDirectory
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        store.downloadDirectory = directory
    }
}

private struct GlassSettingsSection: View {
    let title: String
    @Binding var appearance: GlassAppearance
    let defaults: GlassAppearance
    var allowsSolid = false
    var topRimClipping: Binding<Double>?
    var bottomRimClipping: Binding<Double>?

    var body: some View {
        Section {
            Picker("Glass style", selection: $appearance.style) {
                Text("Regular").tag(GlassAppearance.Style.regular)
                Text("Clear").tag(GlassAppearance.Style.clear)
                if allowsSolid { Text("Solid color").tag(GlassAppearance.Style.solid) }
            }
            if appearance.style == .solid {
                ColorPicker("Color", selection: Binding(
                    get: { appearance.solidColor.color },
                    set: { if let color = GlassAppearance.Tint(color: $0) { appearance.solidColor = color } }
                ), supportsOpacity: false)
            } else {
                HStack {
                    Toggle("Tint", isOn: Binding(
                        get: { appearance.tint != nil },
                        set: { appearance.tint = $0 ? GlassAppearance.Tint(color: .accentColor) : nil }
                    ))
                    Spacer()
                    ColorPicker("Tint color", selection: Binding(
                        get: { appearance.tint?.color ?? .accentColor },
                        set: { appearance.tint = GlassAppearance.Tint(color: $0) }
                    ), supportsOpacity: false)
                    .labelsHidden().disabled(appearance.tint == nil)
                }
                VStack(spacing: 10) {
                    HStack {
                        Text("Darkening")
                        Spacer()
                        Text(appearance.darkening, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $appearance.darkening, in: 0...1) {
                        Text("Darkening")
                    }.labelsHidden()
                }
                if let topRimClipping { rimClippingSlider("Top rim clipping", value: topRimClipping) }
                if let bottomRimClipping { rimClippingSlider("Bottom rim clipping", value: bottomRimClipping) }
                if topRimClipping != nil || bottomRimClipping != nil {
                    Text("Higher values hide more of each glass rim. Zero restores it. Applies to pane and mini-player headers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Reset to Defaults") {
                appearance = defaults
                topRimClipping?.wrappedValue = BrowserStore.defaultHeaderTopRimClipping
                bottomRimClipping?.wrappedValue = BrowserStore.defaultHeaderBottomRimClipping
            }
            .disabled(appearance == defaults && (topRimClipping?.wrappedValue ?? BrowserStore.defaultHeaderTopRimClipping)
                      == BrowserStore.defaultHeaderTopRimClipping
                      && (bottomRimClipping?.wrappedValue ?? BrowserStore.defaultHeaderBottomRimClipping)
                      == BrowserStore.defaultHeaderBottomRimClipping)
        } header: {
            Text(title)
        }
    }

    private func rimClippingSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.1f") pt")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: BrowserStore.headerRimClippingRange) { Text(title) }.labelsHidden()
        }
    }

}

@available(macOS 15.4, *)
private struct ExtensionSettingsView: View {
    @ObservedObject var manager: ExtensionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = manager.error {
                HStack(alignment: .top) {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { manager.error = nil }
                }.padding(16)
            }
            ExtensionCatalogView(manager: manager)
        }
    }
}

@available(macOS 15.4, *)
struct ExtensionManagementView: View {
    @ObservedObject var manager: ExtensionManager
    let record: ExtensionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable in private mode", isOn: Binding(
                get: { manager.records.first(where: { $0.id == record.id })?.enabledInPrivateMode ?? false },
                set: { manager.setPrivateAccess($0, id: record.id) }))
                .toggleStyle(.checkbox).disabled(manager.busy)
            Text("Allow this extension to access private tabs and website data. Extension pages and popups are unavailable in private windows. Reload open pages after changing this setting.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure = manager.failures[record.id] { Text(failure).font(.callout).foregroundStyle(.red) }
            if !manager.ownsPackage(record) {
                Text("Import pending").font(.caption).foregroundStyle(.secondary)
            }
            if let notice = manager.compatibilityNotice(record.id) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if manager.diagnostics.writeFailed {
                Text("Diagnostic log could not be saved. Copy Diagnostics still includes this session.")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Permissions and website access") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.permissionSummary(record.id), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.font(.callout)
            HStack {
                if manager.settingsPageURL(record.id) != nil {
                    Button("Extension Settings…") { manager.showOptions(record.id) }.disabled(!manager.isEnabled(record.id))
                }
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manager.diagnosticReport(), forType: .string)
                }
                .help("Copy extension lifecycle and desktop connection events across restarts. No passwords or message contents.")
                Spacer()
                Button("Remove…") { manager.remove(record.id) }.disabled(manager.busy)
            }
        }
    }
}

@available(macOS 15.4, *)
struct PaneExtensionsMenu: View {
    @ObservedObject var manager: ExtensionManager
    let pageID: UUID
    let showSettings: () -> Void
    var body: some View {
        Menu {
            ForEach(manager.records.filter { manager.isAvailable($0.id, pageID: pageID) }) { record in
                Button(record.name) { manager.performAction(record.id, pageID: pageID) }
            }
            Divider()
            Button("Manage Extensions…", action: showSettings)
        } label: {
            Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().frame(width: 12, height: 12)
        }
        .menuStyle(.button).buttonStyle(ChromeButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help("Extensions").accessibilityLabel("Extensions")
    }
}

private struct SearchSettingsView: View {
    @ObservedObject var store: BrowserStore
    @ViewState private var editingCustom = false
    @ViewState private var name = ""
    @ViewState private var template = ""
    private var draft: CustomSearchEngine { CustomSearchEngine(name: name, template: template) }

    var body: some View {
        Form {
            Section {
                Picker("Search engine", selection: Binding(
                    get: { editingCustom ? .custom : store.searchEngine },
                    set: { engine in
                        editingCustom = engine == .custom
                        if engine != .custom { store.searchEngine = engine }
                    })) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.name).tag(engine)
                    }
                }
            } footer: {
                Text("Used when you enter a search in the address bar.")
            }
            if editingCustom || store.searchEngine == .custom {
                Section {
                    TextField("Name", text: $name, prompt: Text("My search"))
                    TextField("Search URL", text: $template, prompt: Text("https://example.com/search?q=%s"))
                    if let error = draft.validationError, !name.isEmpty || !template.isEmpty {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Test Search") {
                            if let url = draft.searchURL(for: "Bend browser") {
                                store.newTab(address: url.absoluteString)
                            }
                        }
                        Spacer()
                        Button("Save") {
                            store.customSearchEngine = draft
                            store.searchEngine = .custom
                            editingCustom = false
                        }
                        .disabled(store.searchEngine == .custom && store.customSearchEngine == draft)
                    }
                    .disabled(draft.validationError != nil)
                } header: {
                    Text("Custom search engine")
                } footer: {
                    Text("Use %s for the search text. Extra URL parameters are preserved. Test Search opens a new tab with “Bend browser”. Save applies your changes.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = store.customSearchEngine?.name ?? ""
            template = store.customSearchEngine?.template ?? ""
        }
    }
}
