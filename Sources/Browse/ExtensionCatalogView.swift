import AppKit
import SwiftUI

@available(macOS 15.4, *)
struct ExtensionCatalogView: View {
    @ObservedObject var manager: ExtensionManager
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Extensions").font(.title2.weight(.semibold))
                        Text("A small collection, with compatibility notes for each extension.")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    Button { manager.discoverInstalled() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh extensions available on this Mac").disabled(manager.busy)
                        .accessibilityLabel("Refresh available extensions")
                }
                ForEach(CatalogExtension.curated) { entry in card(entry) }
                Text("Installations start disabled. Review permissions when you enable an extension. Updates are manual. Reload open pages after changing extensions.")
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
            HStack(spacing: 8) {
                Text(entry.experimental ? "Experimental" : "Reported working")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(entry.experimental ? Color.orange : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                switch entry.installation {
                case .safari: Text("Safari package").font(.caption).foregroundStyle(.secondary)
                case .download(let download): Text("Firefox package · \(download.version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(entry.compatibility).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if record == nil, case .safari = entry.installation {
                Text(manager.catalogSource(entry) == nil
                    ? "Get the app from the App Store, then return here to install its extension in Bend."
                    : "Available on this Mac. Bend will install its own copy.")
                    .font(.caption).foregroundStyle(.secondary)
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
                } else if case .safari(_, let storeURL) = entry.installation, manager.catalogSource(entry) == nil {
                    Link("Get from App Store", destination: storeURL).buttonStyle(.bordered)
                } else {
                    Button("Install in Bend") { manager.installFromCatalog(entry) }
                        .buttonStyle(.borderedProminent).disabled(manager.busy)
                }
            }
            if let record {
                Divider()
                ExtensionManagementView(manager: manager, record: record)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06), lineWidth: 1))
    }
}
