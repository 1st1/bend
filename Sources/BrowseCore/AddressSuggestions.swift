import Foundation

/// The rows and default selection for a location edit, before UI-specific selection restoration.
public struct AddressSuggestions {
    public struct Row {
        public let title: String
        public let detail: String
        public let address: String
        public let history: HistorySuggestion?
        public let score: HistoryMatchScore?
    }

    public let rows: [Row]
    public let selected: Int
    public let completion: String?

    public init(history: BrowsingHistory, typedQuery: String, showingFrequent: Bool = false,
                allowAutofill: Bool, searchEngine: SearchEngine, customSearchEngine: CustomSearchEngine?) {
        let query = showingFrequent ? "" : typedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestions = history.rankedSuggestions(for: query)
        var rows = suggestions.map { hit in
            let item = hit.suggestion
            return Row(title: item.title, detail: item.displayURL, address: item.url, history: item, score: hit.score)
        }
        var selected = -1
        var completion: String?
        if let intent = AddressResolver.classify(query),
           intent.destination(searchEngine: searchEngine, customSearchEngine: customSearchEngine, query: query) != nil {
            let action: Row
            var promote = false
            switch intent {
            case .visit:
                action = Row(title: "Visit \(query)", detail: "Open address", address: query, history: nil, score: nil)
            case .search(let prefersDirectAction):
                let name = searchEngine.displayName(custom: customSearchEngine)
                action = Row(title: "Search for “\(query)”", detail: "Search with \(name)", address: query, history: nil, score: nil)
                if allowAutofill, !prefersDirectAction, let first = suggestions.first?.suggestion {
                    completion = first.completion(for: typedQuery)
                    promote = first.isFuzzyMatch || first.isPathMatch || completion != nil
                }
            }
            rows.insert(action, at: promote ? 1 : 0)
            selected = 0
        }
        self.rows = rows
        self.selected = selected
        self.completion = completion
    }
}
