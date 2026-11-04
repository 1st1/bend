import Foundation
import UserNotifications

@MainActor
protocol ExtensionNotificationDelivering: AnyObject {
    var onResponse: ((String, String) -> Void)? { get set }
    func permission() async -> Bool
    func post(key: String, title: String, message: String, buttons: [String]) async throws
    func remove(keys: [String])
    func keys() async -> Set<String>
}

@MainActor
final class ExtensionNotifications: NSObject, ExtensionNotificationDelivering, UNUserNotificationCenterDelegate {
    var onResponse: ((String, String) -> Void)?
    private var categories: [String: UNNotificationCategory] = [:]
    private var center: UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }

    func permission() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func post(key: String, title: String, message: String, buttons: [String]) async throws {
        let center = center
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        }
        guard await permission() else {
            throw NSError(domain: "Browse.Extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: "Notifications are disabled for Browse in System Settings."])
        }
        let actions = buttons.enumerated().map { UNNotificationAction(identifier: "button:\($0.offset)", title: $0.element, options: [.foreground]) }
        categories[key] = UNNotificationCategory(identifier: key, actions: actions, intentIdentifiers: [], options: [.customDismissAction])
        center.setNotificationCategories(Set(categories.values))
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.categoryIdentifier = key
        try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    func remove(keys: [String]) {
        guard !keys.isEmpty else { return }
        let center = center
        center.removePendingNotificationRequests(withIdentifiers: keys)
        center.removeDeliveredNotifications(withIdentifiers: keys)
        for key in keys { categories[key] = nil }
        center.setNotificationCategories(Set(categories.values))
    }

    func keys() async -> Set<String> {
        let center = center
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }
        return Set(delivered + pending)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            self?.onResponse?(key, action)
        }
        completionHandler()
    }
}
