---
lat:
  require-code-mention: true
---
# Native AI tests

Tests exercise [[lat.md/architecture/ai|native chat]] with scripted model providers, disposable browser profiles, and local HTML, without Gateway credentials or paid model calls.

## Conversation lifecycle

[[Tests/BrowseTests/AIChatTests.swift#aiConversationLifecycle]] verifies streamed text, a real agent tool round-trip, follow-up history, per-tab isolation, cancellation with partial output, and cleanup on closure.

## Pane tool boundaries

[[Tests/BrowseTests/AIChatTests.swift#aiPaneToolBoundaries]] verifies pane listing excludes other tabs, stale pane IDs and non-HTTP navigation are rejected, and real WebKit reads, clicks, and fills work without exposing password values.

## Gateway connection state

[[Tests/BrowseTests/AIChatTests.swift#aiGatewayConnectionState]] verifies key validation precedes credential storage, disconnect removes credentials, model discovery filters unsupported types, and authentication failures do not expose the supplied key.

## Empty tool arguments

[[Vendor/ai-swift/Tests/AITests/AgentTests.swift#parameterlessToolArguments]] exercises real SSE decoding followed by agent execution: empty, whitespace, and object arguments work for parameterless tools, while malformed JSON and null remain errors.

[[Vendor/ai-swift/Tests/AITests/AgentTests.swift#emptyArgumentsDoNotBypassRequiredParameters]] verifies empty arguments cannot invoke tools requiring a pane. Conversation lifecycle coverage also sends an empty-argument call to Browse's actual pane-list tool.

## AI preferences and tool permissions

[[Tests/BrowseTests/AIChatTests.swift#aiPreferencesAndToolPermissions]] verifies preferred-model persistence, per-chat overrides, catalog refresh retention, tool advertisement filtering, live revocation after advertisement, and re-enabling tools.

## Custom system prompt

[[Tests/BrowseTests/AIChatTests.swift#aiCustomSystemPrompt]] verifies prompt persistence, default/reset state, actual model requests using the edited prompt on follow-ups, and exclusion of stale system instructions from conversation history.

## Markdown rendering

[[Tests/BrowseTests/ChatMarkdownTests.swift#chatMarkdownRendering]] checks emphasis, code text, safe links, and native layout and whole-response selection for structured responses and incomplete streamed Markdown at sidebar width.

## Page citation routing

[[Tests/BrowseTests/ChatPageLinkTests.swift#chatPageCitationRouting]] verifies Markdown references navigate the exact pane to real anchor URLs, preserve URL plus signs, reject foreign panes and legacy selectors, and open external sources in the same tab.

## Chat interaction

[[Tests/BrowseTests/ChatInteractionTests.swift#chatInteraction]] verifies native mouse clicks on selectable citation text reach the chat URL handler and that scroll-following stays suspended above the bottom while text streams.

## AI debugging

[[Tests/BrowseTests/AIDiagnosticsTests.swift#aiDebugging]] verifies logging defaults off, persists enablement, records selectors, redacts URL credentials and query values, stops appending when disabled, and clears retained files.

## Chat header controls

[[Tests/BrowseTests/ChatHeaderTests.swift#chatHeaderControls]] exercises both left and right chat placement and verifies native mouse dispatch, alignment, visibility, spacing across window sizes, and exclusion from window dragging.

## Streaming transcript

[[Tests/BrowseTests/ChatStreamPresentationTests.swift#chatStreamPresentation]] verifies step starts create no placeholder bubbles, provider reasoning updates one latest-paragraph summary across steps and clears with chat, tool states update by call ID, and answer deltas combine into one text bubble.

The summary moves above the first response delta, remains anchored there through later text and tool metadata, and resets its anchor when chat clears. Web search presentation and persistent enablement are also covered by [[Tests/BrowseTests/ChatStreamPresentationTests.swift#chatStreamPresentation]].

## Model search keyboard commands

[[Tests/BrowseTests/ChatStreamPresentationTests.swift#modelSearchKeyboardCommands]] checks native search-field command dispatch for Up/Down, Return, and Escape while retaining the text editor as first responder.

## Paginated page reads

[[Tests/BrowseTests/AIChatTests.swift#aiPaginatedPageReads]] verifies complete Unicode text reconstruction, element and reference pagination, a stable snapshot during live mutations, end-of-read markers, and rejection of replaced or malformed cursors.

## Pane prompt context

[[Tests/BrowseTests/AIChatTests.swift#aiPanePromptContext]] verifies placeholder expansion, active-pane identity, tool-list removal, and fresh tab-scoped metadata before successive model requests without duplicate system messages.

## Progressive Markdown

[[Tests/BrowseTests/ChatMarkdownTests.swift#progressiveChatMarkdown]] checks every streamed prefix of a pane citation hides its routing identifiers, code stays literal, and incremental native text updates retain final content and attributes.

## Account authorization validation

[[Tests/BrowseTests/AIOAuthTests.swift#aiOAuthValidation]] checks PKCE and callback binding, duplicate parameters, denial, and client substitution. Signed RSA fixtures reject tampering, wrong issuer/audience/nonce, and expiry.

## Account refresh and logout

[[Tests/BrowseTests/AIOAuthTests.swift#aiOAuthLifecycle]] checks serialized refresh and atomic token rotation, denied plan scopes, retained registration after logout, local logout during revocation failure, and prevention of refresh resurrection.

## Loopback sign-in callback

[[Tests/BrowseTests/AIOAuthTests.swift#aiOAuthLoopback]] verifies the real loopback listener rejects wrong state without ending sign-in, accepts a subsequent valid callback, and terminates on cancellation.

## Account request routing

[[Tests/BrowseTests/AIOAuthTests.swift#aiOAuthRouting]] verifies account bearer replacement and explicit Vercel team scoping. Requests to an unexpected host are rejected before credentials reach the transport.

## Account selection and models

[[Tests/BrowseTests/AIOAuthTests.swift#aiOAuthAccountSelection]] checks account restoration, visible model filtering, reuse of the loaded catalog on sidebar reopening, direct Responses routing with OAuth, logout disabling inference, and switching back to a Gateway key with a matching model catalog.

## Empty answer reporting

[[Tests/BrowseTests/AIChatTests.swift#aiEmptyAnswerReporting]] verifies a completed run without answer text shows a retryable error rather than silently leaving only the user's bubble.

## Private window exclusion

[[Tests/BrowseTests/AIChatTests.swift#aiPrivateWindowExclusion]] verifies private windows cannot create chats, send model requests, expose pane context, execute any pane tool, or follow chat links.
