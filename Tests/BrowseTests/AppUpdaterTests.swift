import AppKit
import Foundation
import Testing
import Sparkle
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

#if !BEND_PRODUCTION
// @lat: [[tests#Application update preview]]
@Test @MainActor func applicationUpdatePreview() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendUpdatePreview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Bend.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "dev.yury.browse.preview-test",
        "CFBundleName": "Bend Preview Test", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.2.0",
        "CFBundlePackageType": "APPL", "BendPreviewUpdates": true]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let bundle = try #require(Bundle(url: app))
    let updater = AppUpdater(profile: .debug, bundle: bundle)
    updater.start()
    #expect(updater.availableVersion == "0.3.0")
    #expect(!updater.isEnabled)
    #expect(!updater.canCheckForUpdates)
    let production = AppUpdater(profile: .production, bundle: bundle)
    production.start()
    #expect(production.availableVersion == nil)
    var finished = false
    let preview = AppUpdatePreview(bundle: bundle) { finished = true }
    defer { preview.dismiss() }
    let item = try #require(preview.makeItem())
    #expect(item.displayVersionString == "0.3.0")
    #expect(item.itemDescription?.contains("Nothing will be downloaded") == true)
    let state = try #require(try AppUpdatePreview.makeState())
    #expect(state.stage == .notDownloaded)
    #expect(state.userInitiated)
    func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }
    func button(_ title: String) -> NSButton? {
        NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap { buttons($0) }.first { $0.title == title }
    }
    preview.show()
    try await Task.sleep(for: .milliseconds(250))
    try #require(button("Install Update")).performClick(nil)
    try await Task.sleep(for: .milliseconds(250))
    try #require(button("Cancel")).performClick(nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!finished)
    preview.show()
    try await Task.sleep(for: .milliseconds(250))
    try #require(button("Install Update")).performClick(nil)
    for _ in 0..<70 {
        if button("Install and Relaunch") != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    try #require(button("Install and Relaunch")).performClick(nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(finished)
}
#endif
