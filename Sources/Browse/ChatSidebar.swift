import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

struct ChatSidebar: View {
    @ObservedObject var chat: TabChat
    @ObservedObject private var settings: AISettings
    var panelWidth: CGFloat = BrowserStore.defaultChatWidth
    var onLeft = false
    var close: () -> Void
    var settingsAction: () -> Void
    @ViewState private var inputFocused = false
    @ViewState private var scrollFollow = ChatScrollFollow()
    @ViewState private var composerHeight: CGFloat = 110

    init(chat: TabChat, panelWidth: CGFloat = BrowserStore.defaultChatWidth, onLeft: Bool = false,
         aiSettings: AISettings = .shared, close: @escaping () -> Void, settings: @escaping () -> Void) {
        self.panelWidth = panelWidth; self.onLeft = onLeft; self.chat = chat; self.close = close; self.settingsAction = settings
        _settings = ObservedObject(wrappedValue: aiSettings)
    }
    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(onLeft: onLeft, panelWidth: panelWidth, canStartNew: !chat.running && !chat.bubbles.isEmpty,
                       newChat: { chat.clear() }, close: close)
                .zIndex(1)
            if !settings.connected && chat.bubbles.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("A conversation with your tab").font(.headline)
                    Text("Log in to an AI account to ask questions and work across all panes in this tab.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Connect in Settings…", action: settingsAction).buttonStyle(.borderedProminent)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .bottom) {
                    transcript
                    composer
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                }.clipped()
            }
        }
        .frame(maxHeight: .infinity)
        .environment(\.openURL, OpenURLAction { url in
            Task { await chat.openLink(url) }
            return .handled
        })
        .task {
            inputFocused = true
            if chat.modelID.isEmpty { chat.modelID = settings.modelID }
            await settings.restore()
            if chat.modelID.isEmpty { chat.modelID = settings.modelID }
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
                            if bubble.isUser { Spacer(minLength: 0) }
                            Group {
                                if bubble.kind != .text {
                                    ChatActivityRow(bubble: bubble, streaming: chat.running,
                                        approval: chat.approvalBubbleID == bubble.id ? chat.actionApproval.pending : nil,
                                        approve: { chat.approveAction($0) }, decline: { chat.declineAction($0) })
                                } else if bubble.isUser {
                                    Text(bubble.text).textSelection(.enabled).font(.system(size: 13))
                                } else {
                                    ChatMarkdown(source: bubble.text, streaming: chat.running)
                                }
                            }
                                .padding(.horizontal, bubble.kind == .text ? 12 : 4)
                                .padding(.vertical, bubble.kind == .text ? 12 : 2)
                                .background(bubble.kind != .text ? Color.clear : bubble.isUser ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                                .frame(maxWidth: bubble.kind == .text ? max(0, panelWidth - 32) * 0.9 : nil,
                                       alignment: bubble.isUser ? .trailing : .leading)
                            if !bubble.isUser { Spacer(minLength: 4) }
                        }.padding(.vertical, bubble.kind == .text ? 5 : 0)
                    }
                    if chat.thinkingSummaryBeforeBubbleID == nil {
                        thinkingSummary
                    }
                    if chat.running {
                        HStack(spacing: 8) {
                            if chat.actionApproval.pending == nil { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "hand.tap").foregroundStyle(.secondary) }
                            Text(chat.actionApproval.pending == nil ? chat.status : "Waiting for your approval")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    }
                    if let error = chat.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    // The scroll target includes the overlay clearance, so Latest
                    // and streaming keep the final message above the composer.
                    Color.clear.frame(height: composerHeight).id("bottom")
                }.padding(16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                        if scrollFollow.shouldFollow { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
            }
            .clipped()
            .contentMargins(.bottom, composerHeight, for: .scrollIndicators)
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
            .onChange(of: chat.actionApproval.pending?.id) { _, _ in
                if scrollFollow.shouldFollow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !scrollFollow.following {
                    Button("Latest", systemImage: "arrow.down") {
                        scrollFollow.resume()
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .font(.system(size: 10.4, weight: .medium))
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .padding(12)
                    .padding(.bottom, composerHeight)
                }
            }
        }
    }
    private var canSend: Bool {
        !chat.running && !chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.modelID.isEmpty
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChatComposerInput(text: $chat.input, focused: $inputFocused, canSend: canSend,
                              prompts: chat.bubbles.filter(\.isUser).map(\.text)) { chat.send() }
            HStack {
                AIModelPicker(models: settings.models, selection: $chat.modelID)
                    .disabled(chat.running)
                    .frame(maxWidth: 235, alignment: .leading)
                Spacer()
                if chat.running {
                    Button("Stop", systemImage: "stop.fill") { chat.stop() }
                        .help("Stop response (Esc)")
                } else {
                    Button("Send", systemImage: "arrow.up") { chat.send() }
                        .disabled(!canSend)
                        .help("Send message (⌘Return)")
                }
            }.controlSize(.small)
        }
        .padding(10)
        .background {
            ChatComposerGlass()
                .overlay {
                    RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.45))
                        .allowsHitTesting(false)
                }
        }
        .background(WindowDragArea(excluded: true))
        // The adjacent pane canvas supplies the inner gap.
        .padding(EdgeInsets(top: 0, leading: onLeft ? Chrome.paneInset : 0,
                            bottom: Chrome.paneInset, trailing: onLeft ? 0 : Chrome.paneInset))
    }
}

// The fixed header stays above native transcript views during scrolling.
struct ChatHeader: View {
    static func height(onLeft: Bool, panelWidth: CGFloat) -> CGFloat {
        2 * Chrome.headerCenterY + (onLeft && panelWidth < 330 ? 32 : 0)
    }
    var onLeft = false
    var panelWidth: CGFloat = BrowserStore.defaultChatWidth
    private var buttonWidth: CGFloat { panelWidth < 240 ? 86 : 100 }
    private var topOffset: CGFloat { onLeft && panelWidth < 330 ? 32 : 0 }
    var canStartNew: Bool
    var newChat: () -> Void
    var close: () -> Void

    var body: some View {
        HStack(spacing: Chrome.sidebarControlSpacing) {
            Spacer(minLength: 0)
            ChatHeaderButton(symbol: "square.and.pencil", label: "Clear chat", visibleTitle: "Clear chat", controlWidth: buttonWidth, enabled: canStartNew, trailingInset: buttonWidth + 16, onLeft: onLeft, panelWidth: panelWidth, topOffset: topOffset, action: newChat)
                .frame(width: buttonWidth, height: 28)
            ChatHeaderButton(symbol: "xmark", label: "Close chat", visibleTitle: "Close chat", controlWidth: buttonWidth, onLeft: onLeft, panelWidth: panelWidth, topOffset: topOffset, action: close)
                .frame(width: buttonWidth, height: 28)
        }
        .buttonStyle(ChromeButtonStyle(prominent: true))
        .padding(.leading, 10)
        .padding(.trailing, Chrome.sidebarHorizontalInset)
        .padding(.top, topOffset)
        .frame(height: Self.height(onLeft: onLeft, panelWidth: panelWidth))
        .contentShape(Rectangle())
        .background(WindowDragArea(excluded: true))
    }
}

struct ChatActivityRow: View {
    static let maximumDetailsHeight: CGFloat = 260
    let bubble: ChatBubble
    var streaming = false
    var approval: AIActionApproval.Request? = nil
    var approve: (UUID) -> Void = { _ in }
    var decline: (UUID) -> Void = { _ in }
    @ViewState var expanded = false
    @ViewState private var detailsHeight: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).frame(width: 8)
                    Text(bubble.title).lineLimit(1).layoutPriority(1)
                    if !bubble.argumentSummary.isEmpty {
                        Text(bubble.argumentSummary).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(.tertiary).help(bubble.argumentSummary)
                    }
                    if bubble.kind == .tool || bubble.kind == .serverTool {
                        if approval != nil {
                            Image(systemName: "hand.tap").help("Waiting for approval")
                        } else if bubble.state == "Running" {
                            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: bubble.state == "Completed" ? "checkmark" : bubble.state == "Error" ? "exclamationmark.circle" : "stop.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(bubble.state == "Error" ? Color.orange : Color.secondary)
                                .help(bubble.state).accessibilityLabel(bubble.state)
                        }
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: expanded || approval != nil ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(bubble.title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Divider().padding(.horizontal, 9)
                ScrollView(.vertical) {
                    details
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                }
                .frame(height: min(detailsHeight, Self.maximumDetailsHeight))
                .clipped()
            }
            if let approval {
                Divider().padding(.horizontal, 9)
                HStack(spacing: 10) {
                    Button(approval.action.buttonTitle) { approve(approval.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Skip") { decline(approval.id) }.buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .padding(10)
            }
        }
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: expanded || approval != nil ? 14 : 12))
        .overlay { RoundedRectangle(cornerRadius: expanded || approval != nil ? 14 : 12).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        .clipShape(RoundedRectangle(cornerRadius: expanded || approval != nil ? 14 : 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if approval != nil { expanded = true } }
        .onChange(of: approval?.id) { _, id in if id != nil { expanded = true } }
    }

    @ViewBuilder private var details: some View {
        if let approval {
            argumentFields(approval.fields)
        } else if bubble.kind == .reasoning {
            ChatMarkdown(source: bubble.text, streaming: streaming)
        } else if bubble.kind == .serverTool {
            VStack(alignment: .leading, spacing: 10) {
                if !bubble.text.isEmpty { Text(bubble.text).font(.callout).textSelection(.enabled) }
                ForEach(bubble.sources, id: \.url) { source in
                    if let url = URL(string: source.url), ["http", "https"].contains(url.scheme ?? "") {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title).lineLimit(2)
                                if source.title != url.host {
                                    Text(url.host ?? source.url).font(.caption).foregroundStyle(.secondary)
                                }
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
                if bubble.argumentFields.isEmpty {
                    Text("No arguments").font(.caption).foregroundStyle(.secondary)
                } else { argumentFields(bubble.argumentFields) }
                if !bubble.detail.isEmpty {
                    Text(bubble.detailTruncated ? "Result preview — model received the full chunk" : "Result").font(.caption).foregroundStyle(.secondary)
                    Text(bubble.detail).font(.system(size: 11, design: .monospaced))
                }
            }.textSelection(.enabled)
        }
    }

    private func argumentFields(_ fields: [ChatArgumentField]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(fields.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    Text(fields[index].label).font(.caption).foregroundStyle(.secondary)
                    Text(fields[index].value).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.textSelection(.enabled)
    }
}
