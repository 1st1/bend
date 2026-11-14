import AppKit
import SwiftUI

// Native selectable text explicitly forwards link activation to the chat router.
struct ChatInlineText: NSViewRepresentable {
    var text: AttributedString
    var size: CGFloat = 13
    var heading = false
    var document: NSAttributedString? = nil
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSTextView {
        let view = ChatLinkTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.open = { openURL($0) }
        let value = document ?? Self.render(text, size: size, heading: heading)
        if context.coordinator.rendered?.isEqual(to: value) != true {
            let selected = view.selectedRange()
            if let storage = view.textStorage { Self.update(storage, with: value, previous: context.coordinator.rendered) }
            context.coordinator.rendered = value
            let start = min(selected.location, value.length)
            view.setSelectedRange(NSRange(location: start, length: min(selected.length, value.length - start)))
        }
    }
    /// Preserve the unchanged attributed prefix so streaming edits only touch the tail.
    static func update(_ storage: NSTextStorage, with value: NSAttributedString, previous: NSAttributedString? = nil) {
        let original = previous ?? storage
        let oldText = original.string as NSString
        let newText = value.string as NSString
        let limit = min(storage.length, value.length)
        var prefix = 0
        while prefix < limit && oldText.character(at: prefix) == newText.character(at: prefix) { prefix += 1 }
        var position = 0
        while position < prefix {
            var oldRange = NSRange(); var newRange = NSRange()
            let oldAttributes = original.attributes(at: position, effectiveRange: &oldRange)
            let newAttributes = value.attributes(at: position, effectiveRange: &newRange)
            if !NSDictionary(dictionary: oldAttributes).isEqual(to: newAttributes) { prefix = position; break }
            position = min(prefix, min(NSMaxRange(oldRange), NSMaxRange(newRange)))
        }
        if prefix > 0 {
            let range = newText.rangeOfComposedCharacterSequence(at: prefix - 1)
            if NSMaxRange(range) > prefix { prefix = range.location }
        }
        guard prefix < storage.length || prefix < value.length else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: prefix, length: storage.length - prefix),
                                  with: value.attributedSubstring(from: NSRange(location: prefix, length: value.length - prefix)))
        storage.endEditing()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 280)
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
    static func render(_ source: AttributedString, size: CGFloat, heading: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in source.runs {
            let value = String(source[run.range].characters)
            var font = run.font != nil ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                : NSFont.systemFont(ofSize: size, weight: heading ? .semibold : .regular)
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if run.inlinePresentationIntent?.contains(.emphasized) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor,
                                                              .paragraphStyle: paragraph]
            if let link = run.link { attributes[.link] = link }
            if run.strikethroughStyle != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.font != nil { attributes[.backgroundColor] = NSColor.white.withAlphaComponent(0.08) }
            output.append(NSAttributedString(string: value, attributes: attributes))
        }
        return output
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var rendered: NSAttributedString?
        var open: ((URL) -> Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return true }
            AIDiagnostics.shared.record("link.nativeActivated", fields: ["scheme": url.scheme ?? "", "host": url.host ?? ""])
            open?(url)
            return true
        }
    }
}

private final class ChatLinkTextView: NSTextView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// @lat: [[lat.md/architecture/ai#Transcript scrolling]]
struct ChatScrollFollow {
    private(set) var following = true
    private(set) var interacting = false
    private(set) var nearBottom = true
    var shouldFollow: Bool { following && !interacting }
    mutating func geometry(nearBottom: Bool) {
        self.nearBottom = nearBottom
        if interacting { following = nearBottom }
    }
    mutating func interaction(_ active: Bool) {
        interacting = active
        if !active { following = nearBottom }
    }
    mutating func resume() { following = true }
}
