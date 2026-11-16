import SwiftUI
import WebKit
import BrowseCore

struct WebsitePermissionMenu: View {
    @ObservedObject var page: PageController
    @ObservedObject var settings: WebsiteSettingsStore
    let extensions: ExtensionManager
    let pageID: UUID
    let showExtensionSettings: () -> Void
    private var capturing: Bool { page.cameraCaptureState != .none || page.microphoneCaptureState != .none }

    var body: some View {
        Menu {
            if !page.isStartPage, let url = page.committedSiteURL, let origin = WebsitePermission.origin(for: url) {
                Text(origin)
                if page.usesCertificateException {
                    Text("Not Secure")
                    Text("You chose to trust a certificate Bend could not verify.")
                    Text("This website’s identity cannot be confirmed.")
                    Text("The exception lasts until you close this pane.")
                } else {
                    Text(url.scheme == "https" ? (page.webView.hasOnlySecureContent ? "HTTPS connection" : "Some content is not secure") : "Connection is not encrypted")
                }
                Button("View HTTPS Certificates…") { page.certificates.show(for: page.webView) }
                    .disabled(page.isLoading || !WebsiteCertificates.matchesSite(page.webView.url, committed: url) || url.scheme != "https" || page.webView.serverTrust == nil)
                Divider()
                ForEach(WebsitePermission.allCases, id: \.self) { permission in
                    Picker(permission.title, selection: Binding(
                        get: { settings.values.permission(permission, for: origin) },
                        set: { settings.setPermission($0, permission: permission, origin: origin) })) {
                            ForEach(WebsitePermissionChoice.allCases, id: \.self) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                }
                if capturing {
                    Divider()
                    if page.cameraCaptureState != .none { Text(page.cameraCaptureState == .active ? "Camera in use" : "Camera paused") }
                    if page.microphoneCaptureState != .none { Text(page.microphoneCaptureState == .active ? "Microphone in use" : "Microphone paused") }
                    Button("Stop Camera and Microphone") { page.stopCapture() }
                }
                Divider()
            }
            PaneExtensionsMenu(manager: extensions, pageID: pageID, showSettings: showExtensionSettings)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: capturing ? (page.cameraCaptureState != .none ? "video.fill" : "mic.fill") : "slider.horizontal.3")
                Text(page.isStartPage ? page.address : (page.committedSiteURL.flatMap(SiteDisplayDomain.label) ?? "Page")).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: 220)
            }
        }
        .menuStyle(.button)
        .buttonStyle(ChromeButtonStyle(pill: true, foregroundColor: page.usesCertificateException ? .red : nil))
        .menuIndicator(.hidden)
        .disabled(page.isStartPage)
        .fixedSize()
        .help((page.isStartPage ? page.address : (page.committedSiteURL.flatMap(WebsitePermission.origin) ?? "Page")) + " — " + (capturing ? "Camera or microphone in use — website permissions" : "Website permissions"))
        .accessibilityLabel(page.usesCertificateException ? "Not Secure — website permissions" : capturing ? "Capture controls and website permissions" : "Website permissions")
    }
}
