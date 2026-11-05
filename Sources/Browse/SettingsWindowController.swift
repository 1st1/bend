import AppKit
import SwiftUI
import WebKit
import BrowseCore

// @lat: [[architecture#Extension settings]]
@MainActor
final class SettingsWindowController {
    private let window: NSWindow
    init(store: BrowserStore) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Browse Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 480)
        window.setFrameAutosaveName("BrowseSettings")
        window.contentView = NSHostingView(rootView: BrowserSettingsView(store: store))
        window.center()
    }
    func show() { window.makeKeyAndOrderFront(nil) }
}

struct BrowserSettingsView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        TabView {
            Group {
                if #available(macOS 15.4, *) {
                    ExtensionSettingsView(manager: store.extensions)
                } else {
                    Text("Web extensions require macOS 15.4 or later.").padding(40)
                }
            }
            .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }

            UISettingsView(store: store)
                .tabItem { Label("UI", systemImage: "slider.horizontal.3") }

            DevelopmentSettingsView()
                .tabItem { Label("Development", systemImage: "hammer") }
        }.padding(16)
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
            Section {
                Picker("Command-click a link", selection: $store.commandClickOpensNewTab) {
                    Text("Open in adjacent column to the right").tag(false)
                    Text("Open in a new tab").tag(true)
                }
            } header: {
                Text("Links")
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Inactive pane dimming")
                        Spacer()
                        Text(store.inactivePaneDimAmount, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $store.inactivePaneDimAmount, in: 0...1, step: 0.01) {
                        Text("Inactive pane dimming")
                    }.labelsHidden().frame(maxWidth: .infinity)
                    HStack {
                        Text("None")
                        Spacer()
                        Text("Fully dimmed")
                    }.font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Panes")
            }
            if #available(macOS 26.0, *) {
                GlassSettingsSection(title: "Browser window", appearance: $store.windowGlass, defaults: .windowDefault)
                GlassSettingsSection(title: "Pane headers", appearance: $store.paneHeaderGlass, defaults: .headerDefault)
            }
        }.formStyle(.grouped)
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
                Slider(value: $appearance.darkening, in: 0...1, step: 0.01) {
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
            Text(manager.ownsPackage(record) ? "Installed in Browse · Updated manually" : "Import pending")
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
