import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages wire format, routed through Gateway by default.
public struct AnthropicMessagesProvider: Provider {
  let wire: NativeGatewayWire
  public init(apiKey: String, baseURL: URL = URL(string: "https://ai-gateway.vercel.sh/v1")!, transport: any HTTPTransport = URLSessionTransport()) throws {
    wire = try NativeGatewayWire(api: .anthropic, apiKey: apiKey, baseURL: baseURL, transport: transport)
  }
  public func stream(_ request: ModelRequest) -> Stream<ModelResponse> { wire.stream(request) }
}

/// OpenAI Responses wire format, routed through Gateway by default.
public struct OpenAIResponsesProvider: Provider {
  let wire: NativeGatewayWire
  public init(apiKey: String, baseURL: URL = URL(string: "https://ai-gateway.vercel.sh/v1")!, transport: any HTTPTransport = URLSessionTransport()) throws {
    wire = try NativeGatewayWire(api: .openai, apiKey: apiKey, baseURL: baseURL, transport: transport)
  }
  public func stream(_ request: ModelRequest) -> Stream<ModelResponse> { wire.stream(request) }
}

struct NativeGatewayWire: Sendable {
  enum API: String, Sendable { case anthropic, openai }
  let api: API
  let apiKey: String
  let baseURL: URL
  let transport: any HTTPTransport
  init(api: API, apiKey: String, baseURL: URL, transport: any HTTPTransport) throws {
    guard ["https", "http"].contains(baseURL.scheme), baseURL.host != nil,
      baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
      throw AIError.configuration("Expected an HTTP(S) base URL without credentials, query or fragment.")
    }
    self.api = api; self.apiKey = apiKey; self.baseURL = baseURL; self.transport = transport
  }

  func makeRequest(_ request: ModelRequest) throws -> URLRequest {
    guard !request.modelID.isEmpty else { throw AIError.configuration("Model ID is empty.") }
    let limit = request.options.maxCompletionTokens ?? 8192
    guard limit > 0 else { throw AIError.configuration("Token limit must be positive.") }
    var history: [JSONValue] = []
    let owner = api.rawValue + ":" + request.modelID
    for message in request.messages where message.role != .system {
      if message.role == .assistant, message.nativeOwner == owner, let content = message.nativeContent {
        if api == .anthropic { history.append(.object(["role": .string("assistant"), "content": .array(content)])) }
        else {
          // Gateway cannot replay a Responses web_search_call as an input item:
          // it translates it into a client call without a matching tool output.
          // Keep available query/source context as text instead of inventing results.
          for item in content {
            if item["type"] == .string("web_search_call") {
              let context = try (item["action"] ?? .object([:])).jsonString()
              history.append(.object(["role": .string("assistant"), "content": .string("Completed web search (reported query and sources): " + context)]))
            } else { history.append(item) }
          }
        }
        continue
      }
      if api == .anthropic {
        var content: [JSONValue] = []
        if !message.text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(message.text)])) }
        for call in message.toolCalls {
          content.append(.object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name),
            "input": try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))]))
        }
        for result in message.toolResults {
          content.append(.object(["type": .string("tool_result"), "tool_use_id": .string(result.callID),
            "content": .string(try result.value.string ?? result.value.jsonString()), "is_error": .bool(result.isError)]))
        }
        if !content.isEmpty { history.append(.object(["role": .string(message.role == .assistant ? "assistant" : "user"), "content": .array(content)])) }
      } else {
        if !message.text.isEmpty { history.append(.object(["role": .string(message.role == .assistant ? "assistant" : "user"), "content": .string(message.text)])) }
        for call in message.toolCalls {
          history.append(.object(["type": .string("function_call"), "call_id": .string(call.id), "name": .string(call.name), "arguments": .string(call.arguments)]))
        }
        for result in message.toolResults {
          let value = result.isError ? JSONValue.object(["error": result.value]) : result.value
          history.append(.object(["type": .string("function_call_output"), "call_id": .string(result.callID), "output": .string(try value.string ?? value.jsonString())]))
        }
      }
    }
    let system = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
    var body: [String: JSONValue] = ["model": .string(request.modelID), "stream": .bool(true)]
    var definitions = request.tools.map { tool -> JSONValue in
      if api == .anthropic { return .object(["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.parameters]) }
      return .object(["type": .string("function"), "name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters, "strict": .bool(false)])
    }
    if request.options.gatewayWebSearch {
      guard !request.tools.contains(where: { $0.name == "web_search" }) else { throw AIError.configuration("web_search is reserved for native search.") }
      definitions.append(api == .anthropic
        ? .object(["type": .string("web_search_20250305"), "name": .string("web_search"), "max_uses": .integer(5)])
        : .object(["type": .string("web_search")]))
    }
    if !definitions.isEmpty { body["tools"] = .array(definitions) }
    if let temperature = request.options.temperature { body["temperature"] = .number(temperature) }
    if request.options.includeReasoning {
      let id = request.modelID.lowercased()
      if api == .anthropic {
        let pattern = #"claude-(?:opus|sonnet|haiku|fable|mythos)-(\d+)(?:[.-](\d{1,2})(?!\d))?"#
        if let match = try NSRegularExpression(pattern: pattern).firstMatch(in: id, range: NSRange(id.startIndex..., in: id)),
           let majorRange = Range(match.range(at: 1), in: id), let major = Int(id[majorRange]) {
          let minor = Range(match.range(at: 2), in: id).flatMap { Int(id[$0]) } ?? 0
          if major >= 5 || (major == 4 && minor >= 6) {
            body["thinking"] = .object(["type": .string("adaptive"), "display": .string("summarized")])
          } else if major == 4 && limit > 1024 {
            body["thinking"] = .object(["type": .string("enabled"), "budget_tokens": .integer(1024), "display": .string("summarized")])
          }
        }
      } else if !id.contains("-chat"), !id.contains("o3-mini"), id.range(of: #"(?:^|/)(?:gpt-[56](?:[.\-]|$)|o[34](?:-|$))"#, options: .regularExpression) != nil {
        var reasoning: [String: JSONValue] = ["summary": .string("auto")]
        // Astra can return empty summaries at default/medium effort.
        if id.split(separator: "/").last == "gpt-6-astra" { reasoning["effort"] = .string("high") }
        body["reasoning"] = .object(reasoning)
      }
    }
    if api == .anthropic {
      body["messages"] = .array(history); body["max_tokens"] = .integer(Int64(limit))
      if !system.isEmpty { body["system"] = .string(system) }
    } else {
      body["input"] = .array(history); body["max_output_tokens"] = .integer(Int64(limit)); body["store"] = .bool(false)
      body["include"] = .array([.string("reasoning.encrypted_content")] + (request.options.gatewayWebSearch ? [.string("web_search_call.action.sources")] : []))
      if !system.isEmpty { body["instructions"] = .string(system) }
    }
    var http = URLRequest(url: baseURL.appendingPathComponent(api == .anthropic ? "messages" : "responses"))
    http.httpMethod = "POST"; http.timeoutInterval = 120
    http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    if api == .anthropic { http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
    http.httpBody = try JSONEncoder().encode(JSONValue.object(body))
    return http
  }

  func stream(_ request: ModelRequest) -> Stream<ModelResponse> {
    Stream { emit in
      let http = try makeRequest(request)
      var parser = SSEParser(); var state = NativeAccumulator(api: api, owner: api.rawValue + ":" + request.modelID)
      var status: Int?; var errorBody = Data()
      emit(.streamStart(model: request.modelID))
      for try await event in transport.send(http) {
        try Task.checkCancellation()
        switch event {
        case .response(let code): status = code
        case .data(let data):
          guard let status else { throw AIError.invalidResponse("Body before status") }
          guard (200..<300).contains(status) else { errorBody.append(data.prefix(max(0, 16384-errorBody.count))); continue }
          for payload in try parser.feed(data) {
            guard payload != "[DONE]" else { continue }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
            if let response = try state.feed(value, emit: emit) { emit(.streamEnd(response)); return response }
          }
        }
      }
      try Task.checkCancellation()
      if let status, !(200..<300).contains(status) { throw AIError.http(status: status, body: String(decoding: errorBody, as: UTF8.self)) }
      throw AIError.incompleteResponse
    }
  }
}

extension JSONValue {
  var items: [JSONValue] { if case .array(let items) = self { items } else { [] } }
  var int: Int { if case .integer(let value) = self { Int(clamping: value) } else { 0 } }
  func setting(_ key: String, _ value: JSONValue) -> JSONValue {
    guard case .object(var object) = self else { return self }; object[key] = value; return .object(object)
  }
}

struct NativeAccumulator {
  let api: NativeGatewayWire.API
  let owner: String
  var message = Message.assistant("")
  var blocks: [Int: JSONValue] = [:]
  var arguments: [Int: String] = [:]
  var openBlocks = Set<Int>()
  var searches: [String: ServerToolActivity] = [:]
  var completedOutput: [Int: JSONValue] = [:]
  var usage = Usage()
  var reason: String?
  var started = false

  mutating func feed(_ value: JSONValue, emit: EventSink) throws -> ModelResponse? {
    let type = value["type"]?.string ?? ""
    if type == "error" || type == "response.failed" { throw AIError.invalidResponse("Provider reported a stream error.") }
    if api == .openai {
      switch type {
      case "response.output_text.delta":
        let text = value["delta"]?.string ?? ""; message.text += text; emit(.textDelta(text))
      case "response.reasoning_summary_text.delta":
        let text = value["delta"]?.string ?? ""; message.reasoning += text; emit(.reasoningDelta(text))
      case "response.output_item.added", "response.output_item.done":
        if let item = value["item"] {
          if type == "response.output_item.done" {
            guard case .integer(let index) = value["output_index"], index >= 0, index <= 10000 else {
              throw AIError.invalidResponse("Invalid completed output index")
            }
            completedOutput[Int(index)] = item
          }
          if item["type"] == .string("web_search_call") { updateSearch(item, emit: emit) }
        }
      case "response.web_search_call.in_progress", "response.web_search_call.searching", "response.web_search_call.completed":
        if let id = value["item_id"]?.string {
          var activity = searches[id] ?? ServerToolActivity(id: id)
          activity.status = type.hasSuffix("completed") ? "Completed" : "Running"
          searches[id] = activity; emit(.serverToolActivity(activity))
        }
      case "response.incomplete": throw AIError.incompleteResponse
      case "response.completed":
        guard let response = value["response"], response["status"] == .string("completed"), case .array(let terminalOutput) = response["output"] else { throw AIError.incompleteResponse }
        // Direct account streams may omit output items from the terminal snapshot.
        // Completed item events are authoritative; never execute added/partial items.
        var output = completedOutput.keys.sorted().compactMap { completedOutput[$0] }
        for item in terminalOutput {
          if let id = item["id"]?.string, let index = output.firstIndex(where: { $0["id"]?.string == id }) {
            output[index] = item
          } else { output.append(item) }
        }
        var finalText = ""
        var finalReasoning = ""
        for item in output {
          switch item["type"]?.string {
          case "reasoning":
            finalReasoning += (item["summary"]?.items ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n\n")
          case "function_call":
            message.toolCalls.append(ToolCall(id: item["call_id"]?.string ?? "", name: item["name"]?.string ?? "", arguments: item["arguments"]?.string ?? ""))
          case "web_search_call": updateSearch(item, emit: emit)
          case "message":
            for part in item["content"]?.items ?? [] {
              finalText += part["text"]?.string ?? part["refusal"]?.string ?? ""
              for citation in part["annotations"]?.items ?? [] { addCitation(citation, emit: emit) }
            }
          default: break
          }
        }
        if message.reasoning.isEmpty && !finalReasoning.isEmpty { message.reasoning = finalReasoning; emit(.reasoningDelta(finalReasoning)) }
        if message.text.isEmpty && !finalText.isEmpty { message.text = finalText; emit(.textDelta(finalText)) }
        message.nativeOwner = owner; message.nativeContent = output
        usage = Usage(inputTokens: response["usage"]?["input_tokens"]?.int ?? 0, outputTokens: response["usage"]?["output_tokens"]?.int ?? 0)
        return try finish(message.toolCalls.isEmpty ? "stop" : "tool_calls", emit: emit)
      default: break
      }
      return nil
    }
    switch type {
    case "message_start":
      started = true
      usage.inputTokens = value["message"]?["usage"]?["input_tokens"]?.int ?? 0
    case "content_block_start":
      guard let indexValue = value["index"], case .integer(let rawIndex) = indexValue, rawIndex >= 0,
        let block = value["content_block"], blocks[Int(rawIndex)] == nil else { throw AIError.invalidResponse("Invalid block start") }
      let index = Int(rawIndex); blocks[index] = block; openBlocks.insert(index)
      if block["type"] == .string("server_tool_use") { updateAnthropicSearch(block, emit: emit) }
      if block["type"] == .string("text"), let text = block["text"]?.string, !text.isEmpty { message.text += text; emit(.textDelta(text)) }
    case "content_block_delta":
      let index = value["index"]?.int ?? -1
      guard var block = blocks[index], openBlocks.contains(index), let delta = value["delta"] else { throw AIError.invalidResponse("Delta without block") }
      switch delta["type"]?.string {
      case "text_delta":
        let text = delta["text"]?.string ?? ""; message.text += text; emit(.textDelta(text))
        block = block.setting("text", .string((block["text"]?.string ?? "") + text))
      case "thinking_delta":
        let text = delta["thinking"]?.string ?? ""; message.reasoning += text; emit(.reasoningDelta(text))
        block = block.setting("thinking", .string((block["thinking"]?.string ?? "") + text))
      case "signature_delta": block = block.setting("signature", .string((block["signature"]?.string ?? "") + (delta["signature"]?.string ?? "")))
      case "input_json_delta": arguments[index, default: ""] += delta["partial_json"]?.string ?? ""
      case "citations_delta":
        if let citation = delta["citation"] {
          block = block.setting("citations", .array((block["citations"]?.items ?? []) + [citation])); addCitation(citation, emit: emit)
        }
      default: break
      }
      blocks[index] = block
    case "content_block_stop":
      let index = value["index"]?.int ?? -1
      guard var block = blocks[index], openBlocks.remove(index) != nil else { throw AIError.invalidResponse("Invalid block end") }
      if let json = arguments[index] {
        block = block.setting("input", try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
      }
      blocks[index] = block
      if block["type"] == .string("tool_use") {
        message.toolCalls.append(ToolCall(id: block["id"]?.string ?? "", name: block["name"]?.string ?? "", arguments: try (block["input"] ?? .object([:])).jsonString()))
      }
      if block["type"] == .string("server_tool_use") { updateAnthropicSearch(block, emit: emit) }
      if block["type"] == .string("web_search_tool_result") {
        let id = block["tool_use_id"]?.string ?? ""
        var activity = searches[id] ?? ServerToolActivity(id: id)
        activity.status = block["content"]?["type"] == .string("web_search_tool_result_error") ? "Error" : "Completed"
        activity.error = block["content"]?["error_code"]?.string
        activity.sources = (block["content"]?.items ?? []).compactMap(source)
        searches[id] = activity; emit(.serverToolActivity(activity))
      }
    case "message_delta":
      reason = value["delta"]?["stop_reason"]?.string
      usage.outputTokens = value["usage"]?["output_tokens"]?.int ?? usage.outputTokens
    case "message_stop":
      guard started, let reason, openBlocks.isEmpty else { throw AIError.incompleteResponse }
      message.nativeOwner = owner; message.nativeContent = blocks.keys.sorted().compactMap { blocks[$0] }
      return try finish(reason == "tool_use" ? "tool_calls" : reason == "end_turn" || reason == "stop_sequence" ? "stop" : reason, emit: emit)
    default: break
    }
    return nil
  }

  mutating func finish(_ reason: String, emit: EventSink) throws -> ModelResponse {
    var ids = Set<String>()
    for call in message.toolCalls {
      guard !call.id.isEmpty, !call.name.isEmpty, ids.insert(call.id).inserted else { throw AIError.invalidResponse("Invalid tool identity") }
      emit(.toolCall(call))
    }
    usage.totalTokens = usage.inputTokens + usage.outputTokens
    return ModelResponse(message: message, usage: usage, finishReason: reason)
  }
  func source(_ item: JSONValue) -> SearchSource? {
    guard let address = item["url"]?.string, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
    return SearchSource(url: address, title: item["title"]?.string ?? url.host ?? address)
  }
  mutating func addCitation(_ item: JSONValue, emit: EventSink) {
    guard let source = source(item) else { return }
    emit(.source(source))
  }
  mutating func updateAnthropicSearch(_ block: JSONValue, emit: EventSink) {
    guard let id = block["id"]?.string, block["name"] == .string("web_search") else { return }
    var activity = searches[id] ?? ServerToolActivity(id: id)
    if let query = block["input"]?["query"]?.string { activity.query = query }
    searches[id] = activity; emit(.serverToolActivity(activity))
  }
  mutating func updateSearch(_ item: JSONValue, emit: EventSink) {
    guard let id = item["id"]?.string else { return }
    var activity = searches[id] ?? ServerToolActivity(id: id)
    let action = item["action"]
    activity.query = action?["query"]?.string ?? action?["queries"]?.items.compactMap(\.string).joined(separator: "\n") ?? activity.query
    if let url = action?["url"]?.string { activity.query = url }
    activity.status = item["status"] == .string("completed") ? "Completed" : item["status"] == .string("failed") ? "Error" : "Running"
    let sources = (action?["sources"]?.items ?? []).compactMap(source)
    if !sources.isEmpty { activity.sources = sources }
    searches[id] = activity; emit(.serverToolActivity(activity))
  }
}
