This directory defines the high-level concepts, business logic, and architecture of this project using markdown. It is managed by [lat.md](https://www.npmjs.com/package/lat.md) — a tool that anchors source code to these definitions. Install the `lat` command with `npm i -g lat.md` and run `lat --help`.

# Bend

Bend is a SwiftUI and WebKit macOS browser prototype with Rex-inspired vertical tabs and tiled browsing panes.

- [[architecture]] describes the native shell, tiling model, WebKit ownership, web extensions and settings, session persistence, browsing history, and address suggestions.
- [[tests]] describes model and store regression coverage.

See [README.md](../README.md) for building, running, keyboard shortcuts, and prototype scope.
