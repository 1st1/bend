---
lat:
  require-code-mention: true
---
# Address entry and search tests

Tests verify address resolution, search providers, and the location popup.

See [[lat.md/architecture/address-entry|Architecture and behavior]].

## Address resolution

Hostnames, HTTPS, localhost, internal pages, and searches resolve correctly. Empty input and explicit non-web schemes are rejected. Google, DuckDuckGo, and Kagi preserve query punctuation, literal plus signs, and Unicode.

## Location popup requests

[AddressRequestTests.swift](../../Tests/BrowseTests/AddressRequestTests.swift) verifies that explicit location requests target the chosen pane, new blank panes prompt after focus changes, and link destinations do not prompt. Invalid pane IDs are ignored.

The store tests use an isolated temporary session-file path. They cover both split directions, blank tabs, and the replacement tab created after closing the final tab. Each automatic request must identify the newly focused pane.

Explicit requests for an existing pane focus that pane; invalid identities produce no request. Opening a link in a right-hand pane or a tab with a supplied URL must not request location entry. These tests exercise store events without instantiating the popup or loading WebKit pages.

## Canceling new tab entry

[AddressRequestTests.swift](../../Tests/BrowseTests/AddressRequestTests.swift) verifies that canceling initial blank-tab or split-pane entry restores the previous focus, layout, and zoom without recording a closed item.

Both split directions restore a non-first source pane, preserve its controller, and dispose of the provisional controller. The saved session excludes canceled panes and tabs; a pane that has navigated is retained. Existing tabs, completed entry, tabs with added panes, and tabs opened with a destination cannot be discarded through this path.

## New tab popup keyboard cancellation

[AddressRequestTests.swift](../../Tests/BrowseTests/AddressRequestTests.swift) exercises Escape and Command-W through the native popup and application menu after creating a tab or using Command-D and Shift-Command-D.

Both commands dismiss the popup and remove the initial blank pane or tab even after unsubmitted editing. Existing-pane Escape, outside dismissal, and successful submission retain their content. The placeholder uses the system placeholder text color.

## Pane-centered location popup

[AddressRequestTests.swift](../../Tests/BrowseTests/AddressRequestTests.swift) verifies that location popups center horizontally on their target pane, start one-fifth down it, and retain their initial top edge while open.

The native-view regression covers separate left/right targets, result growth and shrinkage, validation errors, pane resizing and clipping, fresh placement after reopening, and retaining the fallback top when a pane mounts later.

## Search engine preference

[[Tests/BrowseTests/AddressRequestTests.swift#searchEnginePreference]] verifies the Google default, shared choices across regular/private windows, immediate search routing in an existing page controller, and persistence after restoring the session, including a named custom engine.

## Custom search templates

[[Tests/BrowseCoreTests/SessionTests.swift#customSearchTemplates]] verifies template validation, path/query substitution, preserved fixed parameters, Unicode and punctuation encoding, and rejection of invalid configurations without sending searches to another engine.
