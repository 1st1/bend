# Address entry and search

Address resolution, search providers, and the location popup.

See [[lat.md/tests/address-entry-tests|Test coverage]].

## Address handling

[Session.swift](../../Sources/BrowseCore/Session.swift) resolves web addresses, localhost development URLs, built-in start pages, and search queries. Explicit non-web schemes are rejected; search text uses the selected [[lat.md/architecture/address-entry#Search engine preference|search engine]].

Bare hostnames containing dots use HTTPS, while localhost and loopback IPv4 addresses use HTTP. [BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) also limits WebKit navigation to web URLs and internal blank documents.

## Location popup

[AddressPanelController.swift](../../Sources/Browse/AddressPanelController.swift) owns a floating command-palette-style location panel. A rounded search field, compact history rows, and a shortcut footer sit within a frosted shell. URL entry remains separate from pane chrome.

Command-L opens the popup for the focused pane, with its current URL selected (blank for start pages). Favorites open a different-origin destination in a new regular tab through [[Sources/Browse/BrowserFavorites.swift#BrowserStore#openLocation]]. Other entries navigate the focused pane using the [[lat.md/architecture/address-entry#Address handling|address resolver]]; invalid input stays open with an error that clears when editing resumes.

[AddressPanelController.swift](../../Sources/Browse/AddressPanelController.swift) displays [[lat.md/architecture/history#History suggestions]] beneath the input. Arrow keys select results, Return opens the selection, and clicking a result opens it. Eligible URL prefixes autocomplete with the added suffix selected; deletion, marked text input, and edits away from the end suppress autofill.

Opening the popup shows frequent/recent pages while retaining the current address selected for editing. Typing shows up to six history matches alongside an explicit visit/search action. Inline URL matches become the selected top result; other queries keep the explicit action selected. History updates preserve selection when possible. Each history row has a Remove from history button that deletes all visits and learned choices for its URL, saves immediately, and removes stale suggestions without navigating or closing the popup. Results sit directly beneath the input with compact spacing; validation errors reserve extra space only while visible.

The popup is a borderless child panel centered horizontally on its target pane's visible native bounds, including start pages. On opening, its top edge sits one-fifth down the pane. That top position stays fixed relative to the window's top for the entire presentation: result counts, validation messages, pane resizing, scrolling, and delayed mounting cannot shift the input vertically. Reopening or targeting another pane establishes a new top position. Its width adapts to the pane, with a readable minimum; long results scroll within the space below the anchored top. Until a pane is mounted, browser content bounds supply the initial fallback position. [[lat.md/tests/address-entry-tests#Pane-centered location popup]] covers pane targeting, fixed-top resizing, validation errors, partial visibility, and delayed mounting. It uses native Liquid Glass with its own rounded rim and backdrop, accepts keyboard focus without becoming the main window, supports full-screen use, and hides when the app deactivates. A compact, softly filled search field includes a magnifying glass and a secondary placeholder. The footer shows arrow-key navigation, Escape dismissal, and Return submission hints beneath a faint separator.

The native glass view owns the backdrop, rounded edge, and content placement without an opaque darkening overlay. An outer rounded container clips the complete glass compositor to prevent a rectangular edge outside its corners; resizing refreshes the window shadow. Regular-weight result titles, compact two-line rows, a narrower panel, and subdued shortcut hints keep the surface light while retaining titles and URLs.

Selected suggestions use the system selected-content background and matching list-selection foreground for titles, URLs, icons, and history-removal buttons, without reducing foreground opacity. [[Sources/Browse/AddressPanelController.swift#AddressPanelController#configureEditorSelection]] explicitly pairs the system selected-text foreground and background for the input, including the selected autocomplete suffix. Two-line rows retain both page titles and URLs. Selection leaves keyboard focus in the address input; the panel remains horizontally centered and resizes downward from its fixed top edge.

Escape dismisses an existing tab’s popup and returns keyboard focus to the browser, as does successful submission. During a new blank tab or split pane’s initial address entry, Escape or Command-W discards both the popup and the new item and adds nothing to closed-item history. Canceling a split removes it from the layout and restores the previous pane focus and zoom; canceling a tab restores the preceding tab and zoom. Typed but unsubmitted text still counts as initial entry. Successful submission or outside dismissal commits the pane or tab; opening its popup again does not make it disposable. Existing panes, link-created panes, new-window initial tabs, and last-tab replacements are retained. [[lat.md/tests/address-entry-tests#Canceling new tab entry]] and [[lat.md/tests/address-entry-tests#New tab popup keyboard cancellation]] cover the boundaries. Losing key-window status dismisses it without reclaiming focus, allowing outside clicks to select another pane or application normally.

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) requests the popup after creating blank split panes, tabs, or a replacement for the last closed tab. Link-created panes and tabs already have a destination and do not prompt. Popup requests validate pane identity; submitting after the target has closed or left the selected tab cannot navigate another pane.

[BrowserWindows.swift](../../Sources/Browse/BrowserWindows.swift) connects each store's location-request callback to the panel controller. Requests carry a pane identity after the store has updated selection and focus, so presentation does not depend on a newly created SwiftUI pane observing an earlier event.

## Search engine preference

[[Sources/BrowseCore/SearchEngine.swift#SearchEngine]] defines Google, DuckDuckGo, Kagi, and custom search destinations. Google remains the default for existing and new profiles.

Settings → Search offers a search engine picker. [[Sources/Browse/BrowserStore.swift#BrowserStore#searchEngine]] persists the choice in the session and shares it across regular and private windows. Existing pages are not reloaded; subsequent searches use the current choice, including controllers created before it changed. The location popup names the selected provider. Explicit URLs, internal pages, and history selections keep their original destinations.

[[Sources/BrowseCore/SearchEngine.swift#SearchEngine#searchURL]] encodes the query as one parameter, escaping literal plus signs for provider form decoding. Kagi uses its [documented search endpoint](https://help.kagi.com/kagi/getting-started/setting-default.html); authentication is handled by the website. [[lat.md/tests/address-entry-tests#Address resolution]] covers URLs and encoding; [[lat.md/tests/address-entry-tests#Search engine preference]] covers persistence and navigation across windows.

Settings → Search also offers Custom with a name and URL template. [[Sources/BrowseCore/SearchEngine.swift#CustomSearchEngine]] requires a nonempty name and an HTTP(S) template containing exactly one `%s` in the path or query, without credentials or fragments. Invalid templates cannot be saved or tested. Save applies the configuration; edits leave the active configuration intact until saved. Test Search opens a new Bend tab for “Bend browser” without changing the active engine. Fixed URL parameters survive substitution, while query text is encoded as one component. The saved custom configuration remains available when switching to a built-in engine. [[lat.md/tests/address-entry-tests#Custom search templates]] covers validation and substitution.
