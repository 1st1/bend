---
lat:
  require-code-mention: true
---
# Find in page tests

Tests verify native find controls and WebKit text matching.

See [[lat.md/architecture/find|Architecture and behavior]].

## Find in page

[FindInPageTests.swift](../../Tests/BrowseTests/FindInPageTests.swift) exercises the Command-F menu against real WebKit documents, checking focused-pane routing, case-insensitive matches, next/previous wrapping, scrolling, header clearance, Escape dismissal, and disabled internal-page commands.

Actual window mouse clicks on the shared-style find buttons navigate forwards and backwards and dismiss the bar, clearing highlights and returning focus to the web page.

Layout assertions verify that the input keeps its frame across empty, pending, matching, and zero-result states, including at minimum pane width. Empty focused and cleared input keep the caret beyond the search icon and vertically inside the field, including at minimum width. The count stays right-aligned inside the field without overlapping the native text editor. Return and Find Next retain the count while navigating; editing the query immediately clears the old total.

On macOS 26 and later, the find controls share the native title glass without a separate material. Opening and closing adjust the visible header height and WebKit inset together; style and tint changes preserve the field editor and control parentage. Switching repeatedly between solid and glass hides the unused background, preserves the chosen solid color, and keeps find geometry, control parents, and WebKit insets unchanged. The glass extends above and below a clipping container to hide its top and bottom rims, while controls retain the visible header's coordinates. Live top- and bottom-clipping changes at zero, fractional, and maximum values preserve the find row, field editor, and WebKit inset. Active-pane tint spans the combined header, covers the find row, stays absent from inactive panes, and clears without removing the controls.

Match-count assertions cover case-insensitive totals, hidden-text exclusion, zero and empty queries, and matches inside an iframe. Dismissal checks clear main-frame and iframe selections, preserve scroll, and reject late count results; reopening searches the retained query again. Repeated Escape presses after dismissal still reach page key listeners without crashing. Cancellation is also safe with no bar or before mounting a web view.
