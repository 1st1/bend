import Foundation
import WebKit

// @lat: [[lat.md/architecture/build#Build profile isolation]]
enum AppProfile: String, Sendable {
    case debug, production

    // Unpackaged SwiftPM/Xcode runs are development runs too. Production is an
    // explicit compiler choice, independent of optimization or bundle location.
    #if BEND_PRODUCTION
    static let current: AppProfile = .production
    #else
    static let current: AppProfile = .debug
    #endif

    var name: String { self == .debug ? "Bend Debug" : "Bend" }
    var bundleIdentifier: String { self == .debug ? "dev.yury.browse.debug" : "dev.yury.browse.prototype" }
    var directoryName: String { self == .debug ? "Bend Debug" : "BrowsePrototype" }
    var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }
    var defaults: UserDefaults { defaults(hostBundleIdentifier: Bundle.main.bundleIdentifier) }

    func defaults(hostBundleIdentifier: String?) -> UserDefaults {
        // Foundation rejects a named suite equal to the running app's bundle ID.
        // Packaged apps already get their isolated domain through .standard.
        if hostBundleIdentifier == bundleIdentifier { return .standard }
        // SwiftPM tools/tests have a different (or absent) host bundle identity.
        return UserDefaults(suiteName: bundleIdentifier) ?? .standard
    }
    func frameName(_ productionName: String) -> String {
        self == .debug ? "BendDebug-" + productionName : productionName
    }
    var websiteStorageIdentifier: UUID? {
        self == .debug ? UUID(uuidString: "B160C74D-C950-491F-91FD-5997CEB63F1A")! : nil
    }
    var extensionStorageIdentifier: UUID? {
        self == .debug ? UUID(uuidString: "30291E68-4698-4493-A545-4187EC33BF71")! : nil
    }
    @MainActor var websiteDataStore: WKWebsiteDataStore {
        if let id = websiteStorageIdentifier { return WKWebsiteDataStore(forIdentifier: id) }
        return .default()
    }
}
