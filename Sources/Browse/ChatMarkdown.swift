import SwiftUI
import AppKit
import Markdown

// @lat: [[lat.md/architecture/ai#Markdown messages]]
struct ChatMarkdown: View {
    let source: String
    var streaming = false

    var body: some View {
        ChatInlineText(text: AttributedString(), document: ChatMarkdownDocument.render(ChatStreamingMarkdown.visibleSource(source, streaming: streaming)))
    }
}

@MainActor enum ChatMarkdownDocument {
    static func render(
        _ source: String,
        inlineCodeBackground: NSColor = NSColor.white.withAlphaComponent(0.08),
        codeBlockBackground: NSColor = NSColor.white.withAlphaComponent(0.06),
        allowedLinkSchemes: Set<String> = ["https", "http", "mailto", "bend-pane"],
        requireLinkHost: Bool = false
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        func inline(_ node: any Markup) -> AttributedString {
            ChatMarkdownText.inline(node, allowedSchemes: allowedLinkSchemes, requireHost: requireLinkHost)
        }
        func paragraph(_ text: NSAttributedString, indent: CGFloat = 0, marker: String = "") {
            let value = NSMutableAttributedString()
            if !marker.isEmpty { value.append(NSAttributedString(string: marker + "\t", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])) }
            value.append(text)
            value.append(NSAttributedString(string: "\n"))
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3; style.paragraphSpacing = 9
            style.firstLineHeadIndent = indent
            style.headIndent = indent + (marker.isEmpty ? 0 : 18)
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
            style.defaultTabInterval = 110
            value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
            output.append(value)
        }
        func block(_ node: any Markup, depth: Int = 0, marker: String = "") {
            let indent = CGFloat(depth) * 18
            switch node {
            case let heading as Heading:
                paragraph(ChatInlineText.render(inline(heading), size: heading.level == 1 ? 19 : heading.level == 2 ? 16 : 14, heading: true, inlineCodeBackground: inlineCodeBackground), indent: indent, marker: marker)
            case let list as OrderedList:
                for (index, item) in list.children.enumerated() {
                    for (offset, child) in item.children.enumerated() { block(child, depth: depth + 1, marker: offset == 0 ? "\(Int(list.startIndex) + index)." : "") }
                }
            case let list as UnorderedList:
                for item in list.children {
                    let label = (item as? ListItem)?.checkbox.map { $0 == .checked ? "☑" : "☐" } ?? "•"
                    for (offset, child) in item.children.enumerated() { block(child, depth: depth + 1, marker: offset == 0 ? label : "") }
                }
            case let quote as BlockQuote:
                for child in quote.children { block(child, depth: depth + 1, marker: "│") }
            case let code as CodeBlock:
                paragraph(NSAttributedString(string: code.code.trimmingCharacters(in: .newlines), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor, .backgroundColor: codeBlockBackground]), indent: indent, marker: marker)
            case let table as Markdown.Table:
                for row in [table.head as any Markup] + Array(table.body.children) {
                    let line = NSMutableAttributedString()
                    for (index, cell) in row.children.enumerated() {
                        if index > 0 { line.append(NSAttributedString(string: "\t")) }
                        line.append(ChatInlineText.render(inline(cell), size: 12, heading: row is Markdown.Table.Head, inlineCodeBackground: inlineCodeBackground))
                    }
                    paragraph(line, indent: indent)
                }
            case is ThematicBreak: paragraph(NSAttributedString(string: "────────", attributes: [.foregroundColor: NSColor.separatorColor]))
            case let html as HTMLBlock: paragraph(NSAttributedString(string: html.rawHTML, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]))
            default: paragraph(ChatInlineText.render(inline(node), size: 13, heading: false, inlineCodeBackground: inlineCodeBackground), indent: indent, marker: marker)
            }
        }
        for child in Document(parsing: source).children { block(child) }
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return output
    }
}

enum ChatMarkdownText {
    static func inline(
        _ node: any Markup,
        allowedSchemes: Set<String> = ["https", "http", "mailto", "bend-pane"],
        requireHost: Bool = false
    ) -> AttributedString {
        if let text = node as? Markdown.Text { return AttributedString(text.string) }
        if node is SoftBreak { return AttributedString(" ") }
        if node is LineBreak { return AttributedString("\n") }
        if let html = node as? InlineHTML { return AttributedString(html.rawHTML) }
        if let code = node as? InlineCode {
            var result = AttributedString(code.code)
            result.font = .system(size: 12, design: .monospaced)
            result.backgroundColor = .white.opacity(0.08)
            return result
        }
        var result = node.children.reduce(into: AttributedString()) {
            $0 += inline($1, allowedSchemes: allowedSchemes, requireHost: requireHost)
        }
        if node is Strong || node is Emphasis {
            for run in result.runs {
                var intent = run.inlinePresentationIntent ?? []
                intent.insert(node is Strong ? .stronglyEmphasized : .emphasized)
                result[run.range].inlinePresentationIntent = intent
            }
        }
        if node is Strikethrough { result.strikethroughStyle = .single }
        if let link = node as? Markdown.Link, let destination = link.destination,
           let url = URL(string: destination),
           allowedSchemes.contains(url.scheme?.lowercased() ?? ""),
           !requireHost || url.host != nil {
            result.link = url
        }
        // Images remain descriptive text; rendering a response never fetches remote content.
        if node is Markdown.Image, result.characters.isEmpty { result = AttributedString("Image") }
        return result
    }
}

/// Keep incomplete Markdown destinations out of the visible streaming text.
/// Code spans and fences are literal; completed links keep their routing URL.
enum ChatStreamingMarkdown {
    static func visibleSource(_ source: String, streaming: Bool = true) -> String {
        let chars = Array(source)
        var output = ""; var index = 0; var codeTicks = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count {
                output.append(char); output.append(chars[index + 1]); index += 2; continue
            }
            if char == "`" {
                var end = index
                while end < chars.count && chars[end] == "`" { end += 1 }
                let count = end - index
                if codeTicks == 0 { codeTicks = count } else if codeTicks == count { codeTicks = 0 }
                output += String(chars[index..<end]); index = end; continue
            }
            guard codeTicks == 0, char == "[" else { output.append(char); index += 1; continue }
            var end = index + 1; var brackets = 1
            while end < chars.count {
                if chars[end] == "\\" { end += 2; continue }
                if chars[end] == "[" { brackets += 1 }
                if chars[end] == "]" { brackets -= 1; if brackets == 0 { break } }
                end += 1
            }
            if end >= chars.count {
                output += String(chars[(streaming ? index + 1 : index)...]); break
            }
            let label = String(chars[(index + 1)..<end])
            if end + 1 == chars.count { output += streaming ? label : String(chars[index...end]); break }
            if chars[end + 1] == "(" {
                var destinationEnd = end + 2; var parentheses = 1
                while destinationEnd < chars.count {
                    if chars[destinationEnd] == "\\" { destinationEnd += 2; continue }
                    if chars[destinationEnd] == "(" { parentheses += 1 }
                    if chars[destinationEnd] == ")" { parentheses -= 1; if parentheses == 0 { break } }
                    destinationEnd += 1
                }
                if destinationEnd >= chars.count { output += label; break }
                output += String(chars[index...destinationEnd]); index = destinationEnd + 1
            } else {
                output += String(chars[index...end]); index = end + 1
            }
        }
        return output
    }
}
