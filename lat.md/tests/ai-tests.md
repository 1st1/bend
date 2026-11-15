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

[[Tests/AITests/AgentTests.swift#parameterlessToolArguments]] exercises real SSE decoding followed by agent execution: empty, whitespace, and object arguments work for parameterless tools, while malformed JSON and null remain errors.

[[Tests/AITests/AgentTests.swift#emptyArgumentsDoNotBypassRequiredParameters]] verifies empty arguments cannot invoke tools requiring a pane. Conversation lifecycle coverage also sends an empty-argument call to Browse's actual pane-list tool.

## AI preferences and tool permissions

[[Tests/BrowseTests/AIChatTests.swift#aiPreferencesAndToolPermissions]] verifies preferred-model persistence, per-chat overrides, catalog refresh retention, tool advertisement filtering, live revocation after advertisement, and re-enabling tools.

## Custom system prompt

[[Tests/BrowseTests/AIChatTests.swift#aiCustomSystemPrompt]] verifies prompt persistence, default/reset state, actual model requests using the edited prompt on follow-ups, and exclusion of stale system instructions from conversation history.

## Markdown rendering

[[Tests/BrowseTests/ChatMarkdownTests.swift#chatMarkdownRendering]] checks emphasis, code text, safe links, and native layout and whole-response selection for structured responses and incomplete streamed Markdown at sidebar width.

## Page citation routing

[[Tests/BrowseTests/ChatPageLinkTests.swift#chatPageCitationRouting]] verifies exact citation targets, anchor URLs, and fallback to a sole or designated link pane without touching other tabs.

Stale citations remain unavailable in split tabs without a designated link pane. Ordinary external links reuse the same fallback destinations or open an adjacent pane. Reuse preserves pane count and WebView identity; URL plus signs survive, and legacy selectors, unsafe schemes, and embedded credentials remain rejected.

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

## Direct API key connections

The direct-key connection fixture in [[Tests/BrowseTests/AIChatTests.swift]] verifies validation before saving, separate credentials, provider switching, model filtering and pagination, direct inference hosts and headers, restoration, and removal without affecting other keys.

## Connection test

The connection-test fixture in [[Tests/BrowseTests/AIChatTests.swift]] verifies real model invocation with only a fixed test prompt, success and sanitized failure feedback, model-change invalidation, and rejection while disconnected.

## Saved conversations and restoration

[[Tests/BrowseTests/ChatHistoryTests.swift#savedChatRestoration]] verifies messages, drafts, panel visibility, and layout survive closing and reopening, and history restoration creates independent panes with remapped citations and retained split fractions.

Opening or reusing chat history gives its sidebar tab the AI Chat History title. Restoring an older session with the generic New tab label repairs that title before the page mounts.

## Deleting saved conversations

[[Tests/BrowseTests/ChatHistoryTests.swift#savedChatDeletion]] clears a streaming conversation and verifies delayed completion cannot recreate its messages or saved file. Private stores cannot open history or persist sessions.

## Browser state clearing ranges

[[Tests/BrowseTests/ChatHistoryTests.swift#browserStateClearingRanges]] verifies rolling time boundaries, preservation of older visits and chats, deletion tombstones, persistence after clearing, and separate WebKit cache and site-data categories.

## Closing tabs with saved chats

[[Tests/BrowseTests/ChatHistoryTests.swift#closingTabsWithChatsAndExtensions]] closes selected and final tabs with open chats and an active extension manager, verifying valid replacement selection, extension activation, archived conversations, and debounced session persistence.

## Clearing open browser windows

[[Tests/BrowseTests/ChatHistoryTests.swift#clearingOpenBrowserWindows]] verifies Privacy closes regular and private windows including pinned tabs, clears a previously closed root’s fallback session, and restores only a blank tab while retaining unselected history and chats.

## Chat panel resizing

[[Tests/BrowseTests/ChatHistoryTests.swift#chatPanelResizing]] verifies mirrored native drag tracking, repeated pointer positions, bounds, independent sidebar width, saved-width restoration, and invalid-width handling on both sides.

## Action approval boundaries

[[Tests/BrowseTests/AISecurityTests.swift#aiActionApprovalBoundaries]] verifies denied navigation, clicking, and filling have no side effects, and unobserved attribute probes fail identically before DOM lookup. Changed elements, permissions, navigation revisions, and pane membership invalidate approval.

## Inline action confirmation

[[Tests/BrowseTests/AISecurityTests.swift#aiInlineActionConfirmation]] verifies actions wait for explicit approval, Skip and cancellation leave the page unchanged, and duplicate or stale request IDs cannot release another action.

## Page read field privacy

[[Tests/BrowseTests/AISecurityTests.swift#aiPageReadFieldPrivacy]] excludes password values, textarea drafts, editable content, and select contents from page text and ancestor labels without modifying the live page.

## Untrusted read cursor presentation

[[Tests/BrowseTests/AISecurityTests.swift#aiUntrustedReadCursorPresentation]] verifies extreme, negative, and malformed model-supplied cursor indices cannot crash transcript rendering before tool validation.

## Malformed loopback connections

[[Tests/BrowseTests/AIOAuthTests.swift#aiOAuthMalformedConnections]] verifies repeated oversized requests cannot exhaust OAuth callback connection slots and prevent a subsequent legitimate sign-in callback.

## Chat approval lifecycle

[[Tests/BrowseTests/AISecurityTests.swift#aiChatApprovalLifecycle]] verifies a real agent turn pauses at its tool bubble, only an open active chat can approve it, and stopping or restoring a conversation cannot revive pending actions. Native Escape first clears a recalled prompt, then cancels a pending run.

## Composer keyboard controls

[[Tests/BrowseTests/ChatComposerTests.swift#chatComposerKeyboard]] exercises native Enter and Shift-Enter insertion at the cursor, Command-Enter submission, disabled sending, protection of active input-method composition, and local prompt history selection, traversal, editing, and Escape clearing.

## Expanded tool card layout

[[Tests/BrowseTests/ChatComposerTests.swift#chatExpandedToolLayout]] verifies long expanded tool contents scroll inside a bounded viewport while approval controls and the composer remain outside it. An opt-in capture supports visual inspection.

## Creating panes from chat

[[Tests/BrowseTests/AISecurityTests.swift#aiCreatePaneApproval]] verifies pane creation waits for approval, preserves the source, and returns the new pane’s metadata within the same tab.

Denied, cancelled, disabled, and stale-source actions leave the layout unchanged. Unsafe URLs and foreign pane IDs are rejected. The advertised tools and prompt accurately reflect live disabled-tool settings.

## Chat composer window spacing

[[Tests/BrowseTests/ChatComposerTests.swift#chatComposerWindowSpacing]] checks equal bottom and outside composer gaps on both window edges across supported panel widths, plus a transcript viewport extending beneath the floating composer.

The header has no overlay material. Scrolling keeps the clear-glass composer fixed; its native background blocks underlying links while the input remains clickable. Assistant text respects the 90% width cap, and the last message scrolls above the composer. An optional snapshot supports visual inspection.

## Recalled prompt appearance

[[Tests/BrowseTests/ChatComposerTests.swift#chatHistoryAppearance]] compares single-line and multiline prompts inserted normally versus recalled with Up/Down, including attributes, full selection, and native editor height.

Clearing recalled text and typing again must retain the same editor styling.
