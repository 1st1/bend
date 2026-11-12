---
lat:
  require-code-mention: true
---
# Favorites tests

Tests verify shared favorite tabs and per-account Google destinations.

See [[lat.md/architecture/favorites|Architecture and behavior]].

## Favorite tabs and persistence

[[Tests/BrowseTests/FavoritesTests.swift#favoriteTabsAndPersistence]] verifies the nine-site cap, duplicate handling, tab-to-tile representation, original-URL reopening, lazy restoration, invalid URL rejection, removal, and compatibility with older sessions.

## Shared favorites and pane transfers

[[Tests/BrowseTests/FavoritesTests.swift#sharedFavoritesAndTransfers]] verifies shared favorites across windows, separate live instances, association preservation during transfers and splitting, focused-pane selection, persistence, and removal from another window.

## Favorite favicon snapshots

[[Tests/BrowseTests/FavoritesTests.swift#favoriteFaviconSnapshots]] verifies late favicon capture, persisted PNG restoration without creating a WebView, rejection of cross-origin icon replacements, and validation of duplicate, invalid, or oversized saved entries.

## Favorite tile interaction

[[Tests/BrowseTests/FavoritesTests.swift#favoriteTileInteraction]] mounts nine tiles in a native window, verifies the three-column layout and window-drag exclusions, and clicks a tile through native mouse dispatch to select its hidden sidebar tab.

## Google favorite account URLs

[[Tests/BrowseTests/GoogleFavoriteTests.swift#googleFavoriteAccountURLs]] checks exact host recognition, email validation, plus-tag encoding, Google chooser destinations, account-hint prefill, spoofed URL rejection, and older favorite decoding.

## Google favorite customization lifecycle

[[Tests/BrowseTests/GoogleFavoriteTests.swift#googleFavoriteCustomizationLifecycle]] verifies optional-email creation, invalid input and cancellation, original-target validation, multiple accounts, duplicate prevention, editing, removal of account targeting, and account-specific session restoration.

## Favorite location entry preserves the source

[[Tests/BrowseTests/GoogleFavoriteTests.swift#favoriteLocationEntryPreservesSource]] submits the native location popup from a favorite and verifies a new unassociated tab opens while the source URL and WebView survive. Same-origin entries remain in place; searches open separately and stale targets are ignored.

## Google favorite popup presentation

[[Tests/BrowseTests/GoogleFavoriteTests.swift#googleFavoritePopupPresentation]] opens the Google account sheet from a browser window, verifies its editable email field, and dismisses with Escape without creating a favorite or changing the tab.
