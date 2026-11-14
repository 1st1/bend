import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

struct ChatSidebar: View {
    @ObservedObject var chat: TabChat
    @ObservedObject private var settings = AISettings.shared
    var close: () -> Void
    var settingsAction: () -> Void
    @FocusState private var inputFocused: Bool
    @ViewState private var scrollFollow = ChatScrollFollow()

    init(chat: TabChat, close: @escaping () -> Void, settings: @escaping () -> Void) {
        self.chat = chat; self.close = close; self.settingsAction = settings
    }
    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(canStartNew: !chat.running && !chat.bubbles.isEmpty,
                       newChat: { chat.clear() }, close: close)
                .zIndex(1)
            if !settings.connected {
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("A conversation with your tab").font(.headline)
                    Text("Connect Vercel Gateway to ask questions and work across all panes in this tab.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Connect in Settings…", action: settingsAction).buttonStyle(.borderedProminent)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
                composer
            }
        }
        .frame(maxHeight: .infinity)
        .environment(\.openURL, OpenURLAction { url in
            Task { await chat.openLink(url) }
            return .handled
        })
        .task {
            await settings.restore()
            if chat.modelID.isEmpty { chat.modelID = settings.modelID }
            inputFocused = true
        }
        .onChange(of: settings.modelID) { _, model in if chat.modelID.isEmpty { chat.modelID = model } }
        .onChange(of: settings.connected) { _, connected in if !connected { chat.stop() } }
    }

    @ViewBuilder private var thinkingSummary: some View {
        if !chat.thinkingSummary.isEmpty {
            Text(chat.thinkingSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 4)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(chat.bubbles) { bubble in
                        if chat.thinkingSummaryBeforeBubbleID == bubble.id {
                            thinkingSummary
                        }
                        HStack {
                            if bubble.isUser { Spacer(minLength: 24) }
                            Group {
                                if bubble.kind != .text {
                                    ChatActivityRow(bubble: bubble, streaming: chat.running)
                                } else if bubble.isUser {
                                    Text(bubble.text).textSelection(.enabled).font(.system(size: 13))
                                } else {
                                    ChatMarkdown(source: bubble.text, streaming: chat.running)
                                }
                            }
                                .padding(.horizontal, bubble.kind == .text ? 12 : 4)
                                .padding(.vertical, bubble.kind == .text ? 12 : 2)
                                .background(bubble.kind != .text ? Color.clear : bubble.isUser ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            if !bubble.isUser { Spacer(minLength: 4) }
                        }.padding(.vertical, bubble.kind == .text ? 5 : 0)
                    }
                    if chat.thinkingSummaryBeforeBubbleID == nil {
                        thinkingSummary
                    }
                    if chat.running {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text(chat.status).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    }
                    if let error = chat.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(16)
            }
            .clipped()
            .contentShape(Rectangle())
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 40
            } action: { _, nearBottom in
                scrollFollow.geometry(nearBottom: nearBottom)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .tracking || phase == .decelerating {
                    scrollFollow.interaction(true)
                } else if phase == .idle, scrollFollow.interacting {
                    scrollFollow.interaction(false)
                }
            }
            .onChange(of: chat.bubbles.last?.text) { _, _ in
                if scrollFollow.shouldFollow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.thinkingSummary) { _, _ in
                if scrollFollow.shouldFollow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.bubbles.count) { _, _ in
                if scrollFollow.shouldFollow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.running) { _, _ in
                if scrollFollow.shouldFollow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !scrollFollow.following {
                    Button("Latest", systemImage: "arrow.down") {
                        scrollFollow.resume()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }.buttonStyle(.bordered).padding(12)
                }
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ask about this tab…", text: $chat.input, axis: .vertical)
                .lineLimit(2...7).textFieldStyle(.plain).focused($inputFocused)
                .onSubmit { chat.send() }
                .padding(.horizontal, 4)
                .padding(.top, 4)
            HStack {
                AIModelPicker(models: settings.models, selection: $chat.modelID)
                    .disabled(chat.running)
                    .frame(maxWidth: 235, alignment: .leading)
                Spacer()
                if chat.running {
                    Button("Stop", systemImage: "stop.fill") { chat.stop() }
                } else {
                    Button("Send", systemImage: "arrow.up") { chat.send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.modelID.isEmpty)
                }
            }.controlSize(.small)
        }
        .padding(10)
        // This standalone panel needs its own rounded top; the media body
        // extends glass above its bounds to join a separate header.
        .background(PaneChromeBackground(cornerRadius: 12))
        .background(WindowDragArea(excluded: true))
        .padding(.horizontal, Chrome.paneInset)
        .padding(.bottom, Chrome.paneInset)
    }
}

// The fixed header stays above native transcript views during scrolling.
struct ChatHeader: View {
    var canStartNew: Bool
    var newChat: () -> Void
    var close: () -> Void

    var body: some View {
        HStack(spacing: Chrome.sidebarControlSpacing) {
            Spacer(minLength: 0)
            ChatHeaderButton(symbol: "square.and.pencil", label: "Clear chat", visibleTitle: "Clear chat", controlWidth: 100, enabled: canStartNew, trailingInset: 44, action: newChat)
                .frame(width: 100, height: 28)
            ChatHeaderButton(symbol: "xmark", label: "Close chat", action: close)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ChromeButtonStyle(prominent: true))
        .padding(.leading, 18)
        .padding(.trailing, Chrome.sidebarHorizontalInset)
        .frame(height: 2 * Chrome.headerCenterY)
        .contentShape(Rectangle())
        .background(WindowDragArea(excluded: true))
    }
}

private struct ChatActivityRow: View {
    let bubble: ChatBubble
    var streaming = false
    var body: some View {
        DisclosureGroup {
            if bubble.kind == .reasoning {
                ChatMarkdown(source: bubble.text, streaming: streaming)
            } else if bubble.kind == .serverTool {
                VStack(alignment: .leading, spacing: 8) {
                    if !bubble.text.isEmpty { Text(bubble.text).font(.callout).textSelection(.enabled) }
                    ForEach(bubble.sources, id: \.url) { source in
                        if let url = URL(string: source.url), ["http", "https"].contains(url.scheme ?? "") {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title).lineLimit(2)
                                    Text(url.host ?? source.url).font(.caption).foregroundStyle(.secondary)
                                }
                            }.font(.callout)
                        }
                    }
                    if !bubble.detail.isEmpty { Text(bubble.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if bubble.state == "Completed" && bubble.sources.isEmpty && bubble.detail.isEmpty {
                        Text("No source details returned.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(bubble.kind == .serverTool ? "Search activity" : "Arguments").font(.caption).foregroundStyle(.secondary)
                    Text(bubble.text.isEmpty ? "{}" : bubble.text).font(.system(size: 11, design: .monospaced))
                    if !bubble.detail.isEmpty {
                        Text(bubble.detailTruncated ? "Result preview — model received the full chunk" : "Result").font(.caption).foregroundStyle(.secondary)
                        Text(bubble.detail).font(.system(size: 11, design: .monospaced))
                    }
                }.textSelection(.enabled)
            }
        } label: {
            HStack(spacing: 6) {
                Text(bubble.title).lineLimit(1).layoutPriority(1)
                if !bubble.argumentSummary.isEmpty {
                    Text(bubble.argumentSummary).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.tertiary).help(bubble.argumentSummary)
                }
                if bubble.kind == .tool || bubble.kind == .serverTool {
                    if bubble.state == "Running" {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: bubble.state == "Completed" ? "checkmark" : bubble.state == "Error" ? "exclamationmark.circle" : "stop.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(bubble.state == "Error" ? Color.orange : Color.secondary)
                            .help(bubble.state).accessibilityLabel(bubble.state)
                    }
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)

        }.disclosureGroupStyle(ChatActivityDisclosureStyle(isTool: bubble.kind != .reasoning))
    }
}

private struct ChatActivityDisclosureStyle: DisclosureGroupStyle {
    var isTool: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 8)
                    configuration.label
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, isTool ? 9 : 0)
                .padding(.vertical, isTool ? 5 : 2)
                .background {
                    if isTool { Capsule().fill(.primary.opacity(0.06)) }
                }
                .overlay {
                    if isTool { Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 13)
                    .padding(.bottom, 4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
