import AuthenticationServices
import Security
import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
enum BrowserPasskeys {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    static var isEntitled: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements[entitlement] as? Bool == true
    }
}

// @lat: [[lat.md/architecture/web-pages#Browser passkeys]]
struct BrowserPasskeySettings: View {
    @ViewState private var status = ""
    @ViewState private var requesting = false
    private let entitled = BrowserPasskeys.isEntitled

    var body: some View {
        if entitled {
            Section("Passkeys") {
                Text(status)
                Button("Allow Bend to Use Passkeys") {
                    requesting = true
                    ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { _ in
                        Task { @MainActor in requesting = false; refresh() }
                    }
                }.disabled(requesting)
            }.onAppear { refresh() }
        }
    }

    private func refresh() {
        guard entitled else { return }
        switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
        case .authorized: status = "Bend can use your passkeys when websites request them."
        case .denied: status = "Passkey access is denied. You can review browser access in System Settings."
        case .notDetermined: status = "Allow Bend to use passkeys for website sign-ins."
        @unknown default: status = "Passkey authorization is unavailable."
        }
    }
}
