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

    init(profile: AppProfile = .current, bundle: Bundle = .main) {
        isEnabled = profile == .production && bundle.bundleIdentifier == AppProfile.production.bundleIdentifier
            && bundle.bundleURL.pathExtension == "app"
        super.init()
    }

    func start() {
        guard isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            self?.canCheckForUpdates = value
        }
        controller.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
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
                Label("Update to \(version)", systemImage: "arrow.down.circle")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Chrome.accent)
            .background(Chrome.accent.opacity(0.12), in: Capsule())
            .help("Download and install the latest Bend update")
            .background(WindowDragArea(excluded: true))
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
    }
}
