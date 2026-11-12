import AppKit
import SwiftUI

@available(macOS 15.4, *)
struct ExtensionCatalogView: View {
    @ObservedObject var manager: ExtensionManager
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ExtensionUpdateControls(updater: manager.updates)
                ForEach(CatalogExtension.curated) { entry in card(entry) }
                mouseGesturesCard
                Text("Installations start disabled. Review permissions when you enable an extension. Bend checks for updates at startup and every four hours. Reload open pages after changing extensions.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private var mouseGesturesCard: some View {
        let record = manager.records.first { $0.packageIdentifier == ExtensionManager.mouseGesturesIdentifier }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let record, let icon = manager.contexts[record.id]?.webExtension.icon(for: NSSize(width: 48, height: 48)) {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "computermouse").font(.system(size: 25, weight: .medium))
                            .foregroundStyle(Color.blue)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mouse Gestures for Safari").font(.system(size: 17, weight: .semibold))
                    Text("Petr Mareš · Productivity").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ExtensionCardBadges(updater: manager.updates, packageLabel: "Safari package", id: nil,
                    version: record.flatMap { manager.contexts[$0.id]?.webExtension.displayVersion })
            }
            Text("Use mouse gestures to open and close tabs, navigate, and scroll.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("If needed, installation opens the App Store. Get the app there, then return to Bend to finish. You don’t need to enable it in Safari.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("View in App Store ↗", destination: URL(string: "https://apps.apple.com/app/id1618804075")!)
                Spacer()
                if manager.waitingForMouseGesturesApp {
                    Text("Waiting for App Store installation…").font(.callout).foregroundStyle(.secondary)
                    Button("Cancel", action: manager.cancelMouseGesturesInstall)
                } else if let record {
                    Toggle("Enable Mouse Gestures", isOn: Binding(
                        get: { manager.isEnabled(record.id) },
                        set: { manager.setEnabled($0, id: record.id) }))
                        .toggleStyle(.switch).disabled(manager.busy)
                } else {
                    Button("Install in Bend") { manager.installMouseGestures() }
                        .buttonStyle(.borderedProminent).disabled(manager.busy)
                }
            }
            if let record {
                Divider()
                HStack {
                    Text("After updating the App Store app, update Bend’s copy here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Update from App") { manager.installMouseGestures() }
                        .disabled(manager.busy)
                }
                ExtensionManagementView(manager: manager, record: record)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06), lineWidth: 1))
    }

    private func card(_ entry: CatalogExtension) -> some View {
        let record = manager.catalogRecord(entry)
        let description = record.flatMap { manager.contexts[$0.id]?.webExtension.displayDescription }
            .flatMap { $0.isEmpty ? nil : $0 } ?? entry.summary
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let record, let icon = manager.contexts[record.id]?.webExtension.icon(for: NSSize(width: 48, height: 48)) {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: entry.symbol).font(.system(size: 25, weight: .medium))
                            .foregroundStyle(entry.experimental ? Color.blue : Color.red)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background((entry.experimental ? Color.blue : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.system(size: 17, weight: .semibold))
                    Text("\(entry.publisher) · \(entry.category)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ExtensionCardBadges(updater: manager.updates,
                    packageLabel: entry.id == "ublock-lite" ? "Safari package" : "Firefox package", id: record?.id,
                    version: record.flatMap { manager.contexts[$0.id]?.webExtension.displayVersion })
            }
            Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
            if entry.id == "1password" {
                Label("To connect to the 1Password desktop app, open 1Password → Settings → Browser → Add Browser and select Bend in your Applications folder, if you haven’t already.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Link("About this extension ↗", destination: entry.website).font(.callout)
                Spacer()
                if manager.catalogInstallingID == entry.id {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.callout).foregroundStyle(.secondary)
                    Button("Cancel", action: manager.cancelCatalogInstall)
                } else if let record {
                    Toggle("Enable \(entry.name)", isOn: Binding(
                        get: { manager.isEnabled(record.id) },
                        set: { manager.setEnabled($0, id: record.id) }))
                        .toggleStyle(.switch).disabled(manager.busy)
                } else {
                    Button("Install in Bend") { manager.installFromCatalog(entry) }
                        .buttonStyle(.borderedProminent).disabled(manager.busy)
                }
            }
            if let record {
                Divider()
                ExtensionUpdateStatus(updater: manager.updates, id: record.id)
                ExtensionManagementView(manager: manager, record: record)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06), lineWidth: 1))
    }
}

@available(macOS 15.4, *)
private struct ExtensionCardBadges: View {
    @ObservedObject var updater: ExtensionUpdater
    let packageLabel: String
    let id: UUID?
    let version: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                pill(packageLabel)
                if let version {
                    pill(version).help("Installed version \(version)")
                        .accessibilityLabel("Installed version \(version)")
                }
            }
            if let id, updater.messages[id] == "Up to date.", updater.installing != id {
                pill("Up to date")
            }
        }.fixedSize()
    }

    private func pill(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

@available(macOS 15.4, *)
private struct ExtensionUpdateControls: View {
    @ObservedObject var updater: ExtensionUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Install extension updates automatically", isOn: $updater.automaticallyInstall)
                Spacer()
                if updater.checking { ProgressView().controlSize(.small) }
                Button(updater.checking ? "Checking…" : "Check for Updates") { updater.check() }
                    .disabled(updater.checking || updater.installing != nil)
            }
            if let date = updater.lastChecked {
                Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = updater.preferenceError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionUpdateStatus: View {
    @ObservedObject var updater: ExtensionUpdater
    let id: UUID
    var body: some View {
        HStack {
            if updater.installing == id {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.caption)
            } else {
                if let message = updater.messages[id], message != "Up to date." {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if updater.candidates[id] != nil {
                    Spacer()
                    Button("Update") { updater.update(id) }
                        .disabled(updater.checking || updater.installing != nil)
                }
            }
        }
    }
}
