---
lat:
  require-code-mention: true
---
# Behavior specifications

These specifications describe existing automated coverage of orchestration, protocol translation, and real HTTP streaming. Every leaf is anchored by one comment next to its corresponding test.

## Agent behavior

Scripted providers isolate the agent loop from HTTP so tests can verify history, side effects, concurrency, and delegation deterministically.

### Tool round trip

A typed local tool's result must reach the next model request, with complete history, accumulated usage, final output, and Codable result serialization preserved.

[[Tests/AITests/AgentTests.swift#agentExecutesTypedToolAndContinuesConversation]] checks a weather tool followed by a final model answer. This protects the [[lat.md/ai-sdk/sdk-agents#Agents and tools#Conversation loop|conversation loop]] and serializable result contract.

### Direct streaming

A direct model stream returns tool calls after one request without running an agent loop, preserving the distinction between inference and local execution.

[[Tests/AITests/AgentTests.swift#directStreamDoesNotExecuteTools]] verifies the returned call and recorded request count. See [[lat.md/ai-sdk/sdk-streaming#Model streaming#Model selection and requests]].

### Recoverable tool errors

Unknown tools, malformed JSON, non-object arguments, and thrown tool errors must become error results so the model can continue the conversation.

[[Tests/AITests/AgentTests.swift#unknownMalformedAndThrowingToolsBecomeErrorResults]] verifies all four results are errors and retain their original call order. See [[lat.md/ai-sdk/sdk-agents#Agents and tools#Tool contracts and errors]].

### Subagent isolation

Child text must stream as nested events, while its final answer becomes the parent tool result and its separate history is retained locally.

[[Tests/AITests/AgentTests.swift#subagentStreamsAndReturnsFinalTextWithSeparateHistory]] checks child instructions and prompt, nested event identity, the final tool value, and separate histories. See [[lat.md/ai-sdk/sdk-agents#Agents and tools#Subagent delegation]].

### Bounded concurrency

Multiple calls may execute concurrently, but active tasks must respect the configured limit and stored results must retain the model's call order.

[[Tests/AITests/AgentTests.swift#toolConcurrencyIsBoundedAndHistoryKeepsCallOrder]] uses differently paced tools and an actor to measure peak concurrency. See [[lat.md/ai-sdk/sdk-agents#Agents and tools#Configuration and execution limits]].

### Step budget

When the last allowed model turn asks for tools, the run must fail before executing those tools or making another request.

[[Tests/AITests/AgentTests.swift#stepLimitPreventsFurtherRequestsAndToolSideEffects]] checks the step-limit error, an untouched side-effect flag, and request count. This protects the follow-up budget invariant.

### Truncated tool completion

A response ending at the token limit must not execute tools even when its argument text appears complete, avoiding side effects from an incomplete model turn.

[[Tests/AITests/AgentTests.swift#refusesToolsFromTruncatedCompletion]] supplies a length finish reason and checks that the tool is never invoked. See [[lat.md/ai-sdk/sdk-provider#Chat Completions provider#Completion integrity]].

### Invalid configuration

Duplicate tool names and nonpositive step or concurrency limits must fail during agent construction rather than after a run starts.

[[Tests/AITests/AgentTests.swift#validatesAgentConfiguration]] covers these configuration errors. Other constructor checks exist but are not individually exercised by this test.

### Nested cancellation

Cancelling the parent while a child tool is running must cancel the nested work and stop further parent requests, rather than turn cancellation into a tool error.

[[Tests/AITests/AgentTests.swift#cancellingParentCancelsSubagentTool]] waits for the child's tool to start and verifies cancellation reaches it before the parent's result completes. See [[lat.md/ai-sdk/sdk-streaming#Model streaming#Cancellation propagation]].

## Provider behavior

HTTP fixtures exercise the real request encoder and incremental response decoder without relying on a model service.

### Fragmented text and usage

Text and usage must survive byte-sized chunks, including a split emoji, keepalive comments, CRLF framing, and a usage-only chunk after the finish reason.

[[Tests/AITests/ProviderTests.swift#streamingTextUsageAndUnicodeAcrossByteBoundaries]] checks final text, token counts, a text delta, and the stream-end aggregate. See [[lat.md/ai-sdk/sdk-provider#Chat Completions provider#Incremental framing]].

### Interleaved tool calls

Interleaved fragments must be joined by call index so IDs, names, and argument text remain attached to the correct tool.

[[Tests/AITests/ProviderTests.swift#interleavedToolCallsAreAssembledByIndex]] supplies calls in reverse initial order and verifies sorted completed calls plus fragment events.

### Missing finish reason

Partial text without a finish reason must fail as incomplete, whether the transport ends directly or supplies a DONE marker.

[[Tests/AITests/ProviderTests.swift#rejectsTruncatedStreamEvenAfterText]] covers both endings, preventing partial output from being treated as successful completion.

### Invalid completion

A missing DONE marker, malformed JSON, or in-band provider error must fail the response instead of producing a successful aggregate.

[[Tests/AITests/ProviderTests.swift#rejectsMissingDoneAndMalformedJSONAndInBandError]] checks each failure shape. See [[lat.md/ai-sdk/sdk-provider#Chat Completions provider#Completion integrity]].

### HTTP error details

A non-success HTTP response must preserve its status and body so callers can distinguish a provider rejection from a malformed successful stream.

[[Tests/AITests/ProviderTests.swift#preservesHTTPErrorStatusAndBody]] verifies a rate-limit response using the fixture transport. Real session behavior has separate [[lat.md/ai-sdk/sdk-tests#Behavior specifications#HTTP behavior#Network error response|network coverage]].

### Request encoding

Wire requests must preserve model selection, authorization, tools, and call-result identity while excluding the child conversation from the parent model's input.

[[Tests/AITests/ProviderTests.swift#requestEncodesToolsAndConversationWithoutNestedHistory]] checks endpoint construction, selected options, streaming mode, message count, tool-result text, and nested-history exclusion.

### SSE line framing

Multiline data, CR separators, an initial byte-order mark, and ignored event fields must yield the intended payloads rather than corrupting JSON boundaries.

[[Tests/AITests/ProviderTests.swift#sseSupportsMultilineCRAndBOM]] exercises the framing parser independently of completion decoding.

### SSE input limits

An oversized frame or invalid UTF-8 must fail parsing, bounding individual event accumulation and avoiding replacement of corrupt input with apparently valid text.

[[Tests/AITests/ProviderTests.swift#sseRejectsOversizedFramesAndInvalidUTF8]] covers both rejected inputs. See [[Sources/AI/SSE.swift#SSEParser]].

### JSON value fidelity

Encoding and decoding JSON values must retain nulls, booleans, arrays, fractional values, and integers larger than floating-point exact-integer precision.

[[Tests/AITests/ProviderTests.swift#jsonRoundTripsNullAndLargeIntegers]] protects the shared [[Sources/AI/JSONValue.swift#JSONValue|tool data representation]].

## HTTP behavior

Loopback integration tests use the default URLSession transport to check properties that an in-memory fixture cannot establish.

### Incremental network delivery

The consumer must receive the first delta while the server is still waiting to send the remainder, proving that HTTP delivery does not buffer the whole response.

[[Tests/AITests/HTTPIntegrationTests.swift#HTTPIntegration#receivesDeltaBeforeServerFinishesResponse]] acknowledges the first delta to release the fixture's remaining output, then checks streamed and aggregate text.

### Network error response

A real HTTP rejection must surface the response status and body through the provider's public error type.

[[Tests/AITests/HTTPIntegrationTests.swift#HTTPIntegration#returnsHTTPFailure]] checks an unauthorized response from the loopback server. See [[lat.md/ai-sdk/sdk-provider#Chat Completions provider#HTTP delivery and failures]].

### Connection cancellation

Cancelling a live stream must fail its result with CancellationError and close the server connection, releasing the underlying network work.

[[Tests/AITests/HTTPIntegrationTests.swift#HTTPIntegration#cancellationClosesNetworkConnection]] cancels after the first delta and polls the fixture for observed disconnect. See [[lat.md/ai-sdk/sdk-development#Development#Test infrastructure]].

## Gateway web search

[[Tests/AITests/ProviderTests.swift#gatewayWebSearchEncodingAndReportedUsage]] checks opt-in server-tool encoding alongside local tools, default omission, and metadata events without local execution.

## Native Gateway adapters

[[Tests/AITests/NativeProviderTests.swift]] verifies fragmented native streams, queries and sources, local tool identity, exact native-history replay, model switching, search-off encoding, and automatic Gateway routing.

## Native stream completion

[[Tests/AITests/NativeProviderTests.swift#nativeStreamCompletion]] rejects missing terminal events and provider errors, and verifies paused server turns continue within the bounded agent loop.

## Live native Gateway search

[[Tests/AITests/NativeGatewaySmokeTests.swift#liveNativeGatewaySearch]] uses explicit opt-in environment variables to verify public web search, sources, a no-op local tool and history replay through both Gateway interfaces. It is skipped by default.

## Thinking summary options

[[Tests/AITests/NativeProviderTests.swift#nativeThinkingOptions]] verifies model-specific summary requests, legacy Claude budgets, date-suffixed models, and omission for non-reasoning OpenAI models. Astra requests high effort only when reasoning summaries are enabled.

## Responses completed item retention

[[Tests/AITests/NativeProviderTests.swift]] verifies tool and message items survive an empty terminal snapshot, repeated snapshots do not duplicate calls, and interrupted streams never execute completed items.

## Live OpenAI account tools

[[Tests/AITests/NativeGatewaySmokeTests.swift#liveOpenAIAccountTools]] optionally checks a synthetic local tool round-trip and a nonempty answer through OpenAI's public Responses endpoint with an account access token. It sends no browsing data.

## Untrusted usage counters

The extreme-counter regression in [[Tests/AITests/NativeProviderTests.swift]] verifies extreme provider counters cannot overflow individual responses or accumulated usage across Chat Completions, Responses, and Messages adapters.
