import Foundation
import Combine

// @lat: [[lat.md/architecture/ai#Action approval]]
@MainActor final class AIActionApproval: ObservableObject {
    enum Action: String {
        case systemInfo = "get_system_info", location = "get_current_location"
        case navigate = "navigate_pane", create = "create_pane", click = "click_element", fill = "fill_element"
        var buttonTitle: String {
            switch self {
            case .navigate: "Open page"
            case .create: "Open in new pane"
            case .click: "Click element"
            case .fill: "Fill field"
            case .systemInfo: "Share system info"
            case .location: "Share location"
            }
        }
    }
    struct Target: Decodable {
        var tag: String
        var label: String
        var href: String?
        var type: String?
    }
    struct Request: Identifiable {
        let id = UUID()
        let callID: String
        let action: Action
        let page: String
        var destination: String?
        var selector: String?
        var text: String?
        var target: Target?

        var fields: [ChatArgumentField] {
            if action == .systemInfo || action == .location {
                return [ChatArgumentField(label: "Share with AI", value: action == .systemInfo
                    ? "macOS version, Bend version/build, current date, time rounded up to minutes, and timezone."
                    : "Current latitude, longitude, and accuracy. macOS may also ask for location permission. This is a one-time request.")]
            }
            var result = [ChatArgumentField(label: action == .create ? "Beside page" : "Current page", value: page)]
            if let destination { result.append(.init(label: "Open", value: destination)) }
            if let target {
                result.append(.init(label: "Element", value: target.label.isEmpty ? target.tag.lowercased() : target.label))
                if let href = target.href { result.append(.init(label: "Link", value: href)) }
            }
            if let selector { result.append(.init(label: "Selector", value: selector)) }
            if let text { result.append(.init(label: "Text", value: text)) }
            return result
        }
    }

    @Published private(set) var pending: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    func request(_ request: Request) async -> Bool {
        guard !Task.isCancelled, pending == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                self.continuation = continuation
                pending = request
            }
        } onCancel: {
            Task { @MainActor in self.resolve(request.id, approved: false) }
        }
    }

    func resolve(_ id: UUID, approved: Bool) {
        guard pending?.id == id, let continuation else { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: approved)
    }

    func cancel() {
        if let pending { resolve(pending.id, approved: false) }
    }
}
