import Foundation
import Testing

@testable import AI

@Test func streamingTextUsageAndUnicodeAcrossByteBoundaries() async throws {
  let provider = try fixtureProvider(
    """
    : keepalive\r
    \r
    data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"Hi 🌍"},"finish_reason":null}]}\r
    \r
    data: {"choices":[{"index":0,"delta":{"content":"!"},"finish_reason":"stop"}]}\r
    \r
    data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}\r
    \r
    data: [DONE]\r
    \r

    """)
  let (response, events) = try await drain(
    stream(Model("test", provider: provider), messages: [.user("Hi")]))
  #expect(response.text == "Hi 🌍!")
  #expect(response.usage == Usage(inputTokens: 3, outputTokens: 2))
  #expect(events.contains(.textDelta("Hi 🌍")))
  #expect(events.last == .streamEnd(response))
}

@Test func interleavedToolCallsAreAssembledByIndex() async throws {
  let provider = try fixtureProvider(
    """
    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"second","arguments":"{\\"x\\":"}},{"index":0,"id":"a","function":{"name":"first","arguments":"{"}}]}}]}

    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}},{"index":1,"function":{"arguments":"2}"}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]


    """)
  let (response, events) = try await drain(stream(Model("test", provider: provider), messages: []))
  #expect(
    response.message.toolCalls == [
      ToolCall(id: "a", name: "first", arguments: "{}"),
      ToolCall(id: "b", name: "second", arguments: "{\"x\":2}"),
    ])
  #expect(events.filter { if case .toolCallDelta = $0 { true } else { false } }.count == 4)
}

@Test func rejectsTruncatedStreamEvenAfterText() async throws {
  for suffix in ["", "data: [DONE]\n\n"] {
    let provider = try fixtureProvider(
      "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\n" + suffix)
    await #expect(throws: AIError.incompleteResponse) {
      try await drain(stream(Model("test", provider: provider), messages: []))
    }
  }
}

@Test func rejectsMissingDoneAndMalformedJSONAndInBandError() async throws {
  let bodies = [
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
    "data: {bad json}\n\n",
    "data: {\"error\":{\"message\":\"overloaded\"}}\n\n",
  ]
  for body in bodies {
    let provider = try fixtureProvider(body)
    await #expect(throws: AIError.self) {
      try await drain(stream(Model("test", provider: provider), messages: []))
    }
  }
}

@Test func preservesHTTPErrorStatusAndBody() async throws {
  let provider = try fixtureProvider("rate limited", status: 429)
  await #expect(throws: AIError.http(status: 429, body: "rate limited")) {
    try await drain(stream(Model("test", provider: provider), messages: []))
  }
}

@Test func requestEncodesToolsAndConversationWithoutNestedHistory() throws {
  let provider = try OpenAICompatibleProvider(
    baseURL: URL(string: "https://example.invalid/v1/")!, apiKey: "test-key")
  let call = ToolCall(id: "call_1", name: "lookup", arguments: "{}")
  let request = try provider.makeRequest(
    .init(
      modelID: "creator/model",
      messages: [
        .system("Be helpful"), .user("Hello"), .assistant("", toolCalls: [call]),
        .tool([
          .init(
            callID: call.id, name: call.name, value: .string("found"),
            subagentMessages: [.user("private child history")])
        ]),
      ], tools: [.init(name: "lookup", description: "Look it up", parameters: emptySchema)],
      options: .init(temperature: 0, maxCompletionTokens: 42)))
  #expect(request.url?.absoluteString == "https://example.invalid/v1/chat/completions")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
  let data = try #require(request.httpBody)
  let body = try JSONDecoder().decode(JSONValue.self, from: data)
  #expect(body["model"] == .string("creator/model"))
  #expect(body["max_completion_tokens"] == .integer(42))
  #expect(body["stream"] == .bool(true))
  #expect(!String(decoding: data, as: UTF8.self).contains("private child history"))
  guard case .array(let messages) = body["messages"] else {
    Issue.record("Missing messages")
    return
  }
  #expect(messages.count == 4)
  #expect(messages[3]["tool_call_id"] == .string("call_1"))
  #expect(messages[3]["content"] == .string("found"))
}

@Test func sseSupportsMultilineCRAndBOM() throws {
  var parser = SSEParser()
  let events = try parser.feed(
    Data("\u{FEFF}: hi\rdata: one\rdata: two\r\revent: ignored\ndata: three\n\n".utf8))
  #expect(events == ["one\ntwo", "three"])
}

@Test func sseRejectsOversizedFramesAndInvalidUTF8() throws {
  var parser = SSEParser()
  #expect(throws: AIError.self) { try parser.feed(Data(repeating: 65, count: 1_048_577)) }
  var other = SSEParser()
  #expect(throws: AIError.self) { try other.feed(Data([0xFF, 10])) }
}

@Test func jsonRoundTripsNullAndLargeIntegers() throws {
  let value = JSONValue.object([
    "large": .integer(9_007_199_254_740_993), "null": .null,
    "bool": .bool(true), "items": .array([.number(1.5)]),
  ])
  #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
}

@Test func gatewayWebSearchEncodingAndReportedUsage() async throws {
  let provider = try OpenAICompatibleProvider(baseURL: URL(string: "https://example.invalid/v1")!)
  for enabled in [false, true] {
    let request = try provider.makeRequest(.init(modelID: "test", messages: [],
      tools: [.init(name: "list_panes", description: "List", parameters: emptySchema)],
      options: .init(gatewayWebSearch: enabled)))
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    guard case .array(let tools) = body["tools"] else { Issue.record("Missing tools"); return }
    #expect(tools.count == (enabled ? 2 : 1))
    if enabled { #expect(tools.last?["type"] == .string("vercel:perplexity_search")) }
  }
  // Gateway metadata must never become a locally executable tool call.
  for container in ["delta", "message"] {
    let body = "data: {\"choices\":[{\"index\":0,\"\(container)\":{\"provider_metadata\":{\"gateway\":{\"gatewayToolCalls\":{\"perplexity_search\":2}}}},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    let (response, events) = try await drain(stream(Model("test", provider: fixtureProvider(body)), messages: []))
    #expect(response.message.toolCalls.isEmpty)
    #expect(events.filter { if case .serverToolUsage = $0 { true } else { false } }.count == 1)
    #expect(events.contains(.serverToolUsage(.object(["perplexity_search": .integer(2)]))))
  }
}
