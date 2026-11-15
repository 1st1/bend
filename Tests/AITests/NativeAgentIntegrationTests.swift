import Foundation
import Testing
@testable import AI

private actor NativeAgentScript {
  private var responses: [[String]]
  private(set) var requests: [URLRequest] = []
  init(_ responses: [[String]]) { self.responses = responses }
  func next(_ request: URLRequest) throws -> [String] {
    requests.append(request)
    guard !responses.isEmpty else { throw AIError.invalidResponse("Unexpected extra model request.") }
    return responses.removeFirst()
  }
}

private struct NativeAgentTransport: HTTPTransport {
  let script: NativeAgentScript
  func send(_ request: URLRequest) -> AsyncThrowingStream<HTTPEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let events = try await script.next(request)
          continuation.yield(.response(status: 200))
          for event in events {
            // Split the real wire format to exercise incremental SSE decoding.
            for byte in ("data: " + event + "\n\n").utf8 { continuation.yield(.data(Data([byte]))) }
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private let openAIToolTurn = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"web_search_call","id":"search","status":"completed","action":{"type":"search","queries":["Swift"],"sources":[{"type":"url","url":"https://swift.org","title":"Swift"}]}},{"type":"function_call","call_id":"local","name":"echo_test","arguments":"{}"}]}}"#
private let openAIAnswer = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"https://swift.org","annotations":[]}]}]}}"#

// @lat: [[lat.md/ai-sdk/sdk-tests#Mocked native Gateway search]]
@Test func mockedNativeGatewaySearch() async throws {
  for anthropic in [true, false] {
    let first = anthropic ? [
      #"{"type":"message_start","message":{"usage":{"input_tokens":12}}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"search","name":"web_search","input":{"query":"Swift"}}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"search","content":[{"type":"web_search_result","url":"https://swift.org","title":"Swift","encrypted_content":"fixture"}]}}"#,
      #"{"type":"content_block_stop","index":1}"#,
      #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"local","name":"echo_test","input":{}}}"#,
      #"{"type":"content_block_stop","index":2}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":6}}"#,
      #"{"type":"message_stop"}"#
    ] : [openAIToolTurn]
    let second = anthropic ? [
      #"{"type":"message_start","message":{"usage":{"input_tokens":18}}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"https://swift.org"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}"#,
      #"{"type":"message_stop"}"#
    ] : [openAIAnswer]
    let script = NativeAgentScript([first, second])
    let transport = NativeAgentTransport(script: script)
    let provider: any Provider = anthropic
      ? try AnthropicMessagesProvider(apiKey: "fixture-key", transport: transport)
      : try OpenAIResponsesProvider(apiKey: "fixture-key", transport: transport)
    let model = Model(anthropic ? "anthropic/test" : "openai/test", provider: provider)
    let agent = try Agent(tools: [Tool(name: "echo_test", description: "Echo a fixture", parameters: emptySchema) { _, _ in .string("fixture-result") }], maxSteps: 3)
    let (result, events) = try await drain(agent.run(model, messages: [.user("Search, call the tool, and answer.")], options: .init(gatewayWebSearch: true)))
    #expect(result.steps == 2 && result.output == "https://swift.org")
    #expect(result.messages.contains { $0.toolResults.contains { $0.name == "echo_test" } })
    #expect(events.contains { if case .serverToolActivity(let value) = $0 { return value.query == "Swift" && !value.sources.isEmpty }; return false })
    let requests = await script.requests
    #expect(requests.count == 2)
    for request in requests {
      #expect(request.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/" + (anthropic ? "messages" : "responses"))
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    }
    let replay = try #require(requests.last?.httpBody)
    let body = String(decoding: replay, as: UTF8.self)
    #expect(body.contains("fixture-result") && body.contains("local"))
    #expect(body.contains(anthropic ? "encrypted_content" : "Completed web search"))
  }
}

// @lat: [[lat.md/ai-sdk/sdk-tests#Mocked OpenAI account tools]]
@Test func mockedOpenAIAccountTools() async throws {
  let script = NativeAgentScript([[openAIToolTurn], [openAIAnswer]])
  let provider = try OpenAIResponsesProvider(apiKey: "fixture-account-token", baseURL: URL(string: "https://api.openai.com/v1")!, transport: NativeAgentTransport(script: script))
  let agent = try Agent(tools: [Tool(name: "echo_test", description: "Synthetic greeting", parameters: emptySchema) { _, _ in .string("Hello from the test tool.") }], maxSteps: 3)
  let (result, _) = try await drain(agent.run(Model("gpt-6.1-sol", provider: provider), messages: [.user("Run the greeting test.")], options: .init(includeReasoning: true)))
  #expect(result.steps == 2 && !result.output.isEmpty)
  #expect(result.messages.contains { $0.toolResults.contains { $0.name == "echo_test" } })
  let requests = await script.requests
  #expect(requests.count == 2)
  for request in requests {
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-account-token")
  }
  let replay = String(decoding: try #require(requests.last?.httpBody), as: UTF8.self)
  #expect(replay.contains("function_call_output") && replay.contains("Hello from the test tool."))
}
