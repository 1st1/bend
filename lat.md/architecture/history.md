# History

Navigation recording, local persistence, history browsing, and suggestion ranking.

See [[lat.md/tests/history-tests|Test coverage]].

## Browsing history

[History.swift](../../Sources/BrowseCore/History.swift) models a bounded, serializable collection of web visits. It normalizes HTTP and HTTPS addresses, strips embedded credentials, and combines rapid consecutive visits to the same URL.

Visits retain titles and timestamps, newest first, up to 10,000 visits. Consecutive visits to the same URL within 30 seconds coalesce. Removing a URL also removes its learned suggestion choices; clearing history removes both visits and choices.

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) records successful web navigations. Later URL changes on a completed, idle page create visits, while title changes update the latest matching visit. Internal pages and failed navigations are excluded.

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) persists visits and learned choices through [[lat.md/architecture/history#History database]] shared across windows. Secondary regular-window stores forward history writes and observations to the root owner, avoiding conflicting snapshots. [[lat.md/architecture/privacy#Private windows]] keep their own temporary history. Writes are debounced and flushed with session saves; removal and clearing save immediately. Unreadable history storage is preserved until an explicit clear permits replacement, with errors exposed by the store.

## History database

[HistoryDatabase.swift](../../Sources/BrowseCore/HistoryDatabase.swift) uses macOS’s system SQLite library for Bend’s own `History.db`, separating URL records, individual visits, and learned address-bar choices.

The database lives under `Application Support/BrowsePrototype`, alongside the primary session. It follows Safari’s URL/visit organization, without reading Safari’s database or depending on its private schema. Visit UUIDs and titles remain per visit; timestamps use seconds since January 1, 2001. Foreign keys link visits and choices to unique URLs. Time and URL indexes support lookup and cleanup.

One root store owns the connection and cached snapshot. Saves apply only changed rows inside a transaction; deleted visits and choices are removed and unreferenced URLs collected. SQLite uses WAL, full synchronous commits, and secure deletion. The in-memory 10,000-visit bound and existing suggestion ranking remain unchanged. Website data stays in WebKit’s separate store.

On first initialization, valid `history.json` visits and choices import in the same transaction as the schema version. JSON is removed only after the database loads successfully; a leftover JSON file is never reimported into an initialized database. Corrupt JSON, corrupt databases, and unsupported schema versions block ordinary persistence. Explicit Clear History may discard unreadable storage and initialize an empty database. Transaction failures leave the previous snapshot intact and pending changes available for retry.

## History interface

[HistoryView.swift](../../Sources/Browse/HistoryView.swift) displays searchable visits grouped by local calendar day in the built-in history page, with controls to revisit or remove pages and clear recorded history.

The History menu and Command-Y open `browse://history`, reusing an existing history pane across workspaces when available. Selecting a visit navigates the current pane; its context menu can open a new tab. Removing a page deletes all visits and learned choices for that URL. Clearing all history requires confirmation and leaves open pages and website data intact. The view displays history read and write errors from the store.

## History suggestions

[History.swift](../../Sources/BrowseCore/History.swift) groups visits by URL and ranks matching suggestions using prior choices, URL match strength, and visit frequency weighted by recency.

Matching ignores case and diacritics and requires every query word to occur in the title or decoded URL. URL-prefix completions preserve the typed prefix; whitespace-containing queries do not receive inline completions. Bare-host queries can omit a leading www. for both inline completion and home-page ranking. Explicit www. and scheme prefixes retain literal matching, and selecting the suggestion still navigates to its original recorded URL.

Suggestions combine visits into one result per URL. Ranking prefers URL match strength, with visited home pages ahead of deep links for host-prefix queries, then frequency with a 30-day recency half-life plus a bounded learned-choice bonus. A single previous choice cannot permanently outrank repeated visits; path queries still find matching deep links. Learned choices are bounded to 1,000 query/URL pairs and decay over time. Matching runs locally without sending partial queries to a search engine or preloading pages.

The interaction draws on [Firefox's address-bar matching](https://support.mozilla.org/en-US/kb/address-bar-autocomplete-firefox), its [frequency/recency and adaptive-input ranking](https://firefox-source-docs.mozilla.org/browser/urlbar/ranking.html), and [Safari's combined search field](https://support.apple.com/en-ie/guide/safari/sfrid73436cb/mac). Bend implements its own bounded ranking over recorded visits.

[AddressPanelController.swift](../../Sources/Browse/AddressPanelController.swift) combines history matches with a direct visit or search action in the [[lat.md/architecture/address-entry#Location popup]]. The popup refreshes when history changes; selecting a history result records the typed query to influence later rankings.
