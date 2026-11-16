import Foundation
import Testing
@testable import AI

// @lat: [[lat.md/ai-sdk/sdk-tests#Tool image transport]]
@Test func toolImageTransport() async throws {
    let image = ToolImage(mediaType: "image/jpeg", data: Data([1, 2, 3]))
    let result = ToolResult(callID: "shot", name: "take_screenshot", value: .string("Approved viewport"), images: [image])
    let tool = Tool(definition: .init(name: "take_screenshot", description: "Screenshot", parameters: emptySchema)) { _, _ in
        ToolOutput(value: .string("Approved viewport"), images: [image])
    }
    let script = Script([
        .init(message: .assistant("", toolCalls: [.init(id: "shot", name: "take_screenshot", arguments: "{}")]), finishReason: "tool_calls"),
        .init(message: .assistant("I see the page."))
    ])
    let agent = try Agent(tools: [tool])
    _ = try await drain(agent.run(Model("test", provider: ScriptedProvider(script: script)), messages: [.user("Look")]))
    #expect(await script.requests.last?.messages.last?.toolResults.first?.images == [image])
    let messages: [Message] = [.assistant("", toolCalls: [.init(id: "shot", name: "take_screenshot", arguments: "{}")]), .tool([result])]
    let decoded = try JSONDecoder().decode([Message].self, from: JSONEncoder().encode(messages))
    #expect(decoded == messages)
    let old = try JSONDecoder().decode(ToolResult.self, from: Data(#"{"callID":"old","name":"read","value":"text","isError":false}"#.utf8))
    #expect(old.images == nil)
    let a = try AnthropicMessagesProvider(apiKey: "fixture")
    let aBody = try JSONDecoder().decode(JSONValue.self, from: #require(a.wire.makeRequest(.init(modelID: "anthropic/test", messages: messages)).httpBody))
    let aImage = aBody["messages"]?.items.last?["content"]?.items.first?["content"]?.items.last
    #expect(aImage?["type"] == .string("image"))
    #expect(aImage?["source"]?["data"] == .string("AQID"))
    let o = try OpenAIResponsesProvider(apiKey: "fixture")
    let oBody = try JSONDecoder().decode(JSONValue.self, from: #require(o.wire.makeRequest(.init(modelID: "openai/test", messages: messages)).httpBody))
    #expect(oBody["input"]?.items.last?["output"]?.items.last?["type"] == .string("input_image"))
    #expect(oBody["input"]?.items.last?["output"]?.items.last?["image_url"] == .string(image.dataURL))
    let c = try OpenAICompatibleProvider(baseURL: URL(string: "https://example.com/v1")!, apiKey: "fixture")
    let cBody = try JSONDecoder().decode(JSONValue.self, from: #require(c.makeRequest(.init(modelID: "test", messages: messages)).httpBody))
    #expect(cBody["messages"]?.items.last?["content"]?.items.last?["image_url"]?["url"] == .string(image.dataURL))
}
