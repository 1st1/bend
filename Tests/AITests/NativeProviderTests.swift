import Foundation
import Testing
@testable import AI

private func nativeFixture(_ events: [String]) -> FixtureTransport {
  FixtureTransport(chunks: events.flatMap { Array(("data: " + $0 + "\n\n").utf8).map { Data([$0]) } })
}

// @lat: [[lat.md/ai-sdk/sdk-tests#Native Gateway adapters]]
@Test func nativeGatewayAdapters() async throws {
  let anthropicEvents = [
    #"{"type":"message_start","message":{"usage":{"input_tokens":12}}}"#,
    #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"search1","name":"web_search","input":{}}}"#,
    #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"Swift 🌍\"}"}}"#,
    #"{"type":"content_block_stop","index":0}"#,
    #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"search1","content":[{"type":"web_search_result","url":"https://swift.org","title":"Swift","encrypted_content":"opaque"}]}}"#,
    #"{"type":"content_block_stop","index":1}"#,
    #"{"type":"content_block_start","index":2,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
    #"{"type":"content_block_delta","index":2,"delta":{"type":"thinking_delta","thinking":"Checking."}}"#,
    #"{"type":"content_block_delta","index":2,"delta":{"type":"signature_delta","signature":"signed"}}"#,
    #"{"type":"content_block_stop","index":2}"#,
    #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"local1","name":"read_pane","input":{}}}"#,
    #"{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"pane\":\"one\"}"}}"#,
    #"{"type":"content_block_stop","index":3}"#,
    #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":6}}"#,
    #"{"type":"message_stop"}"#,
  ]
  let aTransport = nativeFixture(anthropicEvents)
  let a = try AnthropicMessagesProvider(apiKey: "test", transport: aTransport)
  let (ar, ae) = try await drain(stream(Model("anthropic/test", provider: a), messages: [.user("Search")], options: .init(gatewayWebSearch: true)))
  #expect(ar.message.toolCalls.map(\.name) == ["read_pane"])
  #expect(ar.usage == Usage(inputTokens: 12, outputTokens: 6))
  #expect(ae.contains(.reasoningDelta("Checking.")))
  #expect(ae.contains(.serverToolActivity(.init(id: "search1", query: "Swift 🌍", status: "Completed", sources: [.init(url: "https://swift.org", title: "Swift")]))))
  let aRequest = try #require(await aTransport.log.requests.first)
  #expect(aRequest.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/messages")
  #expect(aRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test")
  let followup = try a.wire.makeRequest(.init(modelID: "anthropic/test", messages: [ar.message, .tool([.init(callID: "local1", name: "read_pane", value: .string("page"))])]))
  let followupBody = try JSONDecoder().decode(JSONValue.self, from: #require(followup.httpBody))
  #expect(followupBody["messages"]?.items.first?["content"] == .array(try #require(ar.message.nativeContent)))
  #expect(String(decoding: followup.httpBody!, as: UTF8.self).contains("encrypted_content"))
  #expect(String(decoding: followup.httpBody!, as: UTF8.self).contains("signed"))

  let oEvents = [
    #"{"type":"response.output_item.added","item":{"type":"web_search_call","id":"search2","status":"in_progress"}}"#,
    #"{"type":"response.output_text.delta","delta":"Found 🌍"}"#,
    #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":9,"output_tokens":4},"output":[{"type":"reasoning","id":"reason1","summary":[],"encrypted_content":"opaque"},{"type":"web_search_call","id":"search2","status":"completed","action":{"type":"search","queries":["Swift"],"sources":[{"type":"url","url":"https://swift.org","title":"Swift"}]}},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Found 🌍","annotations":[]}]},{"type":"function_call","call_id":"local2","name":"read_pane","arguments":"{\"pane\":\"one\"}"}]}}"#,
  ]
  let oTransport = nativeFixture(oEvents)
  let o = try OpenAIResponsesProvider(apiKey: "test", transport: oTransport)
  let (or, oe) = try await drain(stream(Model("openai/test", provider: o), messages: [.user("Search")], options: .init(gatewayWebSearch: true)))
  #expect(or.text == "Found 🌍")
  #expect(or.message.toolCalls.map(\.id) == ["local2"])
  #expect(or.usage == Usage(inputTokens: 9, outputTokens: 4))
  #expect(oe.contains(.serverToolActivity(.init(id: "search2", query: "Swift", status: "Completed", sources: [.init(url: "https://swift.org", title: "Swift")]))))
  let oRequest = try #require(await oTransport.log.requests.first)
  #expect(oRequest.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/responses")
  let oBody = try JSONDecoder().decode(JSONValue.self, from: #require(oRequest.httpBody))
  #expect(oBody["store"] == .bool(false))
  #expect(oBody["include"]?.items.contains(.string("web_search_call.action.sources")) == true)
  let oFollowup = try o.wire.makeRequest(.init(modelID: "openai/test", messages: [or.message]))
  let oFollowupBody = try JSONDecoder().decode(JSONValue.self, from: #require(oFollowup.httpBody))
  #expect(oFollowupBody["input"]?.items.contains(where: { $0["type"] == .string("web_search_call") }) == false)
  #expect(String(decoding: oFollowup.httpBody!, as: UTF8.self).contains("Completed web search"))
  #expect(String(decoding: oFollowup.httpBody!, as: UTF8.self).contains("encrypted_content"))
  // Foreign model history must not receive opaque provider payloads.
  let switched = try a.wire.makeRequest(.init(modelID: "anthropic/test", messages: [or.message]))
  #expect(!String(decoding: switched.httpBody!, as: UTF8.self).contains("encrypted_content"))
  for api in [a.wire, o.wire] {
    let disabled = try api.makeRequest(.init(modelID: "test", messages: [.user("Hello")]))
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(disabled.httpBody))
    #expect(body["tools"] == nil)
  }
  #expect(try Model.gateway("anthropic/test", apiKey: "test").provider is AnthropicMessagesProvider)
  #expect(try Model.gateway("openai/test", apiKey: "test").provider is OpenAIResponsesProvider)
  #expect(try Model.gateway("google/test", apiKey: "test").provider is OpenAICompatibleProvider)
}

// @lat: [[lat.md/ai-sdk/sdk-tests#Native stream completion]]
@Test func nativeStreamCompletion() async throws {
  for api in [NativeGatewayWire.API.anthropic, .openai] {
    let wire = try NativeGatewayWire(api: api, apiKey: "test", baseURL: URL(string: "https://example.invalid/v1")!, transport: nativeFixture([#"{"type":"ping"}"#]))
    await #expect(throws: AIError.incompleteResponse) { try await drain(wire.stream(.init(modelID: "test", messages: []))) }
  }
  let errorProvider = try OpenAIResponsesProvider(apiKey: "test", transport: nativeFixture([#"{"type":"response.failed","response":{"error":{"message":"error"}}}"#]))
  await #expect(throws: AIError.self) { try await drain(stream(Model("test", provider: errorProvider), messages: [])) }
  let pauseScript = Script([.init(message: .assistant("Searching"), finishReason: "pause_turn"), .init(message: .assistant("Done"))])
  let (result, _) = try await drain(Agent().run(Model("test", provider: ScriptedProvider(script: pauseScript)), messages: [.user("Search")]))
  #expect(result.steps == 2 && result.output == "Done")
}

// @lat: [[lat.md/ai-sdk/sdk-tests#Thinking summary options]]
@Test func nativeThinkingOptions() throws {
  for (model, expected) in [("anthropic/claude-sonnet-5.5", "adaptive"), ("anthropic/claude-sonnet-4.6", "adaptive"), ("anthropic/claude-sonnet-4.5", "enabled"), ("anthropic/claude-sonnet-4-20250514", "enabled")] {
    let provider = try AnthropicMessagesProvider(apiKey: "test")
    let request = try provider.wire.makeRequest(.init(modelID: model, messages: [], options: .init(includeReasoning: true)))
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    #expect(body["thinking"]?["type"] == .string(expected))
    #expect(body["thinking"]?["display"] == .string("summarized"))
  }
  let provider = try OpenAIResponsesProvider(apiKey: "test")
  let disabled = try provider.wire.makeRequest(.init(modelID: "openai/gpt-6-astra", messages: []))
  let disabledBody = try JSONDecoder().decode(JSONValue.self, from: #require(disabled.httpBody))
  #expect(disabledBody["reasoning"] == nil)
  for model in ["openai/gpt-5.4-mini", "openai/gpt-6", "openai/gpt-6-astra", "openai/gpt-4.1", "openai/gpt-5-chat", "openai/o3-mini"] {
    let request = try provider.wire.makeRequest(.init(modelID: model, messages: [], options: .init(includeReasoning: true)))
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    let supported = ["openai/gpt-5.4-mini", "openai/gpt-6", "openai/gpt-6-astra"].contains(model)
    #expect((body["reasoning"]?["summary"] == .string("auto")) == supported)
    #expect(body["reasoning"]?["effort"] == (model == "openai/gpt-6-astra" ? .string("high") : nil))
  }
}

// @lat: [[lat.md/ai-sdk/sdk-tests#Responses completed item retention]]
@Test func responsesCompletedItemRetention() async throws {
  let call = #"{"type":"function_call","id":"item1","call_id":"call1","name":"read_pane","arguments":"{\"pane\":\"one\"}","status":"completed"}"#
  let done = #"{"type":"response.output_item.done","output_index":0,"item":\#(call)}"#
  let terminal = #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#
  let provider = try OpenAIResponsesProvider(apiKey: "test", transport: nativeFixture([done, terminal]))
  let (result, events) = try await drain(stream(Model("gpt-6.1-sol", provider: provider), messages: [.user("Read")]))
  #expect(result.message.toolCalls == [.init(id: "call1", name: "read_pane", arguments: #"{"pane":"one"}"#)])
  #expect(events.contains(.toolCall(result.message.toolCalls[0])))
  #expect(result.message.nativeContent?.count == 1)

  // A repeated terminal snapshot must not execute the same tool twice.
  let repeated = #"{"type":"response.completed","response":{"status":"completed","output":[\#(call)]}}"#
  let duplicateProvider = try OpenAIResponsesProvider(apiKey: "test", transport: nativeFixture([done, repeated]))
  let (deduplicated, _) = try await drain(stream(Model("test", provider: duplicateProvider), messages: []))
  #expect(deduplicated.message.toolCalls.count == 1)

  let textDone = #"{"type":"response.output_item.done","output_index":0,"item":{"id":"message1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}"#
  let textProvider = try OpenAIResponsesProvider(apiKey: "test", transport: nativeFixture([textDone, terminal]))
  let (text, textEvents) = try await drain(stream(Model("test", provider: textProvider), messages: []))
  #expect(text.text == "Hello")
  #expect(textEvents.filter { $0 == .textDelta("Hello") }.count == 1)

  let interrupted = try OpenAIResponsesProvider(apiKey: "test", transport: nativeFixture([done]))
  await #expect(throws: AIError.incompleteResponse) { try await drain(stream(Model("test", provider: interrupted), messages: [])) }
}
