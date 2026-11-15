import AppKit
import SwiftUI

// @lat: [[lat.md/architecture/ai#Chat composer]]
struct ChatComposerInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var canSend: Bool
    var send: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let input = ChatComposerTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        input.isRichText = false
        input.drawsBackground = false
        input.font = .systemFont(ofSize: 13)
        input.textColor = .labelColor
        input.insertionPointColor = .labelColor
        input.textContainerInset = NSSize(width: 4, height: 4)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = true
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.allowsUndo = true
        input.setAccessibilityLabel("Chat message")
        input.delegate = context.coordinator
        scroll.documentView = input
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? ChatComposerTextView else { return }
        input.canSend = canSend
        input.send = send
        input.wantsFocus = focused
        if input.string != text {
            let selection = input.selectedRange()
            input.string = text
            input.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        input.needsDisplay = true
        input.requestFocus()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let input = nsView.documentView as? NSTextView, let container = input.textContainer,
              let layout = input.layoutManager, let font = input.font else { return nil }
        let width = max(1, proposal.width ?? 280)
        container.containerSize = NSSize(width: max(1, width - 8), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: font)
        let height = max(layout.usedRect(for: container).height, layout.extraLineFragmentRect.maxY) + 8
        return CGSize(width: width, height: min(max(height, line * 2 + 8), line * 7 + 8))
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerInput
        init(_ parent: ChatComposerInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let input = notification.object as? NSTextView else { return }
            parent.text = input.string
            input.needsDisplay = true
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }
    }
}

final class ChatComposerTextView: NSTextView {
    var canSend = false
    var send: () -> Void = {}
    var wantsFocus = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command {
            if canSend && !hasMarkedText() { send() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus()
    }
    func requestFocus() {
        guard wantsFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, !self.isHiddenOrHasHiddenAncestor,
                  let window = self.window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("Ask about this tab…" as NSString).draw(at: NSPoint(x: 4, y: 4), withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }
}
