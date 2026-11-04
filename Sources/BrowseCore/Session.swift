import Foundation

public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }

// @lat: [[architecture#Tiling model]]
public indirect enum PaneLayout: Codable, Equatable, Sendable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, fraction: Double, first: PaneLayout, second: PaneLayout)

    public var paneIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    public func splitting(_ target: UUID, with newID: UUID, axis: SplitAxis) -> Self {
        switch self {
        case .pane(let id):
            return id == target ? .split(id: UUID(), axis: axis, fraction: 0.5, first: self, second: .pane(newID)) : self
        case .split(let id, let direction, let fraction, let first, let second):
            return .split(id: id, axis: direction, fraction: fraction,
                          first: first.splitting(target, with: newID, axis: axis),
                          second: second.splitting(target, with: newID, axis: axis))
        }
    }

    public func removing(_ target: UUID) -> Self? {
        switch self {
        case .pane(let id): return id == target ? nil : self
        case .split(let id, let axis, let fraction, let first, let second):
            let a = first.removing(target), b = second.removing(target)
            if let a, let b { return .split(id: id, axis: axis, fraction: fraction, first: a, second: b) }
            return a ?? b
        }
    }

    public func resizing(_ target: UUID, to value: Double) -> Self {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(id: id, axis: axis, fraction: id == target ? min(0.85, max(0.15, value)) : fraction,
                          first: first.resizing(target, to: value), second: second.resizing(target, to: value))
        }
    }
}

public struct Page: Codable, Identifiable, Sendable {
    public var id: UUID
    public var address: String
    public init(address: String = "browse://start") { id = UUID(); self.address = address }
}

public struct BrowserTab: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var layout: PaneLayout
    public var pages: [Page]
    public var focusedPane: UUID

    public init(title: String = "New tab", pages: [Page] = [Page()]) {
        let pages = pages.isEmpty ? [Page()] : pages
        id = UUID(); self.title = title; self.pages = pages; focusedPane = pages[0].id
        layout = pages.dropFirst().reduce(.pane(pages[0].id)) {
            .split(id: UUID(), axis: .horizontal, fraction: 0.5, first: $0, second: .pane($1.id))
        }
    }

    public mutating func split(axis: SplitAxis, after source: UUID? = nil, address: String = "browse://start") {
        let source = source ?? focusedPane
        guard pages.contains(where: { $0.id == source }) else { return }
        let page = Page(address: address)
        layout = layout.splitting(source, with: page.id, axis: axis)
        pages.append(page); focusedPane = page.id
    }

    public mutating func closePane(_ id: UUID) {
        guard let next = layout.removing(id) else { return }
        layout = next; pages.removeAll { $0.id == id }
        if focusedPane == id { focusedPane = next.paneIDs[0] }
    }
}

public struct Workspace: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var tabs: [BrowserTab]
    public init(name: String, tabs: [BrowserTab] = [BrowserTab()]) {
        id = UUID(); self.name = name; self.tabs = tabs
    }
}

// @lat: [[architecture#Session restoration]]
public struct BrowserSession: Codable, Sendable {
    public var workspaces: [Workspace]
    public var selectedTab: UUID

    public init() {
        let initial = BrowserTab(title: "Start here", pages: [Page(), Page(address: "browse://guide")])
        workspaces = [Workspace(name: "everyday", tabs: [initial]), Workspace(name: "research")]
        selectedTab = initial.id
    }

    public var isValid: Bool {
        let tabs = workspaces.flatMap(\.tabs)
        let pages = tabs.flatMap(\.pages)
        return !workspaces.isEmpty && workspaces.allSatisfy { !$0.tabs.isEmpty }
            && Set(workspaces.map(\.id)).count == workspaces.count
            && Set(tabs.map(\.id)).count == tabs.count
            && Set(pages.map(\.id)).count == pages.count
            && tabs.contains { $0.id == selectedTab }
            && tabs.allSatisfy { tab in
                !tab.pages.isEmpty && tab.layout.paneIDs.count == tab.pages.count
                && Set(tab.layout.paneIDs) == Set(tab.pages.map(\.id))
                && tab.layout.paneIDs.contains(tab.focusedPane)
            }
    }
}

// @lat: [[architecture#Address handling]]
public enum AddressResolver {
    public static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "browse://start" || text == "browse://guide" { return URL(string: text) }
        if text.contains("://") {
            guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        let host = String(text.split(separator: "/").first ?? "")
        if !text.contains(where: \.isWhitespace) && (host.contains(".") || host == "localhost" || host.hasPrefix("localhost:")) {
            return URL(string: (host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1") ? "http://" : "https://") + text)
        }
        var url = URLComponents(string: "https://www.google.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: text)]
        return url.url
    }
}
