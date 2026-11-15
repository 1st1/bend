import SwiftUI
import BrowseCore

private typealias PermissionState<Value> = SwiftUI.State<Value>

struct WebsitePermissionsTable: View {
    @ObservedObject var settings: WebsiteSettingsStore
    @PermissionState private var query = ""
    private struct Site: Identifiable {
        let id: String
    }
    private var sites: [Site] {
        settings.values.permissionOrigins.filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }.map { Site(id: $0) }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search websites", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search saved website permissions")
            Table(sites) {
                TableColumn("Website") { site in
                    Text(site.id).lineLimit(1).truncationMode(.middle)
                        .help(site.id).textSelection(.enabled)
                }.width(min: 150, ideal: 260)
                TableColumn("Camera") { site in picker(.camera, site: site) }.width(82)
                TableColumn("Microphone") { site in picker(.microphone, site: site) }.width(90)
                TableColumn("Location") { site in picker(.location, site: site) }.width(82)
                TableColumn("") { site in
                    Button {
                        settings.setPermissions(.ask, permissions: WebsitePermission.allCases, origin: site.id)
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove saved permissions for \(site.id)")
                    .accessibilityLabel("Remove \(site.id)")
                }.width(28)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: 240 / 1.9)
            .overlay {
                if sites.isEmpty {
                    Text(query.isEmpty ? "No saved website permissions" : "No matching websites")
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
        }
    }

    private func picker(_ permission: WebsitePermission, site: Site) -> some View {
        Picker(permission.title, selection: Binding(
            get: { settings.values.permission(permission, for: site.id) },
            set: { settings.setPermission($0, permission: permission, origin: site.id) })) {
                ForEach(WebsitePermissionChoice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .labelsHidden().controlSize(.small)
            .accessibilityLabel("\(permission.title) for \(site.id)")
    }
}
