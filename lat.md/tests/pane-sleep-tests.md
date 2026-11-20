---
lat:
  require-code-mention: true
---
# Pane sleeping tests

These tests verify conservative suspension, WebView release and restoration, and persistent user controls.

## Timeouts and uncertain replies

Verify power/pressure thresholds and that a missing or late callback produces unknown without double-resuming a completed check.

## Draft and activity protection

Verify clean documents are eligible while changed fields, sticky edits, editable/embedded/custom content, WebRTC use, and missing instrumentation prevent sleeping.

## Release restore and visibility races

Verify every selected-tab pane stays awake, recently hidden pages retain their grace period, site exceptions apply, selection invalidates an outstanding check, and sleeping releases the old controller/WebView before restoring URL and history.

Navigation invalidates an outstanding check. Subsequent sweeps must eventually release an eligible pane once WebKit settles. Transfers preserve sleeping state, explicit destinations supersede it, and closing a sleeping pane drops its capture.

## Persistent exceptions

Verify sleeping starts disabled and the toggle and exceptions survive reopening the profile preferences. Hostnames cover all descendant labels, overlapping entries can be removed independently, and IP addresses match exactly.

## Download startup protection

Verify the download request protects its WebView before WebKit returns a download, remains protected during transfer, and becomes eligible after cancellation without protecting unrelated panes.

## Form resubmission protection

Verify a normal GET page can sleep but a completed POST navigation remains protected, avoiding a replay of side effects when restoring WebKit history.
