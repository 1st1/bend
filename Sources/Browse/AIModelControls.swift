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
    var controls: AIModelControls
    @Binding var tuning: ModelTuning

    init(modelID: String, controls: AIModelControls, selections: Binding<[String: ModelTuning]>) {
        self.controls = controls
        _tuning = Binding(get: { selections.wrappedValue[modelID] ?? .init() },
                          set: { selections.wrappedValue[modelID] = $0 })
    }

    var body: some View {
        if !controls.efforts.isEmpty {
            Picker("Reasoning effort", selection: $tuning.effort) {
                Text("Automatic").tag(nil as ReasoningEffort?)
                ForEach(controls.efforts, id: \.self) { effort in
                    Text(effort == .xhigh ? "Extra high" : effort.rawValue.capitalized).tag(Optional(effort))
                }
            }
        }
        if controls.fast {
            Toggle("Fast mode (premium pricing)", isOn: $tuning.fast)
        }
    }
}
