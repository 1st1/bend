# Pane sleeping

Inactive panes can release their WebViews while preserving a lightweight preview and navigation state. Safety checks take precedence over memory reclamation.

## Automatic pane sleeping

[[Sources/Browse/PaneSleep.swift#PaneSleepCoordinator]] schedules sequential checks for inactive panes; [[Sources/Browse/PaneSleep.swift#PaneSleepPolicy]] adjusts the inactivity threshold for power and memory conditions.

Normal inactivity is 30 minutes, Low Power Mode uses 10 minutes, memory warning uses 5 minutes, and critical pressure uses 1 minute. The timer checks each minute; the inactivity clock resets when a pane is created or its tab is left. All panes in the selected tab remain protected, including unfocused or zoom-hidden panes. Pinned tabs/panes and favorites are protected, as are loading/error/internal/extension pages, open inspectors, pending sheets/dialogs, downloads, media playback, camera/microphone capture, and panes with opener relationships. A controller that has made a non-GET top-level navigation stays awake for its lifetime, avoiding possible form resubmission during history restoration.

[[Sources/Browse/BrowserStore.swift#BrowserStore#sleepCandidate]] evaluates current ownership and protection. Checks and snapshots are serialized across windows. A timed-out snapshot blocks further snapshots of that WebView until its callback returns. Other panes can still sleep. Every asynchronous stage rechecks controller identity, document navigation revision, URL, session revision, and current protections; closing, selecting, transferring, or navigating invalidates an outstanding attempt.

[[Sources/Browse/PaneSleepSettings.swift#PaneSleepSettings]] exposes the experiment in Settings → General → Memory. It starts off. The hostname field shows an example until activated and accepts ASCII letters, digits, hyphens, and dots. Add requires valid hostname labels. Clicking outside or pressing Escape ends editing and preserves the draft. [[Sources/Browse/PaneSleepSettings.swift#PaneSleepPreferences]] persists the switch and hostname exceptions in the app profile. Each saved name covers the host and all its subdomains. IP addresses match exactly. Changes apply across windows. Enabling starts each window’s inactivity clock and installs probes for future documents. Pages already open without probes stay awake until navigation or reload. Disabling stops pending checks and removes probes from future documents. Sleeping panes wake when revisited.

## Conservative state checks

[[Sources/Browse/PaneSleepProbe.swift#PaneSleepProbe]] requires positive evidence from document-start probes. Missing probes, errors, timeouts, or a changed document prevent suspension.

Input/change/beforeinput events mark the document dirty until navigation, even if fields are subsequently cleared or an autosave may have run. Changed form values/checks/selections, file inputs, contenteditable/design-mode documents, playing media, fullscreen and picture-in-picture prevent sleeping. Frames, embedded objects, custom elements, and shadow roots are treated as unknown rather than assumed safe. This intentionally leaves many complex applications awake.

A page-world probe conservatively keeps documents awake after constructing WebRTC or WebAudio objects, attaching shadow roots, registering unload guards, or requesting capture, even if the activity subsequently ends. Native playback/capture checks supplement the DOM probes. Draft checks run again after snapshotting and must return the same document token. This is a conservative heuristic, not a guarantee of recovering arbitrary application state or detecting all script-managed work; users can exempt sites or turn sleeping off.

## State capture and waking

[[Sources/Browse/PaneSleep.swift#SleepingPane]] retains only WebKit interaction state, compressed preview bytes, URL, title, and zoom in memory. It never persists page state or previews to disk.

[[Sources/Browse/BrowserStore.swift#BrowserStore#finishSleeping]] removes the controller from the store and detaches the WebView. [[Sources/Browse/BrowserView.swift]] replaces inactive sleeping pane content with its snapshot, releasing the retained SwiftUI controller and native surface. This is the exception to [[session#Mounted tab views]] retention; unvisited tabs remain lazy.

Returning to the tab creates a new controller with WebKit interaction state and navigates to the restored current history item, falling back to the saved URL. A preview covers reload until completion or error. WebKit controls history/scroll restoration; arbitrary JavaScript heap and application state are not restored. An explicitly changed destination supersedes the saved state. Extension reload/back/forward actions wake a sleeping pane; read-only tab queries do not. Pane transfers carry sleeping state to the destination store, closing drops it, and stopping a window clears all sleeping state and cancels its scheduler.
