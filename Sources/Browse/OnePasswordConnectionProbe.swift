import AppKit
import Security

// Only protocol enums are exposed. Never return arbitrary response values,
// account fields, identifiers, callback IDs, error prose, or payload data.
enum OnePasswordProtocolSummary {
    static let responseTypes: Set<String> = ["Success", "Failure", "BrowserSupport", "Notification", "NotificationModern"]
    static let codes: Set<String> = [
        "BrowserVerificationFailed", "BrowserVerificationFail", "InvalidBrowserSignature", "BrowserSignatureInvalid", "UnsupportedBrowser",
        "InvalidExtensionId", "InvalidBrowserMapping", "UnknownBrowser", "NotSigned", "MissingRequirementInfo",
        "NotInApplicationsDirectory", "AppBundleDoesNotExistOnDisk", "AppBundleIsSymlinked", "UnableToGetMetadata",
        "MainAppNotRunning", "MainAppOpenTimeout", "CannotOpenMainApp", "XpcNotAllowed", "UnknownInvocation",
        "ExtensionDisabled", "ExtensionSupportDisabled", "ExtensionSupportBanned", "LostConnectionToApp", "UnableToProcessRequest",
        "NmAuthenticationError", "AuthenticationFailed", "Untrusted", "Known", "Unknown", "AppQuit"
    ]
    static func fields(_ message: Any) -> [String: String] {
        guard let object = message as? [String: Any], let type = object["type"] as? String,
              responseTypes.contains(type) else { return ["protocolType": "other"] }
        var result = ["protocolType": type]
        if type == "Success" { return result }
        if let content = object["content"] as? [String: Any],
           let state = content["browser_state"] as? [String: Any], let stateType = state["type"] as? String,
           ["Known", "Untrusted", "Unknown"].contains(stateType) {
            result["browserState"] = stateType
            if let details = state["content"] as? [String: Any], let encoded = details["id"] as? String, encoded.count <= 512 {
                let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                if let data = Data(base64Encoded: padded), let identifier = String(data: data, encoding: .utf8),
                   identifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,199}$"#, options: .regularExpression) != nil {
                    result["reportedBrowserID"] = identifier
                }
            }
        }
        // Success contents can contain credentials: do not traverse them at all.
        guard type != "Success" else { return result }
        var found = Set<String>()
        func visit(_ value: Any?, depth: Int) {
            guard depth <= 5 else { return }
            if let code = value as? String, codes.contains(code) { found.insert(code) }
            if let object = value as? [String: Any] {
                for key in ["type", "response", "error", "reason", "content"] { visit(object[key], depth: depth + 1) }
            }
        }
        visit(object["content"], depth: 0)
        if !found.isEmpty { result["protocolCodes"] = found.sorted().joined(separator: ",") }
        return result
    }
}


struct OnePasswordSigningStatus {
    // Certificate requirement observed in the installed 1Password helper. This
    // is a preflight, not a substitute for the helper's own trust checks.
    static let requirement = "anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate leaf[field.1.2.840.113635.100.6.1.25.1] exists or (certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists))"
    let certificateStatus: OSStatus
    let hardenedRuntime: Bool
    static let current = inspect()
    static func inspect() -> Self {
        var code: SecCode?
        let copyStatus = SecCodeCopySelf([], &code)
        guard copyStatus == errSecSuccess, let code else { return .init(certificateStatus: copyStatus, hardenedRuntime: false) }
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement)
        let status = requirementStatus == errSecSuccess ? SecCodeCheckValidity(code, [], requirement) : requirementStatus
        var staticCode: SecStaticCode?, info: CFDictionary?
        var runtime = false
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let dictionary = info as? [String: Any], let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber {
            runtime = flags.uint32Value & 0x10000 != 0 // kSecCodeSignatureRuntime
        }
        return .init(certificateStatus: status, hardenedRuntime: runtime)
    }
    var fields: [String: String] {
        ["distributionCertificateAccepted": String(certificateStatus == errSecSuccess),
         "certificateRequirementStatus": String(certificateStatus), "hardenedRuntime": String(hardenedRuntime)]
    }
}

// @lat: [[architecture#1Password connection probe]]
@MainActor
enum OnePasswordConnectionProbe {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let connection = NativeMessageConnection()
        let callbackID = UUID().uuidString
        var completed = false
        func emit(_ fields: [String: String]) {
            if let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys),
               let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
        }
        func complete(_ status: Int32) {
            guard !completed else { return }; completed = true
            connection.finish()
            exit(status)
        }
        connection.received = { message in
            emit(OnePasswordProtocolSummary.fields(message))
            guard let object = message as? [String: Any], let content = object["content"] as? [String: Any],
                  content["callbackId"] as? String == callbackID else { return }
            complete(object["type"] as? String == "Success" ? 0 : 1)
        }
        connection.ended = { error in
            if let error { emit(ExtensionDiagnostics.errorFields(error)) }
            complete(1)
        }
        Task {
            emit(OnePasswordSigningStatus.current.fields)
            do {
                let host = try NativeHost.resolve("com.1password.1password", extensionID: "{d634138d-c276-4fc8-924b-40a0ea21d284}")
                try connection.start(host)
                // This invocation returns a feature-status flag, never accounts or credentials.
                try connection.send(["callbackId": callbackID, "invocation": ["type": "NmRequestMacNativeAutofillStatus"]])
                emit(["probe": "status-request-sent"])
            } catch { emit(ExtensionDiagnostics.errorFields(error)); complete(1) }
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            emit(["probe": "timeout"]); complete(2)
        }
        withExtendedLifetime(connection) { app.run() }
    }
}
