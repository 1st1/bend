import AppKit
import SwiftUI
import WebKit
import BrowseCore

private typealias ViewState<Value> = SwiftUI.State<Value>

// @lat: [[architecture#Extension settings]]
@MainActor
final class SettingsWindowController {
    let window: NSWindow
    init(store: BrowserStore) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Bend Settings"
        window.titleVisibility = .hidden
        if #available(macOS 15.0, *) {
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "BendSettingsTitlebar")
        window.setFrameAutosaveName("BrowseSettings")
        let hosting = NSHostingController(rootView: BrowserSettingsView(store: store, onScrollUnderHeader: { [weak window] scrolled in
            window?.titlebarAppearsTransparent = !scrolled
            window?.titlebarSeparatorStyle = scrolled ? .automatic : .none
        })
            .frame(width: 880)
            .frame(minHeight: 480))
        // Derive both native bounds from the fixed-width layout so SwiftUI's
        // sizing updates preserve the constraint after every section change.
        hosting.sizingOptions = [.minSize, .maxSize]
        hosting.sceneBridgingOptions = .all
        window.contentViewController = hosting
        window.minSize = NSSize(width: 880, height: 480)
        window.maxSize = NSSize(width: 880, height: window.maxSize.height)
    }
    func show(centeredOn screen: NSScreen? = nil) {
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

private enum SettingsSection: String, CaseIterable, Identifiable {
    case ui = "UI"
    case websites = "Websites"
    case extensions = "Extensions"
    case development = "Development"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .ui: "slider.horizontal.3"
        case .websites: "globe"
        case .extensions: "puzzlepiece.extension.fill"
        case .development: "hammer.fill"
        }
    }
    var color: Color {
        switch self {
        case .ui: .blue
        case .websites: .teal
        case .extensions: .purple
        case .development: .gray
        }
    }
}

struct BrowserSettingsView: View {
    @ObservedObject var store: BrowserStore
    var onScrollUnderHeader: (Bool) -> Void = { _ in }
    @ViewState<SettingsSection?> private var selection = .ui
    @ViewState<Bool> private var contentUnderHeader = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: $selection) { section in
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
                case .websites:
                    WebsiteSettingsView(settings: store.websiteSettings)
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
            sidebar.minimumThickness = 200
            sidebar.maximumThickness = 200
            sidebar.canCollapse = false
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.lockWidth() }
        }

        func lockWidth() {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView,
                   split.delegate is NSSplitViewController {
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
            Section {
                Picker("Command-click a link", selection: $store.commandClickDestination) {
                    Text("Always open a new pane").tag(CommandClickDestination.newPane)
                    Text("Reuse one dedicated pane per tab").tag(CommandClickDestination.dedicatedPane)
                    Text("Open in a new tab").tag(CommandClickDestination.newTab)
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
                            Text("Outline width")
                            Spacer()
                            Text("\(store.paneHighlight.outlineWidth, specifier: "%.1f") pt")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $store.paneHighlight.outlineWidth, in: 0.5...6, step: 0.5) {
                            Text("Outline width")
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
            PaneBorderSettingsSection(title: "Header separator", line: $store.paneBorders.separator,
                                      defaults: PaneBorders().separator)
            if #available(macOS 26.0, *) {
                GlassSettingsSection(title: "Browser window", appearance: $store.windowGlass, defaults: .windowDefault)
                GlassSettingsSection(title: "Pane headers", appearance: $store.paneHeaderGlass, defaults: .headerDefault)
            }
        }.formStyle(.grouped)
    }
}

private struct PaneBorderSettingsSection: View {
    let title: String
    @Binding var line: PaneBorders.Line
    let defaults: PaneBorders.Line

    var body: some View {
        Section {
            Toggle("Show \(title.lowercased())", isOn: $line.enabled)
            Group {
                ColorPicker("Color", selection: Binding(
                    get: { line.color.color },
                    set: { if let color = GlassAppearance.Tint(color: $0) { line.color = color } }
                ), supportsOpacity: false)
                VStack(spacing: 10) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text(line.opacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $line.opacity, in: 0...1) { Text("Opacity") }.labelsHidden()
                }
                VStack(spacing: 10) {
                    HStack {
                        Text("Width")
                        Spacer()
                        Text("\(line.width, specifier: "%.1f") pt")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $line.width, in: 0.5...4, step: 0.5) { Text("Width") }.labelsHidden()
                }
            }.disabled(!line.enabled)
            Button("Reset to Defaults") { line = defaults }.disabled(line == defaults)
        } header: {
            Text(title)
        }
    }
}

private struct GlassSettingsSection: View {
    let title: String
    @Binding var appearance: GlassAppearance
    let defaults: GlassAppearance

    var body: some View {
        Section {
            Picker("Glass style", selection: $appearance.clear) {
                Text("Regular").tag(false)
                Text("Clear").tag(true)
            }
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
            Button("Reset to Defaults") { appearance = defaults }
                .disabled(appearance == defaults)
        } header: {
            Text(title)
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
        .onAppear { manager.discoverInstalled() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.discoverInstalled()
        }
    }
}

@available(macOS 15.4, *)
struct ExtensionManagementView: View {
    @ObservedObject var manager: ExtensionManager
    let record: ExtensionRecord

    var body: some View {
        let context = manager.contexts[record.id]
        VStack(alignment: .leading, spacing: 10) {
            if let version = context?.webExtension.displayVersion {
                Text("Installed version \(version)").font(.caption).foregroundStyle(.secondary)
            }
            if let failure = manager.failures[record.id] { Text(failure).font(.callout).foregroundStyle(.red) }
            Text(manager.ownsPackage(record) ? "Installed in Bend · Updated manually" : "Import pending")
                .font(.caption).foregroundStyle(.secondary)
            if let notice = manager.compatibilityNotice(record.id) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let context, context.hasPermission(.init(rawValue: "nativeMessaging")) {
                Text(manager.nativeMessaging.status(for: context)).font(.caption).foregroundStyle(.secondary)
            }
            if manager.diagnostics.writeFailed {
                Text("Diagnostic log could not be saved. Copy Diagnostics still includes this session.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let errors = context?.errors, !errors.isEmpty {
                Text(errors.map(\.localizedDescription).joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
            }
            if let description = context?.webExtension.displayDescription, !description.isEmpty {
                Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            DisclosureGroup("Permissions and website access") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.permissionSummary(record.id), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.font(.callout)
            HStack {
                if context?.webExtension.hasOptionsPage == true {
                    Button("Extension Settings…") { manager.showOptions(record.id) }.disabled(!manager.isEnabled(record.id))
                }
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manager.diagnosticReport(), forType: .string)
                }
                .help("Copy extension lifecycle and desktop connection events across restarts. No passwords or message contents.")
                Spacer()
                Button("Update from File…") { manager.chooseUpdate(record.id) }.disabled(manager.busy)
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
            ForEach(manager.records.filter { manager.isEnabled($0.id) }) { record in
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
