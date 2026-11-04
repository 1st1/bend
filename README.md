# Browse

A native macOS browser prototype with a Rex-inspired vertical tab sidebar and tiled browsing. Built with SwiftUI, AppKit, and the system WebKit framework; no dependencies or Xcode project required.

## Run

Requires macOS 14 or newer and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
./scripts/build-app.sh --open
```

This builds `dist/Browse.app` and signs it with the `Browse Dev` code-signing certificate and private key in your keychain. Reuse that identity across builds so keychain authorization can persist. The build fails if signing or signature verification fails. You can also open `Package.swift` in Xcode, or run `swift run Browse` during development; those paths do not use the script's signing step.

## Use

The sidebar groups vertical tabs into workspaces. Each tab holds its own nested pane layout. Click the sidebar’s top `+` to create a workspace, or the `+` next to a workspace to add a tab there.

The sidebar and exposed workspace share a native Liquid Glass base on macOS 26 and later. Selected tabs and browser pane frames also use Liquid Glass, with standard material fallbacks on older systems. The focused pane has a brighter neutral header indicator, without a colored border. Pane chrome uses a 50% black scrim to soften the glass effect; web content scrolls behind the compact title row on macOS 26 and later.

| Action | Shortcut |
| --- | --- |
| New tab | ⌘T |
| Open link in a new pane to its right | ⌘-click link |
| Open location popup | ⌘L |
| Split focused pane right | ⌘D |
| Split focused pane below | ⌘⇧D |
| Zoom / restore focused pane | ⌘⇧Return |
| Show / hide sidebar | ⌘⇧S |
| Close focused pane | ⌘W |
| Close entire tab | ⌘⇧W |
| Reload | ⌘R |
| Back / forward | ⌘[ / ⌘] |

Press ⌘L to open a Spotlight-style URL/search popup for the focused pane. Return opens the address; Escape or an outside click dismisses the popup. New blank panes and tabs open it automatically. Reload/stop is in the top-right pane toolbar; back and forward use the shortcuts above.

Drag dividers to resize. Click a pane header or its web content to focus it. Large layouts scroll once their panes reach minimum sizes. Closing the last pane closes its tab; an empty workspace receives a fresh tab.

Tabs, workspace names, URLs, focus, and split proportions restore from `~/Library/Application Support/BrowsePrototype/session.json`. Browser instances stay alive while switching tabs; after restarting, pages load again from saved URLs. WebKit stores website data in this app’s own persistent profile. The prototype does not access Safari’s data.

## Scope

This embeds **system WebKit**, the engine Safari uses. macOS has no supported API for embedding the Safari app itself into arbitrary tiled views. Safari extensions, Safari profiles, Safari tab sync, and existing Safari logins are not inherited.

The prototype supports normal web navigation, search, pop-up links as new tabs, JavaScript dialogs, and WebKit’s developer inspector. It does not yet implement downloads, permission prompts for camera/microphone, a bookmarks/history UI, tab reordering, or full browser settings. It is a local prototype, not a hardened or notarized browser distribution.

## Verify

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox
lat check
```

The core tests cover nested split collapse, focus repair, persisted session integrity, resize bounds, and address/search resolution.
