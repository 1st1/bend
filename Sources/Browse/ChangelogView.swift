import SwiftUI
import AppKit

struct ChangelogView: View {
    var changelog: Changelog = .load()
    var installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    var openLink: (URL) -> Void

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(1, min(720, geometry.size.width - 56))
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text("What’s new in Bend").font(.system(size: 36, weight: .semibold, design: .rounded))
                        .padding(.bottom, 8)
                    if changelog.releases.isEmpty {
                        ContentUnavailableView("Release notes unavailable", systemImage: "doc.text", description: Text("This copy of Bend has no bundled release notes."))
                    }
                    ForEach(changelog.releases) { release in
                        VStack(alignment: .leading, spacing: 22) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 12) {
                                    Text(release.version).font(.system(size: 24, weight: .semibold, design: .rounded))
                                    if release.version == installedVersion {
                                        Text("Installed").font(.system(size: 11, weight: .medium))
                                            .padding(.horizontal, 9).padding(.vertical, 4)
                                            .background(.tint.opacity(0.12), in: Capsule()).foregroundStyle(.tint)
                                    }
                                }
                                if let date = release.date {
                                    Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                                        calendar: Calendar(identifier: .gregorian), timeZone: .gmt)))
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                            }
                            let document = Self.document(release.markdown)
                            let textWidth = max(1, contentWidth - 52)
                            ChangelogText(document: document)
                                .frame(width: textWidth, height: Self.height(document, width: textWidth), alignment: .topLeading)
                        }
                        .padding(26)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
                        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.07), lineWidth: 1) }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
        .environment(\.openURL, OpenURLAction { url in
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return .discarded }
            openLink(url)
            return .handled
        })
    }

    static func height(_ document: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: document)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    // Use the existing selectable Markdown renderer; scale its typography for a page.
    static func document(_ source: String) -> NSAttributedString {
        let original = ChatMarkdownDocument.render(source)
        let result = NSMutableAttributedString(attributedString: original)
        original.enumerateAttribute(.font, in: NSRange(location: 0, length: original.length)) { value, range, _ in
            if let font = value as? NSFont {
                result.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize + 2), range: range)
            }
        }
        return result
    }
}

// An AppKit container owns the text view's frame. NSTextView must not resize
// itself while SwiftUI is measuring a long document at a new pane width.
private struct ChangelogText: NSViewRepresentable {
    let document: NSAttributedString
    @Environment(\.openURL) private var openURL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.isVerticallyResizable = false; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width, .height]
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = context.coordinator
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        host.addSubview(text)
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        context.coordinator.open = { openURL($0) }
        guard let text = host.subviews.first as? NSTextView else { return }
        if !text.attributedString().isEqual(to: document) { text.textStorage?.setAttributedString(document) }
        text.frame = host.bounds
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: ((URL) -> Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) { open?(url) }
            return true
        }
    }
}
