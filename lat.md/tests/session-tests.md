---
lat:
  require-code-mention: true
---
# Session lifecycle tests

Tests verify mounted tab ownership, saved sessions, and reopening closed layouts.

See [[lat.md/architecture/session|Architecture and behavior]].

## Mounted tab switching

[TabSwitchingTests.swift](../../Tests/BrowseTests/TabSwitchingTests.swift) switches between real offscreen WebKit tabs and verifies native parents, document identity, unsaved input, and scroll position survive.

Document identity is checked with an injected JavaScript marker and unsaved DOM state, rather than a wall-clock-derived performance timestamp. The test uses local HTTP fixtures and ephemeral storage in a full-content window with a unified toolbar. It checks that the titlebar adds no extra top inset. Narrowing and widening columns verifies CSS viewport width matches the native web view, media queries switch layouts, and resize events fire. Both the HTTP request received by the fixture and JavaScript expose Safari-compatible product tokens plus Bend’s identifier. Unvisited tabs remain uncreated, hidden tabs keep their viewport and ignore other tabs' zoom, selection resizes the active host, and tab or background-pane closure removes retained content.

After switching back beneath a later-mounted hidden tab, the test verifies the inactive hosting root rejects hit tests and each visible pane's center resolves to its web view in None, Transparency, Outline, Outline glow, and Title tint modes. Switching highlight styles preserves the same WebView and native parent. On macOS 26 and later, the web surface reaches the pane’s top edge without a border inset. The test also sends a complete mouse gesture through the window: header press, drag across nine interior points of a real web view, and release. Each point activates the target preview; release rearranges the panes and removes the drag surface while preserving native WebKit parents, document identity, and unsaved input.

The pane and WebView frames stay identical across all focus styles, including Outline with the maximum gap and thickness; decorations consume no layout space.

## Session round trip

JSON encoding and decoding preserve the selected tab and nested layout. Restore validation rejects missing pages and selected tabs that do not exist.

## Reopening nested pane layouts

[ReopenTests.swift](../../Tests/BrowseTests/ReopenTests.swift) verifies exact split restoration without intervening changes and preserves new panes and divider fractions when reopening into an edited layout.

Restoration uses the nearest surviving ancestor when the original sibling is gone, retaining pane order and split direction.

## Closed pane and tab history

[ReopenTests.swift](../../Tests/BrowseTests/ReopenTests.swift) verifies a unified last-closed-first history, original workspace selection, focus, zoom clearing, saved URLs, and preservation of subsequent pane edits.

Closing a pane and then its tab reopens them in reverse order without duplicate pages or blank replacement tabs. Reopened layouts persist as valid sessions; closed-item history does not persist.

## Reopen boundaries and background closures

[ReopenTests.swift](../../Tests/BrowseTests/ReopenTests.swift) checks background extension closures, final-pane tab closure, invalid pane IDs, preservation of navigated replacement tabs, and the fifty-entry history limit.

## Flat tab list restoration

[ReopenTests.swift](../../Tests/BrowseTests/ReopenTests.swift) verifies legacy groups merge in order without losing selection, pane identities, layouts, or URLs. New tabs append to the list; close/reopen and saving preserve the single-group session.
