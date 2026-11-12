import AppKit
import SwiftUI
import Testing
@testable import Browse

// @lat: [[lat.md/tests/extension-hosting/lifecycle-tests#Extension permission presentation]]
@Test @MainActor func extensionPermissionPresentation() throws {
    _ = NSApplication.shared
    let details = ["<all_urls>", "activeTab", "alarms", "declarativeNetRequest",
                   "declarativeNetRequestWithHostAccess", "scripting", "storage", "unlimitedStorage"]
    let summary = ExtensionPermissionSummary(details: details)
    #expect(summary.websites == ["All websites"])
    #expect(summary.capabilities.count == 7)
    #expect(summary.details == details.sorted())
    let scoped = ExtensionPermissionSummary(details: ["https://*.example.com/private/*", "nativeMessaging", "futurePermission", "storage", "storage"])
    #expect(scoped.websites == ["https://*.example.com/private/*"])
    #expect(scoped.capabilities.contains { $0.title == "Communicate with companion apps on your Mac" })
    #expect(scoped.capabilities.contains { $0.title == "Additional permission: futurePermission" })
    #expect(scoped.details.count == 4)

    // Exercise native close cancellation through the actual modal window.
    let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated { NSApp.modalWindow?.performClose(nil) }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    defer { timer.invalidate() }
    #expect(!ExtensionPermissionDialog().run(name: "Test extension", details: details, icon: nil, sessionOnly: false))

    if let path = ProcessInfo.processInfo.environment["BEND_PERMISSION_PREVIEW"] {
        let host = NSHostingView(rootView: ExtensionPermissionView(name: "uBlock Origin Lite", icon: nil,
            summary: summary, sessionOnly: false, respond: { _ in }).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 580)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
