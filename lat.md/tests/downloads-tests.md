---
lat:
  require-code-mention: true
---
# Downloads tests

Tests verify download transfers, persistent records, progress, and destination handling.

See [[lat.md/architecture/downloads|Architecture and behavior]].

## Dock download progress

[[Tests/BrowseTests/DownloadTests.swift#dockDownloadProgress]] verifies native file progress stays unfinished until publication succeeds, uses the collision-resolved URL, and cancels failed operations without reporting completion.

Windowless progress omits animation metadata, and finishing twice has no effect. Visual animation remains controlled by the macOS Dock.

## Website downloads

[DownloadTests.swift](../../Tests/BrowseTests/DownloadTests.swift) uses real WebKit navigation to download attachments, explicit links, unsupported MIME types, redirects with cookies, POST responses, and blob/data files while preserving the source document.

Existing filenames must remain unchanged, repeated downloads receive distinct names, completed transfers leave no staging folders, and clearing the list preserves downloaded files.

Converting navigation into a download must not display a page error, while genuine connection errors remain visible.

## Download cancellation and retry

[DownloadTests.swift](../../Tests/BrowseTests/DownloadTests.swift) cancels a throttled transfer after progress arrives, releases its source controller, retries to completion, and verifies an HTTP failure can be retried without publishing its error body.

A separate running transfer must finish after its source web view is released.

## Download filenames

[DownloadTests.swift](../../Tests/BrowseTests/DownloadTests.swift) checks traversal paths, Windows separators, hidden names, control and directional characters, and oversized Unicode names become bounded filenames; unsupported URL schemes cannot start downloads.

## Download destination preferences

[DownloadTests.swift](../../Tests/BrowseTests/DownloadTests.swift) verifies the download folder defaults to Downloads, persists across store recreation, and is shared across windows.

An active transfer keeps its original destination after a preference change, while the next download uses the new folder. Resetting to Downloads removes the custom preference.

## Download-only tabs

[DownloadTests.swift](../../Tests/BrowseTests/DownloadTests.swift) opens real new-window download links, directly and through redirects, verifying their temporary tabs disappear while transfers complete and the source document remains intact.

Cleanup restores the preceding tab only if the temporary tab is still selected, does not add closed-tab history, and retains tabs that committed a document before downloading.

Context-menu background tabs load real pages without activation. Download-only background tabs disappear without changing the source selection or zoom, creating closed-tab history, or disturbing unsaved form input.

## Download database retention and transactions

[DownloadDatabaseTests.swift](../../Tests/BrowseTests/DownloadDatabaseTests.swift) verifies SQLite round trips, stable order, 256-record pruning, transactional rollback after an injected failure, retry, and durable clearing without deleting files.

## Download history recovery

[DownloadDatabaseTests.swift](../../Tests/BrowseTests/DownloadDatabaseTests.swift) preserves unreadable storage, retries after repair, and restores unfinished transfers as interrupted without replaying POST requests or starting downloads automatically.

## Persistent download history

[DownloadTests.swift](../../Tests/BrowseTests/DownloadTests.swift) recreates the manager after real completed and interrupted downloads, retries a restored GET, and verifies durable clearing and automatic retention while saved files remain intact.

## Combined download progress

[DownloadDatabaseTests.swift](../../Tests/BrowseTests/DownloadDatabaseTests.swift) verifies byte-weighted progress across transfers, unknown-size and idle states, bounded invalid counts, and large byte totals without integer overflow.

## Downloads with collapsed sidebar

[DownloadTests.swift](../../Tests/BrowseTests/DownloadTests.swift) verifies one visible Downloads control remains inside the window across sidebar toggles, pane zoom, and tab switching, beside the sidebar toggle when collapsed; clearing the list removes it.

Both controls retain their 28-point size and two-point gap in expanded and collapsed layouts.
