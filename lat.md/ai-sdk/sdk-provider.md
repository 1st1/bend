# Chat Completions provider

The built-in provider translates the library's values to OpenAI-compatible Chat Completions HTTP requests and incremental SSE responses, with Vercel AI Gateway as its convenience endpoint.

## Request translation

Protocol translation stays inside the provider so the agent loop and tools do not depend on a particular HTTP service.

[[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider#init]] accepts an HTTP or HTTPS base URL without user credentials, query, or fragment, and a positive timeout. An optional API key becomes a Bearer header. [[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider#makeRequest]] appends chat/completions and always requests a stream.

Messages carry role and text, optional reasoning_content, and assistant function calls. Grouped tool results become individual tool-role messages linked to their call IDs. String results are sent directly; other JSON values are serialized; error values are wrapped in an error object. Subagent history remains local.

Tool definitions become function schemas. Options map to temperature, max_completion_tokens, and optional usage reporting; positive token limits are checked locally. Other model-specific capabilities are not negotiated. This adapter remains the fallback for providers other than Anthropic and OpenAI. [[lat.md/ai-sdk/sdk-tests#Behavior specifications#Provider behavior#Request encoding]] checks the wire boundary.

## Incremental framing

SSE framing operates on bytes, preserving UTF-8 characters and JSON fragments that cross network chunk boundaries.

[[Sources/AI/SSE.swift#SSEParser#feed]] recognizes CR, LF, and CRLF line endings. [[Sources/AI/SSE.swift#SSEParser#finishLine]] strips an initial byte-order mark, joins data lines with newlines, dispatches on blank lines, and ignores comments and unrelated fields. Invalid UTF-8 and oversized frames fail rather than silently dropping content; [[Sources/AI/SSE.swift#SSEParser#maxEventBytes]] owns the frame-size limit.

[[Sources/AI/OpenAICompatibleProvider.swift#CompletionAccumulator#feed]] decodes chunks, forwards text and reasoning deltas, and accumulates tool fragments by their numeric index. It accepts usage-only chunks and uses their latest usage values. Tool IDs, names, and argument strings are assembled before completed calls are emitted. See [[lat.md/ai-sdk/sdk-tests#Behavior specifications#Provider behavior#Fragmented text and usage]] and [[lat.md/ai-sdk/sdk-tests#Behavior specifications#Provider behavior#Interleaved tool calls]].

## Completion integrity

Success requires a finish reason and the SSE DONE marker; partial text or a closed socket alone cannot establish a complete response.

[[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider#stream]] throws an incomplete-response error if the transport ends before DONE. On DONE, [[Sources/AI/OpenAICompatibleProvider.swift#CompletionAccumulator#finish]] requires a finish reason, validates tool identities, orders calls by index, and emits completed tool-call events before the stream-end event.

The accumulator supports only choice index zero, rejects choices arriving after a finish reason, and rejects a tool_calls finish reason with no calls. Malformed JSON and in-band error payloads fail the stream. Tool argument JSON is left for local tool execution to decode, enabling [[lat.md/ai-sdk/sdk-agents#Agents and tools#Tool contracts and errors|model-visible argument errors]].

When no usage is reported, totals remain zero rather than being estimated. Completion does not promise an unrestricted natural-language answer: finish reasons remain visible to callers, and the agent applies additional restrictions before running tools. See [[lat.md/ai-sdk/sdk-tests#Behavior specifications#Provider behavior#Missing finish reason]] and [[lat.md/ai-sdk/sdk-tests#Behavior specifications#Provider behavior#Invalid completion]].

## HTTP delivery and failures

URLSession delegate callbacks deliver chunks on Linux without waiting for the full body. Session cleanup is tied to stream termination.

[[Sources/AI/Transport.swift#URLSessionTransport#send]] creates an ephemeral session with cookie and credential storage disabled. [[Sources/AI/Transport.swift#StreamingDelegate]] forwards status and data, surfaces transport failures, and refuses redirects so credentials are not forwarded to a new location.

[[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider#stream]] requires a status before body data. Non-success responses become [[Sources/AI/Types.swift#AIError|HTTP errors]] with status and a bounded body excerpt. It performs no automatic retries. Cancellation invalidates the session and closes active delivery, as checked by [[lat.md/ai-sdk/sdk-tests#Behavior specifications#HTTP behavior#Connection cancellation]].

## Gateway web search

[[Sources/AI/Stream.swift#ModelOptions]] optionally enables Gateway-hosted Perplexity search alongside local function tools, with model-selected queries and up to five results.

[[Sources/AI/OpenAICompatibleProvider.swift#OpenAICompatibleProvider#makeRequest]] sends the Gateway server-tool format and rejects a colliding local tool name. This option is Gateway-specific and defaults off in the SDK. Successful server-tool counts from provider metadata produce one separate event at completion; they are never executed locally or inserted as client tool calls. Missing metadata produces no inferred activity. Chat Completions does not expose live queries or raw search results. See [[lat.md/ai-sdk/sdk-tests#Gateway web search]].

## Native Gateway adapters

[[Sources/AI/NativeProviders.swift#AnthropicMessagesProvider]] and [[Sources/AI/NativeProviders.swift#OpenAIResponsesProvider]] implement Messages and Responses through Gateway using the same Bearer credential.

[[Sources/AI/Stream.swift#Model#gateway]] selects Messages for anthropic model IDs, Responses for openai IDs, and Chat Completions otherwise. [[Sources/AI/NativeProviders.swift#NativeGatewayWire#makeRequest]] translates local tools and their results, system instructions and optional native web search. Responses disables server storage and requests encrypted reasoning for stateless replay. Messages bounds native searches to five uses per request.

[[Sources/AI/NativeProviders.swift#NativeAccumulator]] assembles byte-framed events into text, reasoning, local calls and separate server-search activity. Search activity includes the provider's query, completion/error state and safe HTTP(S) sources; encrypted search content is not displayed. Citation sources are also emitted independently. Responses retains completed output-item events when the terminal snapshot omits them, merging repeated items by ID. Tools execute only after a successful terminal event. Provider-native blocks/items are retained on [[Sources/AI/Types.swift#Message]] and replayed only to the same protocol and model, preserving signatures and search context across tool steps. Gateway rejects replayed Responses web-search items as unmatched function calls, so those items become assistant text containing the reported query and source URLs on follow-up requests. Other native items are preserved. Switching models falls back to portable text and local tool history.

A terminal Messages stop or completed Responses event is required. Incomplete Responses and in-band errors fail the stream; unfinished local calls are never executed. Anthropic pause_turn continues within the agent's existing step limit. [[lat.md/ai-sdk/sdk-tests#Native Gateway adapters]] and [[lat.md/ai-sdk/sdk-tests#Native stream completion]] cover the wire and orchestration contracts; [[lat.md/ai-sdk/sdk-tests#Mocked native Gateway search]] exercises full agent turns with scripted HTTP responses.

When reasoning display is requested through [[Sources/AI/Stream.swift#ModelOptions]], known Claude 4.6+ models use adaptive summarized thinking, Claude 4 models use a 1,024-token budget, and supported OpenAI reasoning models request automatic summaries. Astra defaults to high effort for summaries because Gateway can return empty summaries at its default and medium effort. An explicit effort selection takes precedence. This can increase latency and token use. Unknown model families retain their defaults. Only provider-returned summary text is emitted; encrypted reasoning stays opaque.

## Tool images

[[Sources/AI/Types.swift#ToolImage]] carries approved image bytes separately from textual tool output. [[Sources/AI/Tool.swift#ToolOutput]] and the agent retain these attachments in Codable tool results.

Anthropic embeds images in tool-result content blocks; OpenAI Responses emits typed input-image function outputs. Chat Completions follows the grouped tool results with a user image message. Text-only legacy results decode without attachments. Provider/model image support is required; the SDK does not negotiate model capabilities.
