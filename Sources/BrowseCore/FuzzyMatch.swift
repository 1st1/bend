import Foundation

// @lat: [[lat.md/architecture/history#History suggestions]]
public enum FuzzyMatch {
    // Ordered-subsequence scoring inspired by editor quick-open search: prefer
    // consecutive runs and word/path boundaries, penalize gaps. Two DP rows
    // find the best alignment without exponential backtracking.
    static func score(_ query: String, in text: String) -> Int? {
        match(query, in: text, positions: false)?.score
    }

    /// UTF-16 ranges in the original displayed text, suitable for attributed strings.
    public static func ranges(_ query: String, in text: String) -> [NSRange] {
        var result: [NSRange] = []
        for word in query.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let literal = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                result.append(NSRange(literal, in: text))
            } else if let match = match(word, in: text, positions: true),
                      match.score >= minimumScore(for: word) {
                result += match.ranges
            }
        }
        return Array(Set(result)).sorted { $0.location < $1.location }
    }

    private static func match(_ query: String, in text: String, positions: Bool) -> (score: Int, ranges: [NSRange])? {
        let pattern = Array(normalize(query))
        guard !pattern.isEmpty, pattern.count <= 128 else { return nil }
        var target: [String] = []
        var sourceRanges: [NSRange] = []
        var bonuses: [Int] = []
        var offset = 0
        var before: Character?
        for character in text.prefix(2048) {
            let length = String(character).utf16.count
            let range = NSRange(location: offset, length: length)
            let bonus: Int
            if before == nil { bonus = 18 }
            else if !before!.isLetter && !before!.isNumber { bonus = 14 }
            else if before!.isLowercase && character.isUppercase { bonus = 12 }
            else { bonus = 0 }
            let folded: String
            if let ascii = character.asciiValue {
                folded = String(UnicodeScalar((65...90).contains(ascii) ? ascii + 32 : ascii))
            } else { folded = normalize(String(character)) }
            for (index, unit) in folded.enumerated() {
                target.append(String(unit))
                sourceRanges.append(range)
                bonuses.append(index == 0 ? bonus : 0)
            }
            offset += length
            before = character
        }
        let wanted = pattern.map(String.init)
        var next = 0
        for character in target where character == wanted[next] {
            next += 1
            if next == wanted.count { break }
        }
        guard next == wanted.count else { return nil }
        let impossible = Int.min / 4
        var previous = Array(repeating: impossible, count: target.count)
        var parents = positions ? Array(repeating: -1, count: wanted.count * target.count) : []
        for row in wanted.indices {
            var current = Array(repeating: impossible, count: target.count)
            var bestGap = impossible
            var bestGapIndex = -1
            for column in target.indices {
                if column >= 2, previous[column - 2] + column - 2 > bestGap {
                    bestGap = previous[column - 2] + column - 2
                    bestGapIndex = column - 2
                }
                guard target[column] == wanted[row] else { continue }
                let base = 10 + bonuses[column]
                if row == 0 {
                    current[column] = base - min(column, 30)
                } else {
                    let contiguous = column > 0 ? previous[column - 1] + 18 : impossible
                    let gap = bestGap - column - 7
                    current[column] = max(contiguous, gap) + base
                    if positions { parents[row * target.count + column] = contiguous >= gap ? column - 1 : bestGapIndex }
                }
            }
            previous = current
        }
        // Prefer a complete suffix over the same alignment with trailing text
        // (for example, /jit over /jit-lat). Apply it before recovering highlights.
        if !previous.isEmpty { previous[previous.count - 1] += 12 }
        guard let score = previous.max() else { return nil }
        var ranges: [NSRange] = []
        if positions, var column = previous.firstIndex(of: score) {
            for row in wanted.indices.reversed() {
                ranges.append(sourceRanges[column])
                if row > 0 { column = parents[row * target.count + column] }
            }
        }
        return (score, ranges.reversed())
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    // Require useful evidence for every word independently: a strong word must
    // not compensate for another word scattered across an unrelated title/URL.
    private static func minimumScore(for word: String) -> Int {
        normalize(word).count * 12
    }

    private static func qualifiedScore(_ word: String, in text: String) -> Int? {
        guard let value = score(word, in: text) else { return nil }
        if text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return value }
        return value >= minimumScore(for: word) ? value : nil
    }

    static func score(words: [String], title: String, url: String) -> Int? {
        guard !words.isEmpty, words.joined().count <= 128 else { return nil }
        var total = 0
        for word in words {
            guard let best = [qualifiedScore(word, in: title), qualifiedScore(word, in: url)].compactMap({ $0 }).max() else { return nil }
            total += best
        }
        return total
    }
}
