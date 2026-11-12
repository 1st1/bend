---
lat:
  require-code-mention: true
---
# History tests

Tests verify navigation recording, local persistence, history browsing, and suggestion ranking.

See [[lat.md/architecture/history|Architecture and behavior]].

## History recording

[HistoryTests.swift](../../Tests/BrowseCoreTests/HistoryTests.swift) verifies web-only recording, credential stripping, merging of rapid repeated visits, title updates, and serialization that preserves valid history.

## History matching and completion

[HistoryTests.swift](../../Tests/BrowseCoreTests/HistoryTests.swift) checks case- and accent-insensitive matching across titles and decoded URLs. Prefix completion handles explicit schemes and declines short, complete, or multiword queries.

Regression coverage includes bare-host completion of www. URLs, typed-case preservation, explicit www./scheme prefixes, unchanged navigation URLs, and retaining other subdomains.

## History ranking and learned choices

[HistoryTests.swift](../../Tests/BrowseCoreTests/HistoryTests.swift) verifies recency, frequency, learned query choices, URL matching, and result limits so suggestions remain relevant and bounded.

## History removal and bounds

[HistoryTests.swift](../../Tests/BrowseCoreTests/HistoryTests.swift) verifies eviction at the visit limit, removal from suggestions, and clearing visits and learned choices while retaining a valid model.

## History persistence and clearing

[HistoryStoreTests.swift](../../Tests/BrowseTests/HistoryStoreTests.swift) verifies that visits and learned choices survive reloading, that secondary windows share the root database, and that removal and clearing persist independently of session data.

## Unreadable history preservation

[HistoryStoreTests.swift](../../Tests/BrowseTests/HistoryStoreTests.swift) verifies that corrupt JSON or SQLite history is reported and preserved during ordinary saves. Explicit clearing permits an empty database to replace it.

## SQLite history transactions

[HistoryDatabaseTests.swift](../../Tests/BrowseCoreTests/HistoryDatabaseTests.swift) verifies normalized URL/visit rows, exact timestamp and title round trips, incremental updates, rollback after an injected failure, retry, and deletion of visits and choices.

## JSON history migration

[HistoryDatabaseTests.swift](../../Tests/BrowseCoreTests/HistoryDatabaseTests.swift) verifies one-time migration preserves visits and learned ranking, removes the JSON source, prevents reimport after clearing, and leaves unsupported database versions untouched.

## SQLite history retention

[HistoryDatabaseTests.swift](../../Tests/BrowseCoreTests/HistoryDatabaseTests.swift) verifies the visit limit persists across reopening, with the oldest visit and its unreferenced URL removed when a new visit exceeds the bound.

## Completed navigation history

[HistoryStoreTests.swift](../../Tests/BrowseTests/HistoryStoreTests.swift) checks that completed web navigation records once, title changes update existing history, and later URL changes add visits. Failed navigation and internal pages are excluded.

## Home page suggestion ranking

[HistoryTests.swift](../../Tests/BrowseCoreTests/HistoryTests.swift) reproduces a deep link with one learned choice competing with 35 home-page visits. Host prefixes prefer the home page, path searches retain deep links, and frequent visits can outweigh learned choices.

Bare-host prefixes also prefer a www. home page over a much more frequently visited article; omitting www. from a path query still finds and completes the deep link.

## Remove address suggestion

[HistoryStoreTests.swift](../../Tests/BrowseTests/HistoryStoreTests.swift) exercises a popup row’s removal button and verifies immediate result refresh, persisted removal of visits and learned choices, and no navigation.
