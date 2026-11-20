import AppKit
import Markdown
import SwiftMath

/// Protect TeX from Markdown escaping and emphasis parsing until the surrounding prose is laid out.
@MainActor struct ChatMath {
    private struct Formula {
        let source: String
        let latex: String
        let display: Bool
    }

    // Each capture contains the TeX body, in delimiter order.
    private static let delimiters: NSRegularExpression = {
        let alternatives = [
            "\\$\\$([\\s\\S]+?)\\$\\$",
            "\\\\\\[([\\s\\S]+?)\\\\\\]",
            "\\\\\\(([^\\n]+?)\\\\\\)",
            "\\$(?![\\s$])((?:\\\\.|[^\\\\$\\n])+?)(?<!\\s)\\$(?![\\d$])",
            "\\[\\s+([^\\[\\]\\\\^_=]*[\\\\^_=][^\\[\\]]*?)\\s+\\](?![\\[(])",
        ].joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![\\\\$])(?:" + alternatives + ")")
    }()
    private static let cache: NSCache<NSString, NSTextAttachment> = {
        let cache = NSCache<NSString, NSTextAttachment>()
        cache.countLimit = 256
        return cache
    }()
    private let prefix = "BendMath" + UUID().uuidString
    private var formulas = [Formula]()
    private(set) var markdown: String

    init(_ source: String) {
        markdown = source
        guard source.contains("$") || source.contains("\\") || source.contains("[ ") else { return }
        let bytes = source.utf8
        var lines = [bytes.startIndex]
        for index in bytes.indices where bytes[index] == 10 { lines.append(bytes.index(after: index)) }
        func index(_ location: SourceLocation) -> String.Index? {
            guard lines.indices.contains(location.line - 1), location.column > 0 else { return nil }
            return bytes.index(lines[location.line - 1], offsetBy: location.column - 1, limitedBy: bytes.endIndex)
        }
        func range(_ node: any Markup) -> NSRange? {
            guard let span = node.range, let start = index(span.lowerBound), let end = index(span.upperBound),
                  start <= end else { return nil }
            return NSRange(start..<end, in: source)
        }

        // Match within prose blocks only. Code, HTML, and link destinations have their own grammar.
        var ranges = [NSRange]()
        func visit(_ node: any Markup) {
            switch node {
            case is Paragraph, is Heading, is Markdown.Table.Cell:
                guard let bounds = range(node) else { return }
                var cursor = bounds.location
                func skipLiterals(_ child: any Markup) {
                    switch child {
                    case is InlineCode, is InlineHTML, is Markdown.Link, is Markdown.Image:
                        guard let literal = range(child), NSLocationInRange(literal.location, bounds) else { return }
                        if literal.location > cursor { ranges.append(NSRange(location: cursor, length: literal.location - cursor)) }
                        cursor = max(cursor, NSMaxRange(literal))
                    default:
                        for nested in child.children { skipLiterals(nested) }
                    }
                }
                skipLiterals(node)
                if cursor < NSMaxRange(bounds) { ranges.append(NSRange(location: cursor, length: NSMaxRange(bounds) - cursor)) }
            default:
                for child in node.children { visit(child) }
            }
        }
        visit(Document(parsing: source))
        let original = source as NSString
        let result = NSMutableString(string: source)
        for range in ranges.reversed() {
            for match in Self.delimiters.matches(in: source, range: range).reversed() {
                guard let group = (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
                let latex = original.substring(with: match.range(at: group)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !latex.isEmpty else { continue }
                let token = prefix + "X\(formulas.count)Z"
                formulas.append(Formula(source: original.substring(with: match.range), latex: latex, display: [1, 2, 5].contains(group)))
                result.replaceCharacters(in: match.range, with: token)
            }
        }
        markdown = result as String
    }

    func typeset(in text: NSMutableAttributedString) {
        guard !formulas.isEmpty else { return }
        let tokens = try! NSRegularExpression(pattern: prefix + "X(\\d+)Z")
        let string = text.string as NSString
        for match in tokens.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            let formula = formulas[Int(string.substring(with: match.range(at: 1)))!]
            let attrs = text.attributes(at: match.range.location, effectiveRange: nil)
            let size = (attrs[.font] as? NSFont)?.pointSize ?? 13
            if let attachment = Self.attachment(for: formula, size: size) {
                let value = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                value.addAttributes(attrs, range: NSRange(location: 0, length: value.length))
                text.replaceCharacters(in: match.range, with: value)
            } else {
                text.replaceCharacters(in: match.range, with: formula.source)
            }
        }
    }

    private static func attachment(for formula: Formula, size: CGFloat) -> NSTextAttachment? {
        let key = "\(size) \(formula.source)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        // SwiftMath lacks these amsmath commands. Translate whole TeX control sequences
        // for display, keeping the original spelling on the attachment for copying.
        let latex = formula.latex.replacing(/\\(?:[A-Za-z]+|.)/) { match in
            switch match.output {
            case "\\operatorname": "\\mathrm"
            case "\\tfrac", "\\dfrac": "\\frac"
            default: String(match.output)
            }
        }
        var math = MathImage(latex: latex, fontSize: formula.display ? size + 2 : size,
                             textColor: .labelColor, labelMode: formula.display ? .display : .text)
        let (_, rendered, layout) = math.asImage()
        guard let image = rendered, let metrics = layout, image.size.width > 0, image.size.height > 0 else { return nil }
        image.accessibilityDescription = formula.source
        let attachment = FormulaAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: CGPoint(x: 0, y: -metrics.descent), size: image.size)
        cache.setObject(attachment, forKey: key)
        return attachment
    }
}

// TextKit proposes a new line for an attachment that cannot fit beside the preceding prose.
// Scale only formulas wider than the full line, including their baseline offset.
private final class FormulaAttachment: NSTextAttachment {
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment line: CGRect,
                                   glyphPosition position: CGPoint, characterIndex: Int) -> CGRect {
        guard line.width > 0, bounds.width > line.width else { return bounds }
        let scale = line.width / bounds.width
        return bounds.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}
