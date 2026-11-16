import Foundation
import WebKit

// @lat: [[lat.md/architecture/ai#Page citations]]
@MainActor enum ChatPageLinks {
    static func citation(pane: UUID, address: String) -> String {
        var parts = URLComponents()
        parts.scheme = "bend-pane"
        parts.host = pane.uuidString
        parts.queryItems = [URLQueryItem(name: "url", value: address)]
        return parts.string ?? ""
    }

    static func citationComponents(_ url: URL) -> URLComponents? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)
    }

    static func sameDocument(_ first: String, _ second: String) -> Bool {
        guard var a = URLComponents(string: first), var b = URLComponents(string: second) else { return false }
        a.fragment = nil; b.fragment = nil
        return a.url == b.url
    }

    static func open(_ url: URL, tabID: UUID, store: BrowserStore) async throws {
        guard !store.isPrivate else { throw LinkError.unavailable }
        guard let tab = store.session.workspaces.flatMap(\.tabs).first(where: { $0.id == tabID }) else {
            throw LinkError.unavailable
        }
        let fallback = tab.pages.first(where: { $0.id == tab.commandClickPaneID })
            ?? (tab.pages.count == 1 ? tab.pages.first : nil)
        if url.scheme == "bend-pane" {
            guard let id = url.host.flatMap(UUID.init(uuidString:)),
                  let components = citationComponents(url),
                  let address = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let source = URL(string: address), (address == "bend://log" || ["http", "https"].contains(source.scheme?.lowercased() ?? "")),
                  source.host != nil, source.user == nil, source.password == nil else { throw LinkError.unavailable }
            guard components.queryItems?.contains(where: { $0.name == "selector" }) != true else {
                throw LinkError.legacyCitation
            }
            guard let page = tab.pages.first(where: { $0.id == id }) ?? fallback else {
                throw LinkError.unavailable
            }
            let controller = store.controller(for: page)
            controller.navigate(source.absoluteString)
            AIDiagnostics.shared.record("citation.anchorNavigation", tab: tabID, fields: ["pane": page.id.uuidString, "hasFragment": String(source.fragment != nil)])
            guard store.session.workspaces.flatMap(\.tabs).first(where: { $0.id == tabID })?.pages.contains(where: { $0.id == page.id }) == true else {
                throw LinkError.unavailable
            }
            store.select(tabID); store.focus(page.id)
            return
        }
        guard (url.absoluteString == "bend://log" || ["http", "https"].contains(url.scheme?.lowercased() ?? "")), url.host != nil,
              url.user == nil, url.password == nil else { throw LinkError.unsupported }
        let matches = tab.pages.filter {
            sameDocument(store.existingController(for: $0.id)?.address ?? $0.address, url.absoluteString)
        }
        store.select(tabID)
        if let page = matches.first(where: { $0.id == tab.focusedPane }) ?? matches.first {
            store.focus(page.id)
            if url.fragment != nil { store.controller(for: page).navigate(url.absoluteString) }
        } else if let page = fallback {
            store.focus(page.id)
            store.controller(for: page).navigate(url.absoluteString)
        } else {
            store.openPane(address: url.absoluteString, toRightOf: tab.focusedPane)
        }
    }

    enum LinkError: LocalizedError {
        case unavailable, unsupported, legacyCitation
        var errorDescription: String? {
            switch self {
            case .unavailable: "This reference's pane is no longer in this tab."
            case .legacyCitation: "This older citation uses a selector. Ask the assistant for a fresh anchor link."
            case .unsupported: "This link cannot be opened from chat."
            }
        }
    }
}
