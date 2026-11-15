import Foundation

// @lat: [[lat.md/architecture/web-pages#Site domain labels]]
public enum SiteDisplayDomain {
    private static let rules: Set<String> = Set(PublicSuffixSnapshot.text.split(separator: "\n").compactMap { line in
        guard let rule = line.split(whereSeparator: \.isWhitespace).first, !rule.hasPrefix("//") else { return nil }
        let prefix = rule.hasPrefix("!") ? "!" : rule.hasPrefix("*.") ? "*." : ""
        let name = rule.dropFirst(prefix.count)
        guard let host = URL(string: "https://\(name)/")?.host else { return nil }
        return prefix + host.lowercased()
    })

    public static func label(for url: URL) -> String? {
        guard let original = url.host?.lowercased() else { return nil }
        let host = original.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // IP addresses and local names have no registrable-domain abbreviation.
        if host.contains(":") { return host.hasPrefix("[") ? host : "[\(host)]" }
        guard !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return original }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, !labels.contains("") else { return original }
        var suffixLength = 1
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if rules.contains("!" + suffix) {
                return labels.suffix(labels.count - index).joined(separator: ".")
            }
            if rules.contains(suffix) { suffixLength = max(suffixLength, labels.count - index) }
            if index > 0, rules.contains("*." + suffix) {
                suffixLength = max(suffixLength, labels.count - index + 1)
            }
        }
        return labels.suffix(min(labels.count, suffixLength + 1)).joined(separator: ".")
    }
}
