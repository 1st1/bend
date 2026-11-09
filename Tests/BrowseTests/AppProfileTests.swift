import AppKit
import Testing
import WebKit
@testable import Browse

// @lat: [[tests#Build profile isolation]]
@Test @MainActor func buildProfileIsolation() async throws {
    let debug = AppProfile.debug
    let production = AppProfile.production
    #expect(debug.name == "Bend Debug")
    #expect(production.name == "Bend")
    #expect(debug.bundleIdentifier != production.bundleIdentifier)
    #expect(debug.supportDirectory != production.supportDirectory)
    #expect(debug.supportDirectory.lastPathComponent == "Bend Debug")
    #expect(production.supportDirectory.lastPathComponent == "BrowsePrototype")
    #expect(debug.frameName("BrowseMainWindow") != production.frameName("BrowseMainWindow"))
    #expect(production.frameName("BrowseMainWindow") == "BrowseMainWindow")
    #expect(debug.websiteStorageIdentifier != nil)
    #expect(debug.extensionStorageIdentifier != nil)
    #expect(production.websiteStorageIdentifier == nil)
    #expect(production.extensionStorageIdentifier == nil)
    #expect(debug.websiteDataStore.identifier == debug.websiteStorageIdentifier)
    #expect(production.websiteDataStore.identifier == nil)
    #expect(AppProfile.current == .debug)
    // The packaged-host case differs from SwiftPM's test bundle. Never try to
    // construct a named suite using the running application's own identifier.
    #expect(debug.defaults(hostBundleIdentifier: debug.bundleIdentifier) === UserDefaults.standard)
    #expect(production.defaults(hostBundleIdentifier: production.bundleIdentifier) === UserDefaults.standard)
    // Unique marker only; remove it without changing any real preferences.
    let key = "BendIsolationTest-\(UUID())"
    defer { debug.defaults.removeObject(forKey: key) }
    debug.defaults.set("debug-only", forKey: key)
    #expect(debug.defaults.string(forKey: key) == "debug-only")
    #expect(production.defaults.object(forKey: key) == nil)
    let cookie = try #require(HTTPCookie(properties: [.domain: "bend-isolation.invalid", .path: "/", .name: key, .value: "debug-only", .secure: "TRUE"]))
    await debug.websiteDataStore.httpCookieStore.setCookie(cookie)
    let debugCookies = await debug.websiteDataStore.httpCookieStore.allCookies()
    let productionCookies = await production.websiteDataStore.httpCookieStore.allCookies()
    await debug.websiteDataStore.httpCookieStore.deleteCookie(cookie)
    #expect(debugCookies.contains { $0.name == key })
    #expect(!productionCookies.contains { $0.name == key })
    if #available(macOS 15.4, *) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionManager(root: root)
        #expect(manager.controller.configuration.identifier == debug.extensionStorageIdentifier)
        #expect(manager.controller.configuration.defaultWebsiteDataStore?.identifier == debug.websiteStorageIdentifier)
    }
}
