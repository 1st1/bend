import Foundation

// @lat: [[lat.md/architecture/web-pages#Site domain labels]]
public enum SiteDisplayDomain {
    // Each sorted bucket contains fixed-width ASCII rules separated by LF.
    private static func containsRule(_ rule: String) -> Bool {
        var key = rule
        return key.withUTF8 { bytes in
            guard let bucket = PublicSuffixSnapshot.rows(ofLength: bytes.count),
                  let keyStart = bytes.baseAddress else { return false }
            return bucket.withUTF8Buffer { rows in
                guard let start = rows.baseAddress else { return false }
                let stride = bytes.count + 1
                var low = 0
                var high = (rows.count + 1) / stride
                while low < high {
                    let middle = (low + high) / 2
                    let order = memcmp(start + middle * stride, keyStart, bytes.count)
                    if order == 0 { return true }
                    if order < 0 { low = middle + 1 } else { high = middle }
                }
                return false
            }
        }
    }

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
            if containsRule("!" + suffix) {
                return labels.suffix(labels.count - index).joined(separator: ".")
            }
            if containsRule(suffix) { suffixLength = max(suffixLength, labels.count - index) }
            if index > 0, containsRule("*." + suffix) {
                suffixLength = max(suffixLength, labels.count - index + 1)
            }
        }
        return labels.suffix(min(labels.count, suffixLength + 1)).joined(separator: ".")
    }
}
