# Find in page

Native find controls and WebKit text matching.

See [[lat.md/tests/find-tests|Test coverage]].

## Find in page

[WebSurfaceHost.swift](../../Sources/Browse/WebSurfaceHost.swift) hosts a compact AppKit search bar per web pane, using WebKit's public find API for matching, selection, and scrolling.

On macOS 26 and later, the controls sit in a transparent row over the title's shared native header background. [FindToolbarButtons.swift](../../Sources/Browse/FindToolbarButtons.swift) hosts previous, next, and close actions with the same semantic colors, 24-point pitch, and circular hover treatment as title controls, aligned to their trailing edge. Navigation buttons are disabled for an empty query. The native search field retains its clear button and editor, with a custom six-point rounded rectangular bezel and matching system focus ring. The cell keeps native bezeled-field layout metrics while overriding only its drawing, preserving icon, placeholder, and caret spacing. The header expands on opening and contracts on dismissal, using the same glass appearance or solid gradient for both rows. Active-pane title tint covers both rows behind their controls and clears on focus loss. Appearance updates retain the field editor and existing controls. The legacy separate standard-material row is outside the supported OS range.

[BrowseApp.swift](../../Sources/Browse/BrowseApp.swift) routes Command-F, Command-G, and Shift-Command-G to the focused pane of the active browser window, excluding other key windows. Internal start/history pages and error views disable these commands. The bar sits beneath the pane header and reserves page viewport space. Search is case-insensitive, updates while typing, wraps in both directions, and displays a native match total (including zero). Counts above the bounded search limit display “10,000+ matches.” Return and Shift-Return advance forwards and backwards; Escape or the close button dismisses the bar and returns focus to the page. Dismissal and empty queries clear the native find indicator and search selection without resetting scroll. Reopening with a retained query searches again; next/previous commands also reopen a hidden bar.

[BendFindSupport.m](../../Sources/WebKitFindSupport/BendFindSupport.m) isolates optional private WebKit selectors in a typed Objective-C adapter: native match counting, clearing the find selection with an empty native search, and hiding find UI. Counting uses the same case-insensitive engine across frames, excludes non-searchable text, and caps work at 10,000 matches. Runtime selector checks preserve public search if SPI is unavailable; the total is omitted instead of guessed. Cleanup falls back to clearing document selections in the main and same-origin frames if native clearing is unavailable. This adapter requires compatibility checks when WebKit changes and is not a public-SDK-only implementation.

Each mounted pane retains its query and bar state. Navigation dismisses the bar; replacing its WebView invalidates pending results. Completion generations prevent stale search/count results from changing current status; count replies are paired with queued requests in query order. Replacement detaches the optional count delegate. Find actions and bar visibility enter optional pane diagnostics without recording the query. [[lat.md/tests/find-tests#Find in page]] covers search and keyboard routing.

Escape delivered to the web pane dismisses an open find bar. With no bar, cancellation is a no-op, including for detached views. Neither native view calls the optional superclass cancellation action, which has no implementation. WebKit still delivers Escape key events to page content.

The match count sits inside the search field, right-aligned before the native clear button. A custom search cell reserves trailing space for both drawn text and the field editor, even while results are pending. Monospaced digits keep counts stable; narrow fields limit the count area to preserve editable space.

Moving between matches for the same query keeps the count visible while refreshing it for possible page changes. Editing the query clears the previous total until the new result arrives; dismissal and empty queries also clear it.
