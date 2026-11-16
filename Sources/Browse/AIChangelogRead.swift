import Foundation
import AI

/// Uses the same bundled releases as bend://log, without exposing other native pages.
@MainActor struct AIChangelogRead {
    let id = UUID().uuidString
    let revision: UUID
    let chunks: [String]
    let version: String

    init(revision: UUID, changelog: Changelog, version: String) {
        self.revision = revision; self.version = version
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let text = "What's new in Bend\nInstalled Bend version: \(version)\n\n" + changelog.releases.map { release in
            "## \(release.version)" + (release.date.map { " — " + formatter.string(from: $0) } ?? "") + "\n" + release.markdown
        }.joined(separator: "\n\n")
        let scalars = Array(text.unicodeScalars)
        chunks = stride(from: 0, to: scalars.count, by: 24000).map { start in
            String(String.UnicodeScalarView(scalars[start..<min(start + 24000, scalars.count)]))
        }
    }

    func read(cursor: String?, pane: UUID) throws -> JSONValue {
        var index = 0
        if let cursor, !cursor.isEmpty {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == id, let value = Int(parts[1]),
                  value >= 0, value < chunks.count else {
                throw AIError.configuration("This read cursor expired. Read bend://log again without a cursor.")
            }
            index = value
        }
        let text = chunks[index]
        let more = index + 1 < chunks.count
        return .string(try JSONValue.object([
            "url": .string("bend://log"), "title": .string("What's New"), "text": .string(text),
            "bend_version": .string(version), "text_start": .integer(Int64(index * 24000 + 1)),
            "text_end": .integer(Int64(index * 24000 + text.unicodeScalars.count)),
            "has_more": .bool(more), "truncated": .bool(more), "text_complete": .bool(!more),
            "chunk": .integer(Int64(index + 1)), "total_chunks": .integer(Int64(chunks.count)),
            "next_cursor": more ? .string("\(id):\(index + 1)") : .null,
            "content_kind": .string("page_text_and_metadata"), "elements": .array([]), "references": .array([]),
            "citation": .string(ChatPageLinks.citation(pane: pane, address: "bend://log"))
        ]).jsonString())
    }
}
