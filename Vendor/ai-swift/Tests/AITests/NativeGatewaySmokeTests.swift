import Foundation
import Testing
@testable import AI

@Test(.enabled(if: ProcessInfo.processInfo.environment["AI_NATIVE_GATEWAY_SMOKE"] == "1"))
func liveNativeGatewaySearch() async throws {
  let key = try #require(ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"])
  for id in (ProcessInfo.processInfo.environment["AI_SMOKE_MODEL"].map { [$0] } ?? ["anthropic/claude-sonnet-4.5", "openai/gpt-5.4-mini"]) {
    let model = try Model.gateway(id, apiKey: key)
    let agent = try Agent(tools: [Tool(name: "echo_test", description: "Echo a public test value", parameters: emptySchema) { _, _ in .string("ok") }], maxSteps: 5)
    let run = agent.run(model, messages: [.user("Search the web once for the official Swift programming language website, then call echo_test, then answer with its URL in one sentence.")], options: .init(maxCompletionTokens: 2048, gatewayWebSearch: true))
    var sawQuery = false; var sawSource = false
    for try await event in run {
      if case .serverToolActivity(let activity) = event {
        sawQuery = sawQuery || !activity.query.isEmpty
        sawSource = sawSource || !activity.sources.isEmpty
      }
      if case .source = event { sawSource = true }
    }
    let result = try await run.result
    #expect(!result.output.isEmpty)
    #expect(sawQuery && sawSource, "Missing search details for \(id)")
    #expect(result.messages.contains { $0.toolResults.contains { $0.name == "echo_test" } })
    print("Native Gateway smoke passed: \(id), steps=\(result.steps)")
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AI_OPENAI_ACCOUNT_SMOKE"] == "1"))
func liveOpenAIAccountTools() async throws {
  let key = try #require(ProcessInfo.processInfo.environment["OPENAI_ACCOUNT_ACCESS_TOKEN"])
  let provider = try OpenAIResponsesProvider(apiKey: key, baseURL: URL(string: "https://api.openai.com/v1")!)
  let agent = try Agent(tools: [Tool(name: "echo_test", description: "Return a synthetic test greeting", parameters: emptySchema) { _, _ in .string("Hello from the test tool.") }], maxSteps: 3)
  let run = agent.run(Model("gpt-6.1-sol", provider: provider),
                      messages: [.system("You are testing a tool. Call echo_test once, then repeat its greeting in your final answer."),
                                 .user("Please run the greeting test.")],
                      options: .init(includeReasoning: true))
  let (result, _) = try await drain(run)
  #expect(result.messages.contains { $0.toolResults.contains { $0.name == "echo_test" } })
  #expect(!result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  print("OpenAI account tool round-trip completed: steps=\(result.steps), answerCharacters=\(result.output.count)")
}
