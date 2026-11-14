# Native AI chat

Native chat works with all website panes in one tab through Vercel AI Gateway, using the local [[Vendor/ai-swift]] package. See [[lat.md/tests/ai-tests|AI tests]].

## Tab conversations

[[Sources/Browse/TabChat.swift#TabChat]] owns a tab's in-memory conversation, streamed bubbles, model selection, and cancellable agent run.

The Chat command in [[Sources/Browse/BrowseApp.swift#AppDelegate#popupCommands]] opens [[Sources/Browse/ChatSidebar.swift#ChatSidebar]] on the right. Its transparent background exposes the shared [[lat.md/architecture/sidebar#Sidebar materials|window glass]], matching the tab sidebar. The transcript is clipped to its scroll viewport so messages cannot draw over the fixed header or composer. [[Sources/Browse/ChatSidebar.swift#ChatHeader]] uses shared sidebar sizing and alignment. Native controls are positioned above the unified toolbar, which otherwise intercepts clicks and hover in the titlebar strip; SwiftUI anchors own their lifetime, while the controls are pinned to the window’s trailing edge and shared header centerline across resizing and sidebar transitions. The window routes header mouse presses and releases to these controls before AppKit can consume them as toolbar events. The transcript also bounds hit testing to its viewport. The header omits the Chat title and sparkles, offering a labelled Clear chat control and an × close button on the shared centerline. It has no bottom divider and an empty transcript shows no introductory text. The standalone composer reuses [[Sources/Browse/BrowserView.swift#PaneChromeBackground|the shared pane glass surface]] with all four corners rounded and no header-overlap clipping or close button; the searchable model selector sits below the input on the left, opposite Send/Stop. [[Sources/Browse/BrowserView.swift#BrowserView]] shrinks the retained pane canvas to make room without rebuilding WebViews. Closing the sidebar retains its conversation and an active run; switching tabs selects that tab's independent chat. New chat clears completed history. Closing a tab or window cancels its runs and releases chat state. Duplicated tabs start without conversations. Chats are not serialized, including in private windows.

Agent calls use the vendored Swift package's streaming agent loop with serial tools and bounded model steps. Successful turns retain tool history for follow-ups. [[Vendor/ai-swift/Sources/AI/Agent.swift#Agent#run]] normalizes blank arguments to an empty JSON object only for explicitly parameterless tools after a complete response; normalized history is sent on subsequent turns. Malformed JSON and missing required inputs remain tool errors. Cancellation and errors preserve partial visible text and append an interruption marker without dangling or replayed tool calls. Disconnecting Gateway cancels active chats. Provider errors are summarized without exposing raw response bodies or credentials.

## Gateway connection

[[Sources/Browse/AISettings.swift#AISettings]] shares Gateway connection state across windows. Settings → AI validates an API key against Gateway's credit endpoint before saving it in Keychain.

[[Sources/Browse/AISettings.swift#GatewayCredential]] uses the current build profile's Keychain service, keeping debug credentials separate from production. The key is loaded lazily when AI UI opens, never stored in session JSON or defaults. Disconnect removes it. Gateway HTTP uses ephemeral sessions without cookies, credential storage, or redirects. The model catalog is fetched live, restricted to tool-capable language models excluding batch variants. The preferred model persists in profile preferences and initializes new chats; a chat-specific selection does not change that preference. New chat resets to the preferred model. Catalog refresh preserves an explicit preference. [[Sources/Browse/AIModelPicker.swift#AIModelPicker]] supplies a searchable popover in Settings and the composer, matching model names and IDs.

Settings → AI exposes the full [[Sources/Browse/AISettings.swift#AISettings#defaultSystemPrompt|default system prompt]] in an editable text area. The default identifies the assistant as part of Bend, a native macOS browser based on Apple’s WebKit engine. Edits persist in profile preferences and apply to the next message in any chat, while a running turn retains its original prompt. Reset to Default appears only for changed text and removes the stored override. [[Sources/Browse/TabChat.swift#TabChat#send]] supplies one system template per run, separate from retained conversation history. The `${panes}` placeholder is expanded by [[Sources/Browse/TabChat.swift#PaneContextProvider]] before every model request, including tool follow-ups. It contains only this tab’s live pane IDs, titles, URLs, citation URLs and active-pane flag, labelled as untrusted metadata. If a custom prompt omits the placeholder, context is appended. Pane listing requires no model tool call.

Authentication currently uses a user-created Gateway API key, with a dashboard link in Settings; browser OAuth is not implemented. Messages and requested page content go to Gateway and the selected provider. Connection failures remain visible and retryable. Authentication and model discovery do not generate billable completions.

## Pane tools

[[Sources/Browse/TabChat.swift#PaneChatTools]] exposes bounded main-frame reading, navigation, clicking, and filling through a fixed tab identity and live pane membership checks.

Settings → AI lists every tool with an independent switch. [[Sources/Browse/AISettings.swift#AISettings#setToolEnabled]] persists disabled tools in profile preferences. Disabled tools are omitted from new runs and checked again at execution time, including calls already advertised by a running agent. All tools default on; all may be disabled. The former list_panes tool is replaced by live system-prompt context.

Tools cannot access another tab's panes, native browser pages, files, or extension documents. Navigation accepts HTTP(S) URLs without embedded credentials. Page reads return bounded text and element selectors without input values; they do not inspect frames or images. Click and fill require a unique selector. Fill rejects password, payment, and token fields and does not submit. JavaScript arguments are passed separately in WebKit's isolated client world. Tools check cancellation before work and membership again after asynchronous reads.

Reads paginate a stable snapshot with up to 24,000 Unicode code points, 100 interactive elements, and 100 citation references per chunk. The optional cursor advances through the snapshot; has_more and next_cursor report continuation. Starting without a cursor replaces the snapshot. Navigation or a replaced snapshot invalidates old cursors. Snapshots live in WebKit’s isolated client world and do not scroll the page. Chunks explicitly distinguish remaining metadata from page text. Expanded tool results are labelled as previews when capped at 12,000 characters; the model receives the complete chunk. The tool description and default prompt instruct the agent to continue through relevant chunks before summarizing.

The agent is instructed to treat page content as untrusted, act only on user requests, and ask before consequential submissions. These are model instructions rather than a separate approval UI. Tools operate on the current live page, so the model must re-read after navigation or interaction. A loading page returns a recoverable tool error.

## Markdown messages

[[Sources/Browse/ChatMarkdown.swift#ChatMarkdown]] renders assistant responses as native selectable Markdown while user messages remain literal text.

Swift Markdown parses each streamed response into headings, paragraphs, nested ordered and unordered lists, task lists, quotes, thematic breaks, code blocks, and tables. Each response uses one attributed NSTextView so selection and copying span all paragraphs and blocks. Code wraps within the bubble and table cells use tab-separated columns. Streaming updates preserve the selected range. Inline emphasis, strong text, strikethrough, code, and HTTP(S) or mail links retain their formatting. Raw HTML is displayed literally and images use descriptive text without fetching remote content. Incomplete streamed link destinations are withheld while the readable label appears progressively, so pane UUIDs and encoded URLs never flash as ordinary text. Complete links retain their routing targets. Native text updates replace only the changed attributed suffix, preserving the unchanged prefix and selection instead of resetting the entire text storage. Code spans/fences remain literal.

## Page citations

[[Sources/Browse/ChatPageLinks.swift#ChatPageLinks]] routes chat links within their originating tab, and the default prompt encourages descriptive links to useful page passages.

Pane listing and page reads return references carrying a pane ID and an HTTP(S) destination URL. Section references use real page anchors from observed IDs or named anchors. On click, Bend checks tab membership and the destination scheme, then navigates that exact pane through WebKit, including the fragment. It does not query selectors or inject scrolling JavaScript, and can navigate back to the cited page after a pane changes. Older selector-based references request a fresh link. Ordinary HTTP(S) links focus a matching page in this tab or open a neighboring pane. Custom system prompt overrides remain unchanged.


## Transcript scrolling

[[Sources/Browse/ChatInlineText.swift#ChatScrollFollow]] suspends automatic bottom-following during user scrolling and keeps the reading position when the user stops above the latest response.

Returning to the bottom or pressing Latest resumes following streamed text. Stable transcript layout avoids lazy row height estimation during updates. [[Sources/Browse/ChatInlineText.swift#ChatInlineText]] uses selectable native text with an explicit link delegate forwarding clicks to the chat's URL handler, including pane citation schemes.

## AI debugging

[[Sources/Browse/AIDiagnostics.swift#AIDiagnostics]] provides opt-in local tracing through Settings → Development, with immediate persistent enablement and controls to reveal or clear the logs.

Run and tool lifecycle events and citation clicks, navigation targets and failures share timestamps, process-run IDs, sequence numbers, and tab/pane identities. Prompts, response bodies, tool input text, credentials, URL query values, and fragments are excluded; URL paths and exact citation selectors remain available for diagnosis. Nothing is uploaded. The shared bounded file writer stores ai.jsonl and ai.previous.jsonl in the profile's AIDiagnostics folder, each capped at 500 KiB. Disabling drains writes and preserves existing logs; clearing removes both segments.

## Streaming transcript

[[Sources/Browse/TabChat.swift#TabChat#consume]] displays tool calls with running, completed, error, or stopped state and collapsible arguments and bounded results in conversation order.

Tool calls use compact, content-width capsule buttons with a subtle fill and border. Search queries and page-read ranges appear inside the pill; Read page is singular and shows a chunk number until the result supplies its exact character range. Metadata-only chunks are labelled separately. Clicking a pill expands its details below; tool status appears as a small progress or result icon. Assistant text bubbles begin with the first nonempty text delta; no placeholder bubbles are created between model steps. Bend requests provider-supported reasoning summaries from the native adapters. Known recent Claude models use adaptive summarized thinking, older Claude 4 models use a bounded budget, and supported OpenAI models use automatic summaries. Astra requests high reasoning effort so Gateway supplies summary text; this may increase response latency and token use. Only the latest nonempty paragraph of the returned thinking summary appears as a rolling text block beneath tool calls until the answer starts, then immediately above its response bubble. That position remains fixed during streaming and late tool metadata updates. New steps replace its contents when their summaries arrive; completion retains it, while a new request or clearing chat resets it. The UI neither synthesizes reasoning nor requires models to expose it. [[Sources/Browse/AIModelSearchField.swift#AIModelSearchField]] routes native search-field Up/Down, Return, and Escape commands to highlighted model selection, submission, and dismissal; filtering resets the highlight and keyboard selection scrolls into view.

## Web search

[[Sources/Browse/AISettings.swift#AISettings]] persists a Web Search switch, enabled by default, which applies to subsequent chat turns through [[Sources/Browse/TabChat.swift#TabChat#send]].

The SDK chooses Anthropic Messages for Claude and OpenAI Responses for OpenAI models, both through Vercel Gateway with the existing key and billing. Other models retain Gateway-hosted Perplexity search. For other providers, reported server-tool counts appear as completed disclosures without invented queries or sources. Native search events update pills by server call ID, with query text, status, errors, and clickable source titles/domains. Responses retains encrypted reasoning and output items, except Gateway-incompatible search replay items which become reported query/source context; Messages retains signed reasoning and search blocks for follow-ups to the same model. These opaque payloads are never displayed. External answer and source links use the existing tab-scoped link routing. Turning search off omits it from subsequent turns without cancelling an in-flight request.
