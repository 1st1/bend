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
