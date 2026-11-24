import Foundation
import Combine
import BrowseCore

// @lat: [[lat.md/architecture/settings#Website settings]]
@MainActor
final class WebsiteSettingsStore: ObservableObject {
    @Published private(set) var values = WebsiteSettings()
    @Published private(set) var errorMessage: String?
    private var database: WebsiteSettingsDatabase?
    private let file: URL?

    init(file: URL) {
        self.file = file
        reload()
    }

    init(temporary values: WebsiteSettings) {
        file = nil
        self.values = values
    }

    func setPermission(_ choice: WebsitePermissionChoice, permission: WebsitePermission, origin: String) {
        setPermissions(choice, permissions: [permission], origin: origin)
    }

    func setPermissions(_ choice: WebsitePermissionChoice, permissions: [WebsitePermission], origin: String) {
        update { settings in
            for permission in permissions {
                settings.blockedPermissions[origin]?.remove(permission)
                settings.allowedPermissions[origin]?.remove(permission)
                if choice == .block { settings.blockedPermissions[origin, default: []].insert(permission) }
                if choice == .allow { settings.allowedPermissions[origin, default: []].insert(permission) }
            }
            if settings.blockedPermissions[origin]?.isEmpty == true { settings.blockedPermissions[origin] = nil }
            if settings.allowedPermissions[origin]?.isEmpty == true { settings.allowedPermissions[origin] = nil }
        }
    }

    func setBlocked(_ blocked: Bool, permission: WebsitePermission, origin: String) {
        setPermission(blocked ? .block : .ask, permission: permission, origin: origin)
    }

    func resetTemporary() {
        guard file == nil else { return }
        values = WebsiteSettings()
    }

    func reload() {
        guard let file else { return }
        do {
            let database = try WebsiteSettingsDatabase(file: file)
            self.database = database
            values = database.load()
            errorMessage = nil
        } catch {
            errorMessage = "Website settings could not be read: \(error.localizedDescription)"
        }
    }

    func setDefaultZoom(_ zoom: Double) {
        guard PageZoom.isValid(zoom) else { return }
        update { $0.defaultZoom = zoom }
    }

    func allowHTTP(for url: URL) {
        guard url.scheme == "http", let origin = WebsitePermission.origin(for: url) else { return }
        update { $0.allowedHTTPOrigins.insert(origin) }
    }

    func forgetHTTP(_ origin: String) { update { $0.allowedHTTPOrigins.remove(origin) } }

    func setPreference(_ key: WritableKeyPath<WebsiteSettings, Bool>, _ enabled: Bool) {
        update { $0[keyPath: key] = enabled }
    }

    func setZoom(_ zoom: Double, for url: URL) {
        guard let host = WebsiteSettings.hostname(for: url) else { return }
        setZoom(zoom, forHost: host)
    }

    func setZoom(_ zoom: Double, forHost host: String) {
        guard PageZoom.isValid(zoom) else { return }
        update { settings in
            settings.zoomByHost[host] = zoom == settings.defaultZoom ? nil : zoom
        }
    }

    func removeOverride(for host: String) { update { $0.zoomByHost[host] = nil } }
    func removeAllOverrides() { update { $0.zoomByHost.removeAll() } }

    private func update(_ change: (inout WebsiteSettings) -> Void) {
        var next = values
        change(&next)
        guard next.isValid else { return }
        if file == nil { values = next; return }
        guard let database else { return }
        do {
            try database.save(next)
            values = next
            errorMessage = nil
        } catch {
            errorMessage = "Website settings could not be saved: \(error.localizedDescription)"
        }
    }
}
