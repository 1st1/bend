---
lat:
  require-code-mention: true
---
# Command panel tests

Tests verify command discovery, validation, and execution in the command popup.

See [[lat.md/architecture/commands|Architecture and behavior]].

## Command popup actions

[[Tests/BrowseTests/CommandPopupTests.swift#commandPopupActions]] verifies state-aware actions, favorite and pin changes, split-tab duplication, the native command shortcut, filtering, execution, empty results, stale targets, and retention of initial blank tabs.

The same test verifies Command-Shift-C chat toggling, dynamic Show/Hide menu titles, and conversation retention.
