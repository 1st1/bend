---
lat:
  require-code-mention: true
---
# Link navigation tests

Tests verify modified clicks, link context menus, and destination previews.

See [[lat.md/architecture/link-navigation|Architecture and behavior]].

## Link pane placement

Opening a link splits its source pane to the right even when another pane is focused, preserves neighboring branches and the source URL, and focuses the destination. The result survives serialization; missing source panes leave the tab unchanged.

## Command-click navigation

[LinkNavigationTests.swift](../../Tests/BrowseTests/LinkNavigationTests.swift) verifies that WebKit's Command-left-click action opens a pane and cancels source navigation. Ordinary clicks, other buttons, and scripted navigation do not open panes; custom schemes remain blocked.

## Command-click new-window links

[LinkNavigationTests.swift](../../Tests/BrowseTests/LinkNavigationTests.swift) verifies that Command-clicking a new-window link opens a pane without creating a tab. An ordinary new-window link still creates a tab.

## Configurable link destination

[LinkNavigationTests.swift](../../Tests/BrowseTests/LinkNavigationTests.swift) verifies live Command-click destination changes on an existing controller, adjacent placement, source preservation, ordinary new-window behavior, and main-frame opener tracking.

Link-created tabs insert immediately after the active tab, ahead of existing later tabs, for both Command-click and ordinary new-window links.

## Dedicated Command-click pane

[LinkNavigationTests.swift](../../Tests/BrowseTests/LinkNavigationTests.swift) verifies one reusable link destination per tab, including stable pane and WebView identity across repeated links.

Clicks from different source panes reuse the target, independent tabs receive independent targets, and iframe/self links avoid stale or self-referential openers. Closing, reopening, replacing, restarting, and switching settings preserve the intended designation and page counts. Closing all ordinary panes promotes the surviving destination without replacing its WebView; the next link creates a new reusable target. Legacy single-pane designations are cleared on restoration.

## Command-click preference migration

[LinkNavigationTests.swift](../../Tests/BrowseTests/LinkNavigationTests.swift) verifies that both legacy link-opening choices survive loading and that the dedicated-pane choice persists without replacing existing tabs.

## Link hover preview

Verify relative, nested, shadow-root, and iframe links display their destinations through an isolated WebKit bridge. Leaving a link and navigating clear the preview; its bounded pane-local bubble ignores clicks.

Pointer movement within one link switches the preview to the right and back without duplicate URL messages or oscillation. Long URLs truncate clear of the cursor at either edge, including after a pane resize. Short and long GitHub URLs fit their full text when the pane has room; changing URLs recomputes the width. Rendered previews must match the same label with truncation disabled, catching internal text-cell padding that geometric assertions miss. `BEND_URL_PREVIEW_SNAPSHOTS` optionally saves those renders for visual inspection.

## Command-Shift-click destinations

[[Tests/BrowseTests/LinkNavigationTests.swift#commandShiftClickDestinations]] verifies independent Command-Shift-click preferences across WebKit navigation and popup callbacks, preserving the source while opening a new tab, pane, or window.

Missing settings default to New tab and insert below the active sidebar row. New panes are adjacent without claiming the dedicated Command-click pane, and iframe links omit opener metadata. Ordinary Command-click retains its own mode. New windows contain one destination pane and persist the URL and window membership. Changes through secondary stores reach existing controllers; all three choices persist independently of Command-click.

## Title URL preview

[[Tests/BrowseTests/LinkHoverPreviewTests.swift#titleURLPreview]] sends native hover events to a pane title handle and verifies the page URL appears in the existing bottom preview even when the pointer is above page content.

Delayed DOM link events cannot erase or replace the title URL while the pointer is in the header. Entering page content gives the hovered link priority even when the native title-exit event arrives late. Exit restores ordinary link previews; title presses, hiding, removal, and navigation clearing remove the title preview. Both sources preserve encoded URLs and strip invisible control and directional characters.

## Option-click destinations

[[Tests/BrowseTests/LinkNavigationTests.swift#optionClickDestinations]] verifies that Option-click defaults to a new tab and independently supports new panes and windows, including WebKit actions marked as downloads.

Both navigation callbacks cancel source navigation. Pane placement, sidebar insertion, iframe opener handling, shared-window preference updates, and persistence match the explicit destination. Command-click and Command-Shift-click keep their separate settings.

## Native Option-click links

[[Tests/BrowseTests/LinkNavigationTests.swift#nativeOptionClickLinks]] sends native Option-click events to same-frame, new-window, and iframe links, verifying correct URLs and frame provenance without downloading or navigating the source.

Trusted native clicks must use the isolated document bridge before navigation policy, while page-generated clicks cannot reach it. The fixture requires document and iframe readiness, waits for a rendered snapshot, and converts measured DOM link bounds into native window coordinates before clicking. Failures report DOM mouse events and WebKit navigation-action metadata to distinguish event-delivery problems from routing regressions.

## Link context menu destinations

[[Tests/BrowseTests/LinkContextMenuTests.swift#linkContextMenuDestinations]] invokes WebKit's real context-menu hit testing for main-frame and iframe links and dispatches the resulting pane, tab, and window menu actions.

Open Link in New Tab is first, followed by New Pane and New Window. URLs retain query strings and fragments. Each menu keeps its own target after another menu opens. Copy Link survives and the native window action is replaced. Explicit choices ignore click preferences, preserve the source, place panes adjacent without dedicated-pane reuse, and omit opener metadata for iframe links. New-tab actions preserve selection, pane focus, and zoom, insert directly below the active row, and create a loading controller without mounting the tab.

## Option-click shared controller isolation

[[Tests/BrowseTests/LinkNavigationTests.swift#optionClickSharedControllerIsolation]] shares one user-content controller between a routed pane and a plain WebView, verifying only the pane enables Option-click interception and other views cannot route links.

## Dedicated pane window restoration

[[Tests/BrowseTests/LinkNavigationTests.swift#dedicatedPaneWindowRestoration]] verifies duplicated tabs retain their reusable Command-click destination through full window shutdown and restoration in both main and secondary windows.

The copied destination has a fresh pane identity. After restoring, the next Command-click reuses that pane without increasing the pane count, and the shared dedicated-pane preference remains active.
