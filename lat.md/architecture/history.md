# History

Navigation recording, local persistence, history browsing, and suggestion ranking.

See [[lat.md/tests/history-tests|Test coverage]].

## Corpus explorer

[[scripts/address-corpus.py#load_sources]] reads the Bend and Bend Debug databases in read-only transactions on each launch. The --safari flag includes Safari. [[scripts/address-corpus/Matcher.swift#CorpusMatcher]] ranks the combined visits in memory using the production matcher.

Run `python3 scripts/address-corpus.py` from the repository root. Type a query to see up to five ranked URLs with matched characters highlighted. Ctrl-R samples ten random URLs for inspiration. Use the arrow keys to select the URL that should rank first, then Ctrl-G to mark the expected order. Esc exits and prints marked cases. Browser rows and marked cases stay in memory. The tool caches the compiled matcher and rebuilds it on launch when its Swift sources change.

To keep an example for future tuning, add a small block to [[Tests/Fixtures/address-matching.txt]] with the competing URLs, visit counts, titles, and expected ranks. Use a dash for a result that should be absent. Run `scripts/test.sh --filter addressMatchingCorpus` to check the entire [[lat.md/tests/history-tests#Address matching corpus|ranking corpus]].

## Browsing history

[History.swift](../../Sources/BrowseCore/History.swift) models a bounded, serializable collection of web visits. It normalizes HTTP and HTTPS addresses, strips embedded credentials, and combines rapid consecutive visits to the same URL.

Visits retain titles and timestamps, newest first, up to 10,000 visits. Consecutive visits to the same URL within 30 seconds coalesce. Removing a URL also removes its learned suggestion choices; clearing history removes both visits and choices.

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) records successful web navigations. Later URL changes on a completed, idle page create visits, while title changes update the latest matching visit. Internal pages and failed navigations are excluded.

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) persists visits and learned choices through [[lat.md/architecture/history#History database]] shared across windows. Secondary regular-window stores forward history writes and observations to the root owner, avoiding conflicting snapshots. [[lat.md/architecture/privacy#Private windows]] keep their own temporary history. Writes are debounced and flushed with session saves; removal and clearing save immediately. Unreadable history storage is preserved until an explicit clear permits replacement, with errors exposed by the store.

## History database

[HistoryDatabase.swift](../../Sources/BrowseCore/HistoryDatabase.swift) uses macOS’s system SQLite library for Bend’s own `History.db`, separating URL records, individual visits, and learned address-bar choices.

The database lives under `Application Support/BrowsePrototype`, alongside the primary session. It follows Safari’s URL/visit organization, without reading Safari’s database or depending on its private schema. Visit UUIDs and titles remain per visit; timestamps use seconds since January 1, 2001. Foreign keys link visits and choices to unique URLs. Time and URL indexes support lookup and cleanup.

The regular profile opens SQLite, restores visits, and builds the search index on a background utility queue. Windows and tabs can open immediately. Startup edits update provisional history and replay in order against the loaded snapshot before publication. Normal quit waits for a pending load to finish saving edits. One root store owns the resulting connection and cached snapshot. Saves apply only changed rows inside a transaction; deleted visits and choices are removed and unreferenced URLs collected. SQLite uses WAL, full synchronous commits, and secure deletion. The in-memory 10,000-visit bound and existing suggestion ranking remain unchanged. Website data stays in WebKit’s separate store.

On first initialization, valid `history.json` visits and choices import in the same transaction as the schema version. JSON is removed only after the database loads successfully; a leftover JSON file is never reimported into an initialized database. Corrupt JSON, corrupt databases, and unsupported schema versions block ordinary persistence. Explicit Clear History may discard unreadable storage and initialize an empty database. Transaction failures leave the previous snapshot intact and pending changes available for retry.

## History interface

[HistoryView.swift](../../Sources/Browse/HistoryView.swift) displays searchable visits grouped by local calendar day in the built-in history page, with controls to revisit or remove pages and clear recorded history.

The History menu and Command-Y open `browse://history`, reusing an existing history pane across workspaces when available. Selecting a visit navigates the current pane; its context menu can open a new tab. Removing a page deletes all visits and learned choices for that URL. Clearing all history requires confirmation and leaves open pages and website data intact. The view displays history read and write errors from the store.

## History suggestions

[History.swift](../../Sources/BrowseCore/History.swift) groups visits by URL and ranks matching suggestions using prior choices, URL match strength, and visit frequency weighted by recency.

Each in-memory history snapshot keeps one prepared search record per URL, with folded text, fuzzy-match units and boundary bonuses, and visit dates. Restoring history builds the index. Recording visits, title changes, eviction and removal update the affected records. Time-based clearing regroups the retained visits and reuses prepared text where possible. Only visits and learned choices are persisted.

Matching ignores case and diacritics. For ordinary text, literal matches precede fuzzy matches; each query word must match the title or decoded URL. [[Sources/BrowseCore/FuzzyMatch.swift#FuzzyMatch]] scores ordered subsequences using consecutive runs, word/path boundaries, camel-case initials, and gap penalties. Thus github/jit finds github.com/1st1/jit. Every query word must independently meet a length-scaled minimum fuzzy score in either the title or URL; literal words remain eligible. Weak scattered-letter matches are omitted, including their highlight spans, so they cannot displace the search action. Fuzzy quality precedes frequency and learned choices; matches reaching the end of a title or URL receive a completion bonus, so a complete path can outrank the same match with an extra suffix. Literal ranking remains unchanged. The scorer uses two bounded dynamic-programming rows (128 query characters, 2,048 candidate characters) and a linear rejection pass. Highlighting recovers the same best alignment with optional predecessor storage only for displayed results. Original UTF-16 ranges preserve composed characters and case-fold expansions. Literal spans take precedence when present. The full history page retains literal filtering. URL-prefix completions preserve the typed prefix; whitespace-containing queries do not receive inline completions. Inline completion uses the recorded hostname, including its subdomains. Explicit www. and scheme prefixes retain literal matching, and selecting the suggestion still navigates to its original recorded URL.

IPv4-like input with two to four valid numeric octets, optionally ending in a dot, uses strict URL-prefix matching against complete IPv4 hosts. Titles, paths on unrelated hosts, and fuzzy subsequences cannot supply matches. Explicit HTTP(S) schemes, ports, and paths retain prefix semantics; ordinary text searches and the full history page keep their existing behavior.

Suggestions combine visits into one result per URL. Ranking prefers URL match strength, with visited home pages ahead of deep links for host-prefix queries, then frequency with a 30-day recency half-life plus a bounded learned-choice bonus. A single previous choice cannot permanently outrank repeated visits; path queries still find matching deep links. Learned choices are bounded to 1,000 query/URL pairs and decay over time. Matching runs locally without sending partial queries to a search engine or preloading pages.

Fuzzy ranking draws on [VS Code’s quick-open scorer](https://github.com/microsoft/vscode/blob/main/src/vs/base/common/fuzzyScorer.ts) and [Sublime Text’s Goto Anything interaction](https://www.sublimetext.com/blog/articles/sublime-text-2-public-alpha), implemented independently in Swift.

The interaction draws on [Firefox's address-bar matching](https://support.mozilla.org/en-US/kb/address-bar-autocomplete-firefox), its [frequency/recency and adaptive-input ranking](https://firefox-source-docs.mozilla.org/browser/urlbar/ranking.html), and [Safari's combined search field](https://support.apple.com/en-ie/guide/safari/sfrid73436cb/mac). Bend implements its own bounded ranking over recorded visits.

[AddressPanelController.swift](../../Sources/Browse/AddressPanelController.swift) combines history matches with a direct visit or search action in the [[lat.md/architecture/address-entry#Location popup]]. The popup displays cached origin favicons in their original colors, falling back to a clock for uncached history entries. The history page uses the same cache with a globe fallback. Neither view fetches icons or creates WebViews. The popup refreshes when history or cached icons change; selecting a history result records the typed query to influence later rankings.

### Address-bar scoring weights

[[Sources/BrowseCore/History.swift#BrowsingHistory#suggestions]] ranks eligible URLs by match tier, fuzzy score, usage score, and most recent visit, all descending. URL text ascending breaks a final tie. The popup requests six history rows.

- Host-only inputs such as chess.com and chess.co match literal hostname prefixes first, then prefixes of consecutive hostname labels. For example, new.yc matches news.ycombinator.com. A home page precedes deeper pages among these abbreviated matches. Dotted abbreviations can start at any hostname label, including www. Thus w.ny and ny.c can both find www.nytimes.com. An explicit HTTP(S) scheme requires the recorded URL prefix. The popup keeps the direct action selected and offers qualifying pages underneath. [[lat.md/architecture/address-entry#Address handling]] determines whether the action is Visit or Search. Ordinary text uses word matching. Slash abbreviations use the component ranking below.
- Literal tiers are 3 for an exact host or full URL, 2 for a host or URL prefix, and 1 for all other literal matches. A home page adds 1 to tiers 2 and 3. Fuzzy and empty queries use tier 0.
- Each aligned character earns 10 points. Matching the first character earns 18 extra, following punctuation or whitespace earns 14, and a lower-to-upper camel-case boundary earns 12. These boundary bonuses are mutually exclusive. Starting late costs one point per skipped character, capped at 30. Adjacent matches earn 18 extra. Each gap costs 8 plus the number of characters skipped. Ending on the final candidate character earns 4.
- Each word needs 12 points per folded character or a literal occurrence in the same field. The fuzzy score sums each word’s better qualifying alignment across title and URL.
- Each visit contributes 0.5 raised to its age in 30-day periods. A learned query/URL pair starts at weight 1 and each repeat updates it to 0.9 times its previous weight plus 1. A previous query beginning with the current input contributes its weight times 0.975 raised to its age in days, doubled for an exact query. The strongest pair for the URL contributes three times that value, capped at 6. Future timestamps count as age zero. Empty input uses visits alone.


For a leading word with at least two nonempty slash groups, the matcher tries to align each group with a distinct hostname or path component in order. It splits before percent-decoding. Query strings and fragments cannot supply components. A dotted first group can abbreviate the hostname by label. A scheme typed on the abbreviation must agree with the recorded URL. Extra words must qualify in the title or URL.

Among complete component alignments, a literal prefix of the address ranks first. For example, x.com/1 prefers x.com/1st1 over another account’s photo/1. An abbreviated host followed by consecutive path-component prefixes ranks next. For x/1 this keeps the 1 aligned with the first path component, so 1st1 precedes a deeper photo/1 match. Other complete alignments precede ordinary text matches. Each group earns 100 for equality, 70 for a prefix, 45 for a substring, or 25 for a qualifying fuzzy match within that component. Skipping an intervening component costs 4. Starting on the hostname adds 8 and finishing on the last component adds 6. The best alignment wins, then usage breaks ties. A literal occurrence in a title or decoded URL remains a fallback. Scattered letters across components cannot stand in for a group.
