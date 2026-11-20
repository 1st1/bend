import AppKit
import SwiftUI
import Markdown
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Markdown rendering]]
@Test @MainActor func chatMarkdownRendering() throws {
    let document = Document(parsing: "**Bold** and *italic*, `code`, [source](https://example.com), [unsafe](javascript:alert(1))")
    let text = ChatMarkdownText.inline(document)
    #expect(String(text.characters) == "Bold and italic, code, source, unsafe")
    #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    #expect(text.runs.compactMap(\.link) == [URL(string: "https://example.com")!])
    let source = """
    # Summary
    ## What's happening
    - **First** item
      - Nested item
    - Second item

    3. Third
    4. Fourth

    > Quoted text

    ```swift
    let longLine = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
    ```

    | Model | Result |
    | --- | --- |
    | A | **Good** |

    - [x] Complete
    - [ ] Pending

    ---
    ![Descriptive image](https://example.com/image.png)
    """
    _ = NSApplication.shared
    for value in [source, "## Partial\n\n**still streaming", "```swift\nlet x = 1"] {
        let host = NSHostingView(rootView: ChatMarkdown(source: value).frame(width: 280))
        host.frame.size = NSSize(width: 280, height: 1000)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 281)
        #expect(host.fittingSize.height > 0)
        func texts(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(texts)
        }
        let views = texts(host)
        #expect(views.count == 1)
        let textView = try #require(views.first)
        textView.selectAll(nil)
        #expect(textView.selectedRange().length == textView.string.utf16.count)
        if value == source {
            #expect(textView.string.contains("Summary") && textView.string.contains("Second item"))
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Progressive Markdown]]
@Test @MainActor func progressiveChatMarkdown() {
    let source = "Read [this comment](bend-pane://B160C74D-C950-491F-91FD-5997CEB63F1A?url=https%3A%2F%2Fexample.com%23comment)."
    for length in 1...source.count {
        let partial = String(source.prefix(length))
        let visible = ChatMarkdownDocument.render(ChatStreamingMarkdown.visibleSource(partial)).string
        #expect(!visible.contains("B160C74D"))
        #expect(!visible.contains("bend-pane:"))
        #expect(!visible.contains("https%3A"))
    }
    #expect(ChatStreamingMarkdown.visibleSource("`[literal](bend-pane://id`") == "`[literal](bend-pane://id`")
    let storage = NSTextStorage(attributedString: ChatMarkdownDocument.render("First paragraph.\n\nSecond"))
    let final = ChatMarkdownDocument.render("First paragraph.\n\nSecond paragraph 🌍.")
    ChatInlineText.update(storage, with: final)
    let normalized = NSTextStorage(attributedString: final)
    normalized.fixAttributes(in: NSRange(location: 0, length: normalized.length))
    #expect(storage.isEqual(to: normalized))
    let linked = ChatMarkdownDocument.render(source)
    ChatInlineText.update(storage, with: linked)
    #expect(storage.isEqual(to: linked))
    #expect(linked.string == "Read this comment.")
}

// @lat: [[lat.md/tests/ai-tests#Math in responses]]
@Test @MainActor func chatMathRendering() throws {
    let sample = "[ \\text{nth square}=n^2 ]"
    for source in [sample, "\\(x_i^2\\)", "$\\frac{1}{2}$", "$$\n\\sqrt{x}\n$$", "\\[x^2\\]"] {
        for streaming in [true, false] {
            let rendered = ChatMarkdownDocument.response("🌍 " + source, streaming: streaming)
            #expect(rendered.string == "🌍 \u{fffc}")
            let attachment = try #require(rendered.attribute(.attachment, at: rendered.length - 1, effectiveRange: nil) as? NSTextAttachment)
            #expect(attachment.image?.accessibilityDescription == source)
            #expect(attachment.bounds.height > 0)
            let narrowLine = CGRect(x: 0, y: 0, width: 12, height: 30)
            let fitted = attachment.attachmentBounds(for: nil, proposedLineFragment: narrowLine, glyphPosition: .zero, characterIndex: 0)
            #expect(fitted.width <= narrowLine.width + 0.01)
        }
    }
    for literal in ["`$x$`", "~~~\n$x$\n~~~", "[ reference ]", "[ x^2 ](https://example.com)",
                    "Costs $5 and $10.", "still writing $x^", "\\$x$"] {
        let rendered = ChatMarkdownDocument.response(literal, streaming: false)
        #expect(!rendered.string.contains("\u{fffc}"))
    }
    let unsupported = "$\\notARealCommand{x}$"
    #expect(ChatMarkdownDocument.response(unsupported, streaming: false).string == unsupported)

    let host = NSHostingView(rootView: ChatMarkdown(source: "Result " + sample).frame(width: 280))
    host.layoutSubtreeIfNeeded()
    func textView(_ view: NSView) -> NSTextView? {
        (view as? NSTextView) ?? view.subviews.lazy.compactMap(textView).first
    }
    let view = try #require(textView(host))
    view.selectAll(nil)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(view.writeSelection(to: pasteboard, type: .string))
    #expect(pasteboard.string(forType: .string) == "Result " + sample)
}
