import AppKit
import Foundation
import Testing
@testable import Browse

// @lat: [[tests#Application updater isolation]]
@Test @MainActor func applicationUpdaterIsolation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendUpdater-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Bend.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": AppProfile.production.bundleIdentifier,
        "CFBundleName": "Bend", "CFBundleVersion": "12001", "CFBundleShortVersionString": "0.3.0",
        "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let bundle = try #require(Bundle(url: app))
    let debug = AppUpdater(profile: .debug, bundle: bundle)
    debug.start()
    debug.checkForUpdates()
    #expect(!debug.isEnabled)
    #expect(!debug.canCheckForUpdates)
    #expect(debug.availableVersion == nil)
    #expect(!AppUpdater(profile: .production, bundle: .main).isEnabled)
    let production = AppUpdater(profile: .production, bundle: bundle)
    #expect(production.isEnabled)
    #expect(production.supportsGentleScheduledUpdateReminders)
    // Catch misspelled optional Objective-C callbacks, which silently suppress reminders.
    for name in ["standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
                 "standardUserDriverWillHandleShowingUpdate:forUpdate:state:",
                 "standardUserDriverDidReceiveUserAttentionForUpdate:",
                 "standardUserDriverWillFinishUpdateSession"] {
        #expect(production.responds(to: NSSelectorFromString(name)))
    }
}
