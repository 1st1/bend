# Downloads

Download transfers, persistent records, progress, and destination handling.

See [[lat.md/tests/downloads-tests|Test coverage]].

## Browser downloads

[BrowserDownloads.swift](../../Sources/Browse/BrowserDownloads.swift) owns native WebKit downloads across all browser windows, with persistent history and a configurable destination that defaults to Downloads.

Settings → UI → Downloads offers a folder chooser and a reset to Downloads. [BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) persists the custom path in the shared session preferences. Existing sessions without the preference retain the default. Each transfer captures its destination when added; changing the preference affects new transfers, while active downloads and retries retain their original folder. [[lat.md/tests/downloads-tests#Download destination preferences]] covers persistence, sharing, and destination changes during a transfer.

[PageController](../../Sources/Browse/BrowserStore.swift) converts download links, attachment responses, and unsupported MIME types into native downloads. WebKit retains the original navigation request, including cookies and POST bodies; explicit blob and data download links are supported. Downloads retain their native transfer independently of their source tab. Redirects remain limited to HTTP and HTTPS, and authentication uses default system handling.

Tabs created by new-window links (or Command-click configured for a new tab) are removed when their initial main-frame navigation becomes a download, including after redirects. The transfer is retained before its web view is released. Cleanup creates no closed-tab history and restores the previous selection and zoom only if that temporary tab remains selected. A committed document, explicit navigation elsewhere, additional panes, a pinned pane, or a moved pane prevents this cleanup. Existing tabs and manually created tabs remain open. [[lat.md/tests/downloads-tests#Download-only tabs]] covers this handoff and focus behavior.

Files first land in private, uniquely named staging directories under their destination folder. Suggested names are reduced to a bounded visible filename without path components, control characters, or directional formatting. An atomic no-replace rename publishes completed files, preserving native download metadata and adding numeric suffixes on collision. Cancelled and failed transfers never publish partial files. Clearing finished entries leaves completed files intact; normal app shutdown cancels active transfers and removes staging files.

The shared manager polls active progress at four updates per second and stops polling when idle. Cancellation keeps WebKit resume data in memory when available. Retry resumes that transfer or restarts an HTTP(S) GET using the originating website data store; it does not replay non-resumable POST requests or expired generated-file URLs. [[lat.md/architecture/downloads#Download database]] retains download records across restarts. Interrupted transfers restore as failed without restarting automatically; HTTP(S) GET retries use WebKit's default website data store after restart.

[DownloadsButton.swift](../../Sources/Browse/DownloadsButton.swift) presents filenames, progress, failure details, cancel/retry controls, and Show in Finder in a popover. A circular ring around the arrow shows combined byte-weighted progress for all active transfers. If any transfer's total size is unknown, a rotating arc indicates activity; Reduce Motion keeps that arc stationary. Idle state restores the ordinary circled arrow. [[lat.md/tests/downloads-tests#Combined download progress]] covers aggregation and unknown sizes.

The same shared list is available in every window, including when the sidebar is hidden. Clear removes inactive entries from memory and the database, with a smaller eraser icon centered on the label’s cap height and the shared capsule hover treatment. An empty list hides the button and dismisses its popover unless transfers are still running or a persistence error needs attention. [[lat.md/tests/downloads-tests#Website downloads]], [[lat.md/tests/downloads-tests#Download cancellation and retry]], and [[lat.md/tests/downloads-tests#Download filenames]] cover transfers and file handling with local fixtures.

## Dock download progress

[[Sources/Browse/BrowserDownloads.swift#DownloadDockProgress]] publishes native file progress so macOS can animate a download into its destination folder in the Dock and display completion feedback.

The public Foundation animation keys provide the file icon and source pane’s center in screen coordinates. Reduce Motion and windowless downloads omit the animation keys. The Dock controls presentation, which requires the destination folder to be in the Dock.

Progress points to the destination folder rather than hidden staging. Completion is reported only after the atomic rename succeeds, using the final collision-resolved URL. Failure, cancellation, and shutdown cancel and unpublish progress; retries create a fresh publication. [[lat.md/tests/downloads-tests#Dock download progress]] covers completion and failure semantics.

## Download database

[DownloadDatabase.swift](../../Sources/Browse/DownloadDatabase.swift) stores the newest 256 download records in SQLite at Downloads.db beside the root session file, shared by all windows.

Each record has a stable UUID, insertion sequence, and encoded metadata containing its filename, state, byte counts, source URL and method, destination folder, saved file URL, and failure message. Updates retain insertion order. Headers, cookies, POST bodies, embedded URL credentials, generated-file URLs, and native resume data are not persisted. Restored active or cancelling records become interrupted failures. Normal shutdown cancels transfers, removes staging files, and persists that interrupted state.

Lifecycle changes use incremental upserts and deletions in transactions with WAL, full synchronous commits, and secure deletion. Progress polling does not write the database. The manager and database both enforce the 256-record limit, discarding oldest metadata without deleting completed files or cancelling live transfers. Evicted live transfers remain owned until completion and still contribute to the progress ring. [[lat.md/tests/downloads-tests#Download database retention and transactions]] and [[lat.md/tests/downloads-tests#Persistent download history]] cover pruning, rollback, clearing, and restart behavior.

Unreadable or unsupported databases are preserved. A message in the downloads popover offers Retry while new transfers can continue in memory. Retrying a successful read merges retained in-memory downloads with the stored history; failed writes retain the last committed snapshot. [[lat.md/tests/downloads-tests#Download history recovery]] covers preservation and interrupted records.
