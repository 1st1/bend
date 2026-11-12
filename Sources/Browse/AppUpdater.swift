import AppKit
import Combine
import Sparkle
import SwiftUI

// @lat: [[architecture#Application updates]]
@MainActor
final class AppUpdater: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate, NSMenuItemValidation {
    static let shared = AppUpdater()
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    let isEnabled: Bool
    private let preview: (version: String, show: () -> Void)?

    init(profile: AppProfile = .current, bundle: Bundle = .main) {
        isEnabled = profile == .production && bundle.bundleIdentifier == AppProfile.production.bundleIdentifier
            && bundle.bundleURL.pathExtension == "app"
        preview = makeUpdatePreview(profile: profile, bundle: bundle)
        super.init()
    }

    func start() {
        if let preview { availableVersion = preview.version; return }
        guard isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            self?.canCheckForUpdates = value
        }
        controller.startUpdater()
        let updater = controller.updater
        // Sparkle permits an extra launch check before its next runloop cycle.
        // Its own scheduler handles subsequent hourly checks and persistence.
        if updater.canCheckForUpdates, updater.automaticallyChecksForUpdates,
           Self.needsLaunchCheck(lastCheck: updater.lastUpdateCheckDate) {
            updater.checkForUpdatesInBackground()
        }
    }

    static func needsLaunchCheck(lastCheck: Date?, now: Date = .now) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= 10 * 60
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        if let preview { preview.show(); return }
        guard isEnabled else { return }
        start()
        controller?.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                               andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        availableVersion = handleShowingUpdate ? nil : update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}

struct AppUpdateButton: View {
    @ObservedObject var updater: AppUpdater = .shared

    var body: some View {
        if let version = updater.availableVersion {
            Button { updater.checkForUpdates() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16))
                        .frame(width: SidebarTabIconView.slotSize.width)
                    Text("Update to \(version)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 11)
                .frame(height: Chrome.sidebarTabHeight)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .glassEffect(.regular.tint(Color(red: 1, green: 0.76, blue: 0.12).opacity(0.55)).interactive(), in: Capsule())
            .help("Download and install the latest Bend update")
            .background(WindowDragArea(excluded: true))
            .padding(.bottom, 8)
        }
    }
}

@MainActor
private func makeUpdatePreview(profile: AppProfile, bundle: Bundle) -> (version: String, show: () -> Void)? {
    #if !BEND_PRODUCTION
    guard profile == .debug, bundle.object(forInfoDictionaryKey: "BendPreviewUpdates") as? Bool == true else { return nil }
    let preview = AppUpdatePreview(bundle: bundle)
    return (preview.version, preview.show)
    #else
    return nil
    #endif
}
