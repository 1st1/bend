---
lat:
  require-code-mention: true
---
# Pane materials tests

Tests verify pane surfaces, glass ownership, shadows, and rendering boundaries.

See [[lat.md/architecture/pane-materials|Architecture and behavior]].

## Solid header appearance

[[Tests/BrowseTests/AddressRequestTests.swift#solidHeaderAppearance]] verifies legacy style migration, retained solid color across style changes and serialization, and invalid-color normalization.

Native and SwiftUI bitmap renders must both be opaque, lighter than the chosen color at the top, darker at the bottom, and visually equivalent within channel tolerance. Maximum glass darkening and rim clipping cannot affect solid paint.

## Pane shadow boundaries

[PaneShadowTests.swift](../../Tests/BrowseTests/PaneShadowTests.swift) renders the shadow layer to a bitmap, checking visible falloff beyond canvas bounds, clear pane interiors, ignored hit tests, and updates for moved or hidden panes.

The neutral outer edge fades in through the header, leaves the top rim unlit, keeps pane interiors clear at its fixed subtle intensity. The bitmap checks also verify that glow colors only the focused pane’s shadow, follows focus changes, respects intensity and spread, and has matching top/bottom and left/right falloff. Leaving glow mode restores the ordinary black shadow. Outline checks cover independent gap and thickness, drawing beyond the canvas, focus changes, hiding, and clear pane interiors even when a thick ring reaches a neighbor.

## Header glass after window transfer

Moving a live page between windows must preserve a single header material, viewport geometry, scrolling, and unsaved document state.

[[Tests/BrowseTests/HeaderGlassTransferTests.swift#headerGlassAfterWindowTransfer]] mounts two identical pages, repeatedly detaches one into a new window and returns it, then compares the moved and untouched headers. The real WebKit scroll-pocket view remains hidden while Bend's glass stays visible. Scrolling down and back to the top and switching tabs preserve suppression, the content inset, live controller, document token, and form value. A full-app visual check of the reported Hacker News page confirms matching headers after the same round trip.
