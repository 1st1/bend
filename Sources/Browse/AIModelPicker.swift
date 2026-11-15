import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

// Shared by the composer and preferred-model setting.
struct AIModelPicker: View {
    let models: [GatewayModel]
    @Binding var selection: String
    @ViewState private var presented = false
    private var label: String {
        models.first(where: { $0.id == selection })?.name ?? (selection.isEmpty ? "Select model" : selection)
    }
    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 5) {
                Text(label).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.font(.system(size: 11)).padding(.horizontal, 5).frame(height: 24)
        }
        .buttonStyle(ChromeButtonStyle(pill: true))
        .accessibilityLabel("Model").accessibilityValue(label)
        .help("Choose a model")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            AIModelSearch(models: models, selection: $selection) { presented = false }
        }
    }
}

private struct AIModelSearch: View {
    let models: [GatewayModel]
    @Binding var selection: String
    let dismiss: () -> Void
    @ViewState private var query = ""
    @ViewState private var highlighted: String?
    private var matches: [GatewayModel] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return models.filter { model in
            words.allSatisfy { (model.id + " " + (model.name ?? "")).localizedCaseInsensitiveContains(String($0)) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            AIModelSearchField(text: $query, move: move, submit: {
                if let model = matches.first(where: { $0.id == highlighted }) ?? matches.first { choose(model) }
            }, dismiss: dismiss).frame(height: 24).padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { model in
                            Button { choose(model) } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name ?? model.id).font(.system(size: 12))
                                        Text(model.id).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selection == model.id { Image(systemName: "checkmark").font(.system(size: 11)) }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(highlighted == model.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .id(model.id)
                        }
                        if matches.isEmpty {
                            Text(models.isEmpty ? "No models loaded. Refresh in Settings → AI." : "No matching models")
                                .font(.callout).foregroundStyle(.secondary).padding(20)
                        }
                    }.padding(6)
                }.frame(height: 320)
                .onAppear { highlighted = matches.contains(where: { $0.id == selection }) ? selection : matches.first?.id; proxy.scrollTo(highlighted, anchor: .center) }
                .onChange(of: highlighted) { _, value in proxy.scrollTo(value, anchor: .center) }
                .onChange(of: query) { _, _ in highlighted = matches.first?.id }
            }
        }
        .frame(width: 320)
        .onExitCommand(perform: dismiss)
    }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { highlighted = nil; return }
        let current = matches.firstIndex(where: { $0.id == highlighted }) ?? 0
        highlighted = matches[min(matches.count - 1, max(0, current + delta))].id
    }
    private func choose(_ model: GatewayModel) { selection = model.id; dismiss() }
}

enum AIPaneTool: String, CaseIterable, Identifiable {
    case read = "read_pane", navigate = "navigate_pane", create = "create_pane"
    case click = "click_element", fill = "fill_element"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .read: "Read page"
        case .navigate: "Navigate panes"
        case .create: "Open a new pane"
        case .click: "Click elements"
        case .fill: "Fill text fields"
        }
    }
    var summary: String {
        switch self {
        case .read: "Read page text and find interactive elements."
        case .navigate: "Open a web address in an existing pane."
        case .create: "Open a web address beside an existing pane in this tab."
        case .click: "Click links, buttons, and other page elements."
        case .fill: "Enter text in ordinary fields without submitting."
        }
    }
}
