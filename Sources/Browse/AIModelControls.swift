import SwiftUI
import AI

/// Catalog IDs can be vendor-qualified and direct API snapshots carry a release date.
struct AIModelControls {
    var efforts: [ReasoningEffort] = []
    var fast = false
    var available: Bool { fast || !efforts.isEmpty }

    init(modelID: String, connection: String) {
        let parts = modelID.split(separator: "/")
        guard let slug = parts.last else { return }
        let direct = parts.count == 1
        let name = String(slug).replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$|-\d{8}$"#,
                                                     with: "", options: .regularExpression)
        let common: [ReasoningEffort] = [.low, .medium, .high]
        if (direct && ["openai", "openaiKey"].contains(connection)) || parts.first == "openai" {
            switch name {
            case "gpt-6-sol", "gpt-6-luna", "gpt-6.1-terra":
                efforts = [.none] + common + [.xhigh, .max]
                fast = direct
            case "gpt-6-astra", "gpt-6.1-sol", "gpt-6.2-astra", "gpt-6.2-sol":
                efforts = common + [.xhigh, .max]
                fast = direct
            case "gpt-5.6-sol", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini":
                efforts = common + [.xhigh]
                fast = direct
            case "gpt-5.4-pro":
                efforts = [.medium, .high, .xhigh]
            case "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1", "o3", "o3-mini", "o4-mini":
                efforts = common
            case "gpt-5.2", "gpt-5.3-codex":
                efforts = common + [.xhigh]
            default: break
            }
        } else if (direct && connection == "anthropicKey") || parts.first == "anthropic" {
            switch name.replacingOccurrences(of: ".", with: "-") {
            case "claude-opus-5-5", "claude-fable-5-2", "claude-mythos-5-2":
                fast = direct
                efforts = common + [.xhigh, .max]
            case "claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7":
                efforts = common + [.xhigh, .max]
            case "claude-opus-4-6":
                efforts = common + [.max]
            case "claude-sonnet-5":
                efforts = common + [.xhigh]
            case "claude-sonnet-4-6", "claude-opus-4-5":
                efforts = common
            default: break
            }
        }
    }
}

struct AIModelControlPicker: View {
    let model: GatewayModel
    let controls: AIModelControls
    @Binding var selections: [String: ModelTuning]
    let back: () -> Void
    let dismiss: () -> Void
    @FocusState private var focused: Int?
    private var choices: [ReasoningEffort?] { [nil] + controls.efforts.map(Optional.some) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                    Text(model.name ?? model.id).lineLimit(1)
                    Spacer()
                }.font(.system(size: 12, weight: .medium)).padding(10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to models")
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                if !controls.efforts.isEmpty {
                    Text("Reasoning effort").font(.caption).foregroundStyle(.secondary).padding(8)
                    ForEach(choices.indices, id: \.self) { index in
                        let effort = choices[index]
                        Button { choose(effort) } label: {
                            HStack {
                                Text(effort == .xhigh ? "Extra high" : effort?.rawValue.capitalized ?? "Automatic")
                                Spacer()
                                if effort == selections[model.id]?.effort { Image(systemName: "checkmark") }
                            }
                            .font(.system(size: 12)).padding(8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focused, equals: index)
                        .focusEffectDisabled()
                        .background(focused == index ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .onHover { if $0 { focused = index } }
                        .accessibilityAddTraits(effort == selections[model.id]?.effort ? .isSelected : [])
                    }
                }
                if controls.fast {
                    Divider()
                    Toggle("Fast mode (premium pricing)", isOn: Binding(
                        get: { selections[model.id]?.fast == true },
                        set: { selections[model.id, default: .init()].fast = $0 }
                    )).font(.system(size: 12)).padding(8)
                }
            }.padding(6)
        }
        .onAppear { focused = choices.firstIndex(of: selections[model.id]?.effort) }
        .onKeyPress(.downArrow) { moveFocus(1) }
        .onKeyPress(.upArrow) { moveFocus(-1) }
        .onKeyPress(.return) {
            guard let index = focused else { return .ignored }
            choose(choices[index])
            return .handled
        }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onExitCommand(perform: back)
    }
    private func choose(_ effort: ReasoningEffort?) {
        selections[model.id, default: .init()].effort = effort
        dismiss()
    }

    private func moveFocus(_ delta: Int) -> KeyPress.Result {
        guard let index = focused else { return .ignored }
        focused = min(choices.count - 1, max(0, index + delta))
        return .handled
    }

}
