import Foundation

// @lat: [[lat.md/architecture/history#History suggestions]]
public enum FuzzyMatch {
    // Ordered-subsequence scoring inspired by editor quick-open search: prefer
    // consecutive runs and word/path boundaries, penalize gaps. Two DP rows
    // find the best alignment without exponential backtracking.
    static func score(_ query: String, in text: String) -> Int? {
        match(Word(query), in: Candidate(text), positions: false)?.score
    }

    /// UTF-16 ranges in the original displayed text, suitable for attributed strings.
    public static func ranges(_ query: String, in text: String) -> [NSRange] {
        var result: [NSRange] = []
        for word in query.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let literal = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                result.append(NSRange(literal, in: text))
            } else if let match = match(Word(word), in: Candidate(text, positions: true), positions: true),
                      match.score >= minimumScore(for: word) {
                result += match.ranges
            }
        }
        return Array(Set(result)).sorted { $0.location < $1.location }
    }

    struct Candidate: Sendable {
        let text: String
        fileprivate var ascii: [UInt8]?
        fileprivate var asciiLiteral: Data?
        fileprivate var target: [Character] = []
        fileprivate var bonuses: [UInt8] = []
        fileprivate var sourceRanges: [NSRange] = []

        init(_ text: String, positions: Bool = false) {
            self.text = text
            // ASCII byte positions are also UTF-16 positions. CRLF forms one
            // grapheme, so let the Character path handle it when present.
            if text.utf8.allSatisfy({ $0 < 128 && $0 != 13 }) {
                var units: [UInt8] = []
                var previousIsAlphanumeric = false
                var previousIsLowercase = false
                for byte in text.utf8.prefix(2048) {
                    let uppercase = (65...90).contains(byte)
                    let lowercase = (97...122).contains(byte)
                    let boundary: UInt8 = units.isEmpty ? 18 : (!previousIsAlphanumeric ? 14 : 0)
                    bonuses.append(uppercase && previousIsLowercase ? 12 : boundary)
                    if positions { sourceRanges.append(NSRange(location: units.count, length: 1)) }
                    units.append(uppercase ? byte + 32 : byte)
                    previousIsAlphanumeric = uppercase || lowercase || (48...57).contains(byte)
                    previousIsLowercase = lowercase
                }
                asciiLiteral = text.utf8.count > units.count ? Data(text.lowercased().utf8) : Data(units)
                ascii = units
                return
            }
            var offset = 0
            var before: Character?
            for character in text.prefix(2048) {
                let length = positions ? String(character).utf16.count : 0
                let range = NSRange(location: offset, length: length)
                let bonus: UInt8
                if let before {
                    if !before.isLetter && !before.isNumber { bonus = 14 }
                    else if before.isLowercase && character.isUppercase { bonus = 12 }
                    else { bonus = 0 }
                } else { bonus = 18 }
                let folded: String
                if let ascii = character.asciiValue {
                    folded = String(UnicodeScalar((65...90).contains(ascii) ? ascii + 32 : ascii))
                } else { folded = normalize(String(character)) }
                for (index, unit) in folded.enumerated() {
                    target.append(unit)
                    if positions { sourceRanges.append(range) }
                    bonuses.append(index == 0 ? bonus : 0)
                }
                offset += length
                before = character
            }
        }
    }

    private static func match(_ word: Word, in candidate: Candidate, positions: Bool) -> (score: Int, ranges: [NSRange])? {
        guard !word.pattern.isEmpty, word.pattern.count <= 128 else { return nil }
        if let target = candidate.ascii {
            guard let wanted = word.ascii else { return nil }
            return matchUnits(wanted, target, candidate, positions: positions)
        }
        return matchUnits(word.pattern, candidate.target, candidate, positions: positions)
    }

    private static func matchUnits<Unit: Equatable>(_ wanted: [Unit], _ target: [Unit], _ candidate: Candidate,
                                                    positions: Bool) -> (score: Int, ranges: [NSRange])? {
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
                let base = 10 + Int(candidate.bonuses[column])
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
        if !previous.isEmpty { previous[previous.count - 1] += 4 }
        guard let score = previous.max() else { return nil }
        var ranges: [NSRange] = []
        if positions, var column = previous.firstIndex(of: score) {
            for row in wanted.indices.reversed() {
                ranges.append(candidate.sourceRanges[column])
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

    struct Word {
        let text: String
        let pattern: [Character]
        let ascii: [UInt8]?
        let asciiData: Data?

        init(_ text: String) {
            self.text = text
            let normalized = normalize(text)
            pattern = Array(normalized)
            ascii = normalized.utf8.allSatisfy { $0 < 128 } ? Array(normalized.utf8) : nil
            asciiData = ascii.map { Data($0) }
        }

        func qualifiedScore(in candidate: Candidate) -> Int? {
            guard let value = match(self, in: candidate, positions: false)?.score else { return nil }
            if value >= pattern.count * 12 { return value }
            if let haystack = candidate.asciiLiteral, let needle = asciiData {
                return haystack.range(of: needle) == nil ? nil : value
            }
            return candidate.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? nil : value
        }
    }

    static func score(words: [Word], title: Candidate, url: Candidate) -> Int? {
        guard !words.isEmpty else { return nil }
        var total = 0
        for word in words {
            guard let best = [word.qualifiedScore(in: title), word.qualifiedScore(in: url)].compactMap({ $0 }).max() else { return nil }
            total += best
        }
        return total
    }
}
