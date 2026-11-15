#if BEND_TESTING
#if BEND_PRODUCTION
#error("Production apps must not use test credential storage.")
#endif

import Foundation

struct GatewayCredential: AICredentialStore {
    var service = AppProfile.current.bundleIdentifier + ".ai-gateway"
    // Even default/shared settings must never access the developer's Keychain in tests.
    @MainActor private static var values: [String: String] = [:]
    func read() throws -> String? { Self.values[service] }
    func readAsync() async throws -> String? {
        try Task.checkCancellation()
        return try read()
    }
    func save(_ key: String) throws { Self.values[service] = key }
    func delete() throws { Self.values.removeValue(forKey: service) }
}
#endif
