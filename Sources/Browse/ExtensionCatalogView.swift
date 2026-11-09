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
                Text("Installations start disabled. Review permissions when you enable an extension. Bend checks for updates at startup and every four hours. Reload open pages after changing extensions.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private func card(_ entry: CatalogExtension) -> some View {
        let record = manager.catalogRecord(entry)
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
                    Text(entry.summary).font(.callout).padding(.top, 3)
                }
                Spacer(minLength: 0)
            }
            Text(entry.id == "ublock-lite" ? "Safari package · Direct download" : "Firefox package")
                .font(.caption).foregroundStyle(.secondary)
            Text(entry.compatibility).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                if let message = updater.messages[id] { Text(message).font(.caption).foregroundStyle(.secondary) }
                if updater.candidates[id] != nil {
                    Spacer()
                    Button("Update") { updater.update(id) }
                        .disabled(updater.checking || updater.installing != nil)
                }
            }
        }
    }
}
