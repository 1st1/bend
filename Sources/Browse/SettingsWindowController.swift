import AppKit
import SwiftUI
import WebKit

// @lat: [[architecture#Extension settings]]
@MainActor
final class SettingsWindowController {
    private let window: NSWindow
    init(store: BrowserStore) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Browse Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 420)
        window.setFrameAutosaveName("BrowseSettings")
        if #available(macOS 15.4, *) {
            window.contentView = NSHostingView(rootView: ExtensionSettingsView(manager: store.extensions))
        } else {
            window.contentView = NSHostingView(rootView: Text("Web extensions require macOS 15.4 or later.").padding(40))
        }
        window.center()
    }
    func show() { window.makeKeyAndOrderFront(nil) }
}

@available(macOS 15.4, *)
private struct ExtensionSettingsView: View {
    @ObservedObject var manager: ExtensionManager
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extensions").font(.system(size: 24, weight: .semibold))
                    Text("Install and manage Browse’s own extension copies, permissions, and data.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Install from File…", action: manager.chooseExtension).disabled(manager.busy)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if manager.busy { ProgressView().controlSize(.small) }
                    if let error = manager.error {
                        HStack(alignment: .top) {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                            Spacer()
                            Button("Dismiss") { manager.error = nil }
                        }
                    }
                    if manager.records.isEmpty {
                        ContentUnavailableView("No Extensions Installed", systemImage: "puzzlepiece.extension",
                            description: Text("Install a downloaded ZIP, Firefox XPI, Chrome CRX, or unpacked extension folder. API compatibility varies by extension."))
                    }
                    ForEach(manager.records) { record in extensionRow(record) }
                    if !manager.available.isEmpty {
                        DisclosureGroup("Import a Safari extension from this Mac") {
                        ForEach(manager.available) { item in
                            HStack {
                                Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                                Text(item.name)
                                Spacer()
                                Button("Import Copy") { manager.add(item.id) }.disabled(manager.busy)
                            }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                        }.padding(.top, 8)
                    }
                    Text("Reload open pages after changing extensions. Native Safari App Extensions are not supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
        }
        .onAppear { manager.discoverInstalled() }
    }

    private func extensionRow(_ record: ExtensionRecord) -> some View {
        let context = manager.contexts[record.id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let image = context?.webExtension.icon(for: NSSize(width: 32, height: 32)) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 32, height: 32)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.title2).frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name).font(.headline)
                    if let version = context?.webExtension.displayVersion { Text(version).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Toggle("Enable \(record.name)", isOn: Binding(get: { manager.isEnabled(record.id) },
                    set: { manager.setEnabled($0, id: record.id) })).labelsHidden().toggleStyle(.switch).disabled(manager.busy)
            }
            if let failure = manager.failures[record.id] { Text(failure).font(.callout).foregroundStyle(.red) }
            Text(manager.ownsPackage(record) ? "Installed in Browse · Updated manually" : "Import pending")
                .font(.caption).foregroundStyle(.secondary)
            if let notice = manager.compatibilityNotice(record.id) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
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
                Spacer()
                Button("Update from File…") { manager.chooseUpdate(record.id) }.disabled(manager.busy)
                Button("Remove…") { manager.remove(record.id) }.disabled(manager.busy)
            }
        }.padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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
            Image(systemName: "puzzlepiece.extension").font(.system(size: 11)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Extensions").accessibilityLabel("Extensions")
    }
}
