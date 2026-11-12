---
lat:
  require-code-mention: true
---
# Media playback tests

Tests verify sidebar media controls, source ownership, and exclusive playback.

See [[lat.md/architecture/media|Architecture and behavior]].

## Media session commands and metadata

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) checks document-start action capture, controls, title/artist extraction, metadata mutation, handler removal, native validation, command timeout, and stale-command rejection after navigation.

## Media playback progress

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) verifies Media Session timing, native interpolation, pause freezing, seek-handler arguments, clearing position state, and rejection of invalid durations and seek targets.

HTML fallback fixtures also verify duration and seeking for attached and detached audio. The optional sidebar snapshots include a seekable progress bar at narrow and regular sidebar widths.

## Media progress layout

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) verifies the card height and progress-bar frame stay unchanged as timing appears, disappears between tracks, and returns with a new duration. Missing timing disables seeking.

Live bottom-rim clipping changes from zero through fractional to maximum values preserve the card height and progress-bar frame.

## Media slider interaction

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) verifies the styled native slider commits keyboard and accessibility changes immediately in five-second steps. The optional sidebar snapshots verify the track appearance at narrow and regular widths.

## Media frame routing and lifecycle

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) targets an opaque-origin embedded player while another WebView shares its content controller, verifying frame and pane isolation, removal cleanup, and process-termination invalidation.

## HTML media fallback controls

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) plays a silent WAV in an open shadow root and in off-DOM audio elements, verifying discovery, commands, exclusive playback, and cleanup.

Both `new Audio()` and `document.createElement` fixtures work without DOM insertion or declared Media Session playback state. Play/pause controls, page-title fallback, and resuming work in all cases; volume commands are rejected without changing page volume; removing and emptying the player retires it.

## Sidebar media ownership

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) verifies commands reach a background tab, title activation reveals its pane, cross-window transfer retains the live WebView, dismissal survives refresh, resumed playback restores the card, and closure removes it.

## Media track transitions

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) verifies that pauses and brief inactive sessions between tracks preserve the selected source, while real stops expire and navigation clears it immediately.

## Media source menu images

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) verifies native player menu rows include correctly sized favicon and fallback images, explicitly visible images on macOS 27, selected state, and actions bound to their source.

The test and application compile with the macOS 26 SDK using SDK-independent property access; no newer enum or property declaration is referenced.

## Media source selection

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) checks most-recent playback selection, explicit source selection, commands affecting only that source, persistent dismissal, reappearance on new playback, and cleanup on native-page navigation.

Sources are ordered most-recent-first after playback starts and explicit selection; refreshes, pauses, and metadata changes do not reorder them. With two sources, closing hides the entire panel while retaining both players and their playback state. Refreshing either source or changing metadata keeps it hidden; a new playback start reveals the panel with both players still available.

## Exclusive media playback

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) starts media in competing panes and windows, checks that older players pause, resumes an older source, and rejects a queued pause for its previous playback revision.

Stopping the new owner must leave older players paused. The HTML fallback fixture separately checks the underlying audio element is paused when another pane starts.

## Short media filtering

[[Tests/BrowseTests/MediaDurationTests.swift#shortMediaFiltering]] plays real audio/video notifications at one and seven seconds, verifying no transient card, no interruption of another pane, and immediate controls above the cutoff.

A short sound in the same frame must preserve the longer player's identity and duration. Looping does not turn a short clip into eligible long media.

## Unknown media duration qualification

[[Tests/BrowseTests/MediaDurationTests.swift#unknownMediaDurationQualification]] verifies unknown and infinite-duration sessions stay hidden until seven seconds of playback, exclude paused time, and become visible through a native deadline without idle polling.

A later known short duration removes an already qualified source, while a duration just above seven seconds restores controls immediately.

## Media qualification lifecycle

[[Tests/BrowseTests/MediaDurationTests.swift#mediaQualificationLifecycle]] uses a controlled HTML playback clock to exclude paused and buffering time, reset eligibility on resource replacement, and preserve qualified controls when timing disappears.

## Live media session smoke test

[MediaPlayerTests.swift](../../Tests/BrowseTests/MediaPlayerTests.swift) optionally loads `BEND_MEDIA_SMOKE_URL` in an ephemeral WebKit store, attempts muted playback, matches the sidebar title to Media Session metadata, and tests pause/resume with default playback policy.

This opt-in check uses no saved sign-in and depends on the site's availability, consent flow, and playback policies. Local fixtures cover the deterministic bridge behavior. `BEND_MEDIA_SNAPSHOT` optionally renders the card with multiple players, a long title, and favicon at narrow, default, and wide sidebar widths, plus the full browser window, during the ownership fixture to inspect centered metadata, the compact favicon picker beside transport controls (with a separate row at minimum width), truncation, glass chrome, and pane spacing.
