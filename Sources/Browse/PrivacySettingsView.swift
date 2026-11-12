import SwiftUI
import WebKit
import BrowseCore

private typealias ViewState<Value> = SwiftUI.State<Value>

struct PrivacySettingsView: View {
    @ObservedObject var settings: WebsiteSettingsStore
    let dataStore: WKWebsiteDataStore
    @ViewState private var showsWebsiteData = false

    var body: some View {
        Form {
            if let error = settings.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { settings.reload() }
                }
            }
            Section {
                protection("Websites are isolated by origin")
                protection("Private windows use separate, temporary website storage")
                if WebKitPrivacy.supports(.advanced, on: WKWebpagePreferences()) {
                    protection("Additional fingerprinting protections enabled",
                               detail: "Websites can combine details about your device to recognize you, even without cookies. WebKit limits or varies identifying information, such as reported screen dimensions and canvas image data, to make this harder.")
                    protection("Known tracking parameters filtered from links")
                    Text("Applies to regular and private browsing. Filtering depends on macOS WebKit’s available rules. Reload open pages to apply protections.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Additional tracking protections are unavailable on this macOS version", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Built-in protections")
            } footer: {
                Text("Powered by WebKit, the engine used by Safari. These protections do not hide your IP address or make browsing anonymous.")
            }
            Section("Website tracking") {
                privacyToggle("Prevent cross-site tracking", key: \.preventCrossSiteTracking,
                              control: .tracking, object: dataStore)
                Text("Limits third-party cookies and tracking storage. Additional fingerprinting and link protections remain enabled when this is off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Payments and advertising") {
                privacyToggle("Allow websites to check for Apple Pay and Apple Card", key: \.applePayDisclosureAllowed,
                              control: .applePay, object: WKPreferences())
                Text("Allows payment capability checks. Private browsing may further restrict disclosure.")
                    .font(.caption).foregroundStyle(.secondary)
                privacyToggle("Allow privacy-preserving measurement of ad effectiveness", key: \.privateClickMeasurementEnabled,
                              control: .measurement, object: WKPreferences())
                Text("Controls WebKit’s Private Click Measurement. Turning this off does not block advertisements.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Website data") {
                Toggle("Block all cookies", isOn: preference(\.blockAllCookies))
                Text("Websites may not work or let you sign in. Existing cookies are retained until you remove website data.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Manage Website Data…") { showsWebsiteData = true }
            }
            Section("IP address") {
                Text("Bend does not provide an IP-hiding service. A system VPN can hide your IP address from websites when Bend’s traffic is routed through it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsWebsiteData) { WebsiteDataView(dataStore: dataStore) }
    }

    private func protection(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func privacyToggle(_ title: String, key: WritableKeyPath<WebsiteSettings, Bool>,
                               control: WebKitPrivacy.Control, object: NSObject) -> some View {
        let available = WebKitPrivacy.supports(control, on: object)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: preference(key)).disabled(!available)
            if !available {
                Text("Unavailable on this macOS version").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func preference(_ key: WritableKeyPath<WebsiteSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings.values[keyPath: key] }, set: { settings.setPreference(key, $0) })
    }
}
