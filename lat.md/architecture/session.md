# Session lifecycle

Mounted tab ownership, saved sessions, and reopening closed layouts.

See [[lat.md/tests/session-tests|Test coverage]].

## Reopening closed panes and tabs

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) keeps the last fifty pane or tab closures in one in-memory stack. Command-Shift-T reopens the most recent item and selects its original tab and workspace.

[BrowseApp.swift](../../Sources/Browse/BrowseApp.swift) exposes Reopen Closed Pane or Tab in the File menu, disabled when the stack is empty. Closing the final pane records one whole-tab closure; extension-requested pane closures use the same history. Reopening clears zoom and the location popup. Closed views are released: restoration uses saved URLs and identities, without recovering page forms, scroll positions, or back-forward lists. Closed-item history is discarded on restart; reopened layouts are saved normally.

[Session.swift](../../Sources/BrowseCore/Session.swift) restores the original split tree when the remaining layout is unchanged. Otherwise it inserts the closed pane beside the nearest surviving sibling, retaining subsequent splits, divider changes, and surviving page URLs. If no sibling remains, the pane opens beside the focused pane. Whole tabs return at their saved index. An unused blank tab created automatically after closing a workspace's last tab is removed on reopen; a replacement that has been navigated, split, or pinned is retained.

## Mounted tab views

[MountedTabContent.swift](../../Sources/Browse/MountedTabContent.swift) retains a native hosting view for each visited tab, hiding inactive containers instead of rebuilding the pane canvas on selection.

Unvisited tabs stay lazy. Inactive content remains natively hidden while its pane and WebKit parent views stay attached. The tab hosting view explicitly returns no hit when it or an ancestor is hidden, before entering SwiftUI hit testing: a hidden SwiftUI root can otherwise claim events intended for the visible page. Hidden containers retain their last viewport; selection applies the current size. Closed tabs release their containers, and closed panes are removed from retained trees. Focus moves out of a hidden canvas without taking focus from unrelated controls.

Tab and pane hosting views disable inherited safe-area regions: the window shell supplies their margins, so the unified titlebar must not insert extra space above nested content.

[BrowserView.swift](../../Sources/Browse/BrowserView.swift) renders each retained canvas from its own tab model. Pane focus and window controls belong to that tab, and another tab's zoom cannot replace its layout. A cross-tab pane transfer reattaches the existing web view to the destination host without navigating or replacing its controller. Retention avoids reparenting and zero-sized WebKit layout during ordinary tab switches; it does not prevent WebKit process termination or pages' own background behavior. [[lat.md/tests/session-tests#Mounted tab switching]] verifies native parent identity and document state.

## Session restoration

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) debounces atomic JSON saves to the app’s Application Support directory and saves on normal termination. [Session.swift](../../Sources/BrowseCore/Session.swift) checks restored tab, focus, and pane identity consistency before accepting state.

[BrowserWindows.swift](../../Sources/Browse/BrowserWindows.swift) saves the open regular-window IDs in `windows.json`. The legacy primary layout and shared preferences remain in `session.json`; additional windows save separate `Windows/<UUID>.json` sessions. With no window manifest, startup restores the legacy window. Normal quit saves the whole open set before native teardown. Closing one of several windows removes it from the manifest; closing the final window retains it for the next launch. [[lat.md/tests/windows-tests#Browser window restoration]] covers both paths.

Persistence retains the workspace envelope for compatibility, plus selected tab, URLs, focused panes, and split trees. On load, [BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) combines legacy workspaces into one in their existing tab order, preserving tab and pane identities, layouts, URLs, and selection. New sessions start with one workspace; group names are not displayed. Restarting recreates web views from URLs; in-page state and back-forward lists are only retained during the running process. Invalid session files fall back to the initial workspace. Save failures appear in the sidebar.
