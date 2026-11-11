import Foundation

public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }
public enum CommandClickDestination: String, Codable, Sendable { case newPane, dedicatedPane, newTab }
public enum LinkOpenDestination: String, Codable, Sendable { case newTab, newPane, newWindow }

// @lat: [[architecture#Tiling model]]
public indirect enum PaneLayout: Codable, Equatable, Sendable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, fraction: Double, first: PaneLayout, second: PaneLayout, isAutomatic: Bool? = nil)

    public var paneIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, _, let first, let second, _): first.paneIDs + second.paneIDs
        }
    }

    public func splitting(_ target: UUID, with newID: UUID, axis: SplitAxis) -> Self {
        switch self {
        case .pane(let id):
            return id == target ? .split(id: UUID(), axis: axis, fraction: 0.5, first: self, second: .pane(newID)) : self
        case .split(let id, let direction, let fraction, let first, let second, let automatic):
            return .split(id: id, axis: direction, fraction: fraction,
                          first: first.splitting(target, with: newID, axis: axis),
                          second: second.splitting(target, with: newID, axis: axis), isAutomatic: automatic)
        }
    }

    public func removing(_ target: UUID) -> Self? {
        switch self {
        case .pane(let id): return id == target ? nil : self
        case .split(let id, let axis, let fraction, let first, let second, let automatic):
            let a = first.removing(target), b = second.removing(target)
            if let a, let b { return .split(id: id, axis: axis, fraction: fraction, first: a, second: b, isAutomatic: automatic) }
            return a ?? b
        }
    }

    // @lat: [[architecture#Pane drag and drop]]
    public func moving(_ source: UUID, beside target: UUID, edge: PaneDropEdge) -> Self? {
        guard source != target, paneIDs.contains(source), paneIDs.contains(target),
              let remaining = removing(source) else { return nil }
        return remaining.inserting(source, beside: target, edge: edge)
    }

    public func inserting(_ source: UUID, beside target: UUID, edge: PaneDropEdge) -> Self? {
        guard !paneIDs.contains(source), paneIDs.contains(target) else { return nil }
        return replacingNode(target) { current in
            .split(id: UUID(), axis: edge.axis, fraction: 0.5,
                   first: edge.isBefore ? .pane(source) : current,
                   second: edge.isBefore ? current : .pane(source))
        }
    }

    public func inserting(_ source: Self, beside target: UUID, edge: PaneDropEdge) -> Self? {
        guard paneIDs.contains(target), Set(paneIDs).isDisjoint(with: source.paneIDs) else { return nil }
        return replacingNode(target) { current in
            .split(id: UUID(), axis: edge.axis, fraction: 0.5,
                   first: edge.isBefore ? source : current,
                   second: edge.isBefore ? current : source)
        }
    }

    // @lat: [[architecture#Automatic pane sizing]]
    public var usesAutomaticSizing: Bool {
        guard case .split(_, _, let fraction, _, _, let automatic) = self else { return false }
        // Older sessions did not record resize intent. Preserve unequal ratios.
        return automatic ?? (fraction == 0.5)
    }

    public func automaticUnits(along axis: SplitAxis) -> Int {
        guard case .split(_, let direction, _, let first, let second, _) = self,
              direction == axis, usesAutomaticSizing else { return 1 }
        return first.automaticUnits(along: axis) + second.automaticUnits(along: axis)
    }

    public func resizing(_ target: UUID, to value: Double, geometry: PaneGeometry? = nil) -> Self {
        guard value.isFinite, nodeIDs.contains(target), !paneIDs.contains(target) else { return self }
        let fractions = Dictionary(uniqueKeysWithValues: (geometry?.dividers ?? []).map {
            ($0.id, Double($0.firstLength / $0.available))
        })
        return fixingSizes(target, to: value, fractions: fractions)
    }

    private func fixingSizes(_ target: UUID, to value: Double, fractions: [UUID: Double]) -> Self {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let fraction, let first, let second, _):
            let units = first.automaticUnits(along: axis)
            let automaticFraction = Double(units) / Double(units + second.automaticUnits(along: axis))
            let retained = usesAutomaticSizing ? (fractions[id] ?? automaticFraction) : fraction
            return .split(id: id, axis: axis, fraction: id == target ? min(0.85, max(0.15, value)) : retained,
                          first: first.fixingSizes(target, to: value, fractions: fractions),
                          second: second.fixingSizes(target, to: value, fractions: fractions), isAutomatic: false)
        }
    }

    // Restore beside the nearest surviving sibling, preserving subsequent edits
    // to the live layout instead of replacing the entire tree with a snapshot.
    public func restoring(_ target: UUID, from previous: Self) -> Self? {
        guard !paneIDs.contains(target) else { return nil }
        if previous.removing(target) == self { return previous }
        guard case .split(_, let axis, let fraction, let first, let second, let automatic) = previous else { return nil }
        let wasFirst = first.paneIDs.contains(target)
        guard wasFirst || second.paneIDs.contains(target) else { return nil }
        if let nested = restoring(target, from: wasFirst ? first : second) { return nested }
        let sibling = wasFirst ? second : first
        for anchor in sibling.nodeIDs {
            if let restored = replacingNode(anchor, transform: { current in
                .split(id: UUID(), axis: axis, fraction: fraction,
                    first: wasFirst ? .pane(target) : current,
                    second: wasFirst ? current : .pane(target), isAutomatic: automatic)
            }) { return restored }
        }
        return nil
    }

    private var nodeIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(let id, _, _, let first, let second, _): [id] + first.nodeIDs + second.nodeIDs
        }
    }

    private func replacingNode(_ target: UUID, transform: (Self) -> Self) -> Self? {
        switch self {
        case .pane(let id): return id == target ? transform(self) : nil
        case .split(let id, let axis, let fraction, let first, let second, let automatic):
            if id == target { return transform(self) }
            if let next = first.replacingNode(target, transform: transform) {
                return .split(id: id, axis: axis, fraction: fraction, first: next, second: second, isAutomatic: automatic)
            }
            if let next = second.replacingNode(target, transform: transform) {
                return .split(id: id, axis: axis, fraction: fraction, first: first, second: next, isAutomatic: automatic)
            }
            return nil
        }
    }
}

public struct Page: Codable, Identifiable, Sendable {
    public var id: UUID
    public var address: String
    public var isPinned: Bool
    public var favoriteID: UUID?
    public init(address: String = "browse://start", isPinned: Bool = false) {
        id = UUID(); self.address = address; self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey { case id, address, isPinned, favoriteID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        address = try values.decode(String.self, forKey: .address)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        favoriteID = try values.decodeIfPresent(UUID.self, forKey: .favoriteID)
    }
}

public struct BrowserTab: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var layout: PaneLayout
    public var pages: [Page]
    public var focusedPane: UUID
    public var commandClickPaneID: UUID?
    public var isPinned: Bool { pages.contains { $0.isPinned } }

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
        guard pages.first(where: { $0.id == id })?.isPinned == false else { return }
        removePaneForTransfer(id)
    }

    // Structural removal for moves: the destination retains the page and its pin.
    public mutating func removePaneForTransfer(_ id: UUID) {
        guard let next = layout.removing(id) else { return }
        layout = next; pages.removeAll { $0.id == id }
        if commandClickPaneID == id || pages.count == 1 { commandClickPaneID = nil }
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

public enum SidebarSide: String, Codable, CaseIterable, Sendable {
    case left, right
}

// @lat: [[architecture#Session restoration]]
public struct BrowserSession: Codable, Sendable {
    public var workspaces: [Workspace]
    public var selectedTab: UUID
    public var sidebarWidth: Double?
    public var sidebarSide: SidebarSide?
    public var commandClickOpensNewTab: Bool?
    public var commandClickDestination: CommandClickDestination?
    public var commandShiftClickDestination: LinkOpenDestination?
    public var optionClickDestination: LinkOpenDestination?
    public var inactivePaneDimAmount: Double?
    public var windowGlass: GlassAppearance?
    public var paneHeaderGlass: GlassAppearance?
    public var paneHeaderTopRimClipping: Double?
    public var paneHeaderBottomRimClipping: Double?
    public var paneHighlight: PaneHighlight?
    public var downloadDirectory: String?
    public var favorites: [SidebarFavorite]?

    public init() {
        let initial = BrowserTab(title: "Start here", pages: [Page(), Page(address: "browse://guide")])
        workspaces = [Workspace(name: "Tabs", tabs: [initial])]
        selectedTab = initial.id
    }

    // Moving a pane is atomic: its identity and address survive, and no closed
    // item is created. Keep an empty source workspace usable with a blank tab.
    public mutating func transferPane(_ source: UUID, from sourceTabID: UUID,
                                     beside target: UUID, in targetTabID: UUID, edge: PaneDropEdge) -> Bool {
        guard sourceTabID != targetTabID,
              let sourceTab = workspaces.flatMap(\.tabs).first(where: { $0.id == sourceTabID }),
              let page = sourceTab.pages.first(where: { $0.id == source }),
              let wi = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == targetTabID } }),
              let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == targetTabID }),
              let layout = workspaces[wi].tabs[ti].layout.inserting(source, beside: target, edge: edge) else { return false }
        workspaces[wi].tabs[ti].layout = layout
        workspaces[wi].tabs[ti].pages.append(page)
        workspaces[wi].tabs[ti].focusedPane = source
        removeTransferredPane(source, from: sourceTabID)
        selectedTab = targetTabID
        return true
    }

    public mutating func detachPane(_ source: UUID, from sourceTabID: UUID, into workspaceID: UUID, title: String) -> UUID? {
        guard let sourceTab = workspaces.flatMap(\.tabs).first(where: { $0.id == sourceTabID }),
              let page = sourceTab.pages.first(where: { $0.id == source }),
              let wi = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        // A single-pane tab dropped into its existing workspace is already detached.
        guard sourceTab.pages.count > 1 || !workspaces[wi].tabs.contains(where: { $0.id == sourceTabID }) else { return nil }
        let tab = BrowserTab(title: title, pages: [page])
        workspaces[wi].tabs.append(tab)
        removeTransferredPane(source, from: sourceTabID)
        selectedTab = tab.id
        return tab.id
    }

    // Keep the source split tree intact, either beside a destination pane or
    // alongside the entire destination layout for a direct sidebar drop.
    public mutating func joinTabs(_ sourceID: UUID, into destinationID: UUID,
                                  beside target: UUID? = nil, edge: PaneDropEdge = .right) -> Bool {
        guard sourceID != destinationID,
              let source = workspaces.flatMap(\.tabs).first(where: { $0.id == sourceID }),
              let sourceWorkspace = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == sourceID } }),
              let wi = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == destinationID } }),
              let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == destinationID }) else { return false }
        let destination = workspaces[wi].tabs[ti]
        let layout: PaneLayout
        if let target {
            guard let inserted = destination.layout.inserting(source.layout, beside: target, edge: edge) else { return false }
            layout = inserted
        } else {
            layout = .split(id: UUID(), axis: edge.axis, fraction: 0.5,
                            first: edge.isBefore ? source.layout : destination.layout,
                            second: edge.isBefore ? destination.layout : source.layout)
        }
        workspaces[wi].tabs[ti].layout = layout
        workspaces[wi].tabs[ti].pages.append(contentsOf: source.pages)
        if workspaces[wi].tabs[ti].commandClickPaneID == nil {
            workspaces[wi].tabs[ti].commandClickPaneID = source.commandClickPaneID
        }
        workspaces[wi].tabs[ti].focusedPane = source.focusedPane
        workspaces[sourceWorkspace].tabs.removeAll { $0.id == sourceID }
        if workspaces[sourceWorkspace].tabs.isEmpty { workspaces[sourceWorkspace].tabs.append(BrowserTab()) }
        selectedTab = destinationID
        return true
    }

    private mutating func removeTransferredPane(_ source: UUID, from tabID: UUID) {
        guard let wi = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let ti = workspaces[wi].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if workspaces[wi].tabs[ti].pages.count > 1 {
            workspaces[wi].tabs[ti].removePaneForTransfer(source)
        } else {
            workspaces[wi].tabs.remove(at: ti)
            if workspaces[wi].tabs.isEmpty { workspaces[wi].tabs.append(BrowserTab()) }
        }
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
        if ["browse://start", "browse://guide", "browse://history"].contains(text) { return URL(string: text) }
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
