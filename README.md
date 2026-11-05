# Browse

A native macOS browser prototype with a Rex-inspired vertical tab sidebar and tiled browsing. Built with SwiftUI, AppKit, and the system WebKit framework; no dependencies or Xcode project required.

## Run

Requires macOS 14 or newer and a Swift 6 toolchain (Xcode or Command Line Tools).

```sh
./scripts/build-app.sh --open
```

This builds `dist/Browse.app` and defaults to `Apple Development: Yury Selivanov (H8TFDJMW7E)`. The build fails if signing or signature verification fails. Apple-issued signing supplies a stable team partition for WebCrypto Keychain access across rebuilds. The former self-signed `Browse Dev` identity used separate code-hash partitions and could prompt again after each rebuild. On another Mac, create an Apple-issued development certificate through [Xcode's certificate manager](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html), then select its installed signing identity:

```sh
BROWSE_SIGNING_IDENTITY='Apple Development: Your Name (IDENTIFIER)' ./scripts/build-app.sh --open
```

Switching to the Apple-issued identity may require a new Keychain approval once. The build never changes Keychain access controls or stored keys. You can also open `Package.swift` in Xcode, or run `swift run Browse` during development; those paths do not use the script's signing step.

The signing certificate's Apple intermediate must also be installed locally. If signing reports “unable to build chain to self-signed root,” follow [Apple's intermediate-certificate instructions](https://help.apple.com/xcode/mac/current/en.lproj/devc4c7101d8.html); this Apple Development identity uses Worldwide Developer Relations G3. `security find-identity -v -p codesigning` should list the identity as valid.

## Use

Each window has a sidebar of vertical tabs, and each tab holds its own nested pane layout. Click the sidebar’s top `+` to add a tab. Command-N opens a separate browser window with a blank tab. Windows share history, settings, extensions, and website data; their tabs and pane layouts restore independently on relaunch.

The sidebar and exposed workspace share a native Liquid Glass base on macOS 26 and later. Selected tabs and browser pane frames also use Liquid Glass, with standard material fallbacks on older systems. The focused pane has a brighter neutral header indicator, without a colored border. Pane chrome uses a 50% black scrim to soften the glass effect; web content scrolls behind the compact title row on macOS 26 and later.

| Action | Shortcut |
| --- | --- |
| New window | ⌘N |
| New tab | ⌘T |
| Open link in a new pane to its right | ⌘-click link |
| Open location popup | ⌘L |
| Show History | ⌘Y |
| Settings / extensions | ⌘, |
| Split focused pane right | ⌘D |
| Split focused pane below | ⌘⇧D |
| Zoom / restore focused pane | ⌘⇧Return |
| Show / hide sidebar | ⌘⇧S |
| Close focused pane | ⌘W |
| Close entire tab | ⌘⇧W |
| Reopen last closed pane or tab | ⌘⇧T |
| Reload | ⌘R |
| Back / forward | ⌘[ / ⌘] |

Press ⌘L to open a Spotlight-style URL/search popup for the focused pane. Return opens the address; Escape or an outside click dismisses the popup. New blank panes and tabs open it automatically. Reload/stop is in the top-right pane toolbar; back and forward use the shortcuts above.

The location popup searches browsing history by page title and URL as you type. Suggestions favor recent/frequent pages and learn from the results you choose; URL prefixes autocomplete with the suffix selected. Use ↑/↓ and Return or click a result. Matching is local; web searches run only when submitted.

Choose History → Show History (⌘Y) to search visits grouped by day, revisit a page, remove it from history, or clear history. Up to 10,000 web visits are saved in `~/Library/Application Support/BrowsePrototype/history.json`, separately from the open-tab session. Internal pages and failed loads are excluded.

Drag dividers to resize. Click a pane header or its web content to focus it. Large layouts scroll once their panes reach minimum sizes. Closing the last pane closes its tab; an empty workspace receives a fresh tab.

Drag a pane's title or the empty space beside it onto another pane in the same tab. A blue preview shows placement to the left, right, above, or below; release to rearrange, or press Escape to cancel. Live pages and unsaved input stay intact. Exit pane zoom before rearranging.

Press ⌘⇧T to reopen closed panes and tabs, most recent first. Panes return to their original tab and split position where possible, preserving later edits. The last 50 closures are available during the current app session. Reopening reloads saved URLs; page forms and back-forward history are not retained after closing.

Tabs, workspace names, URLs, focus, and split proportions restore from `~/Library/Application Support/BrowsePrototype/session.json`. Visited tabs keep their pane views and browser instances mounted while inactive, so switching does not rebuild the canvas or reload pages. Unvisited tabs load on first selection; after restarting, pages load again from saved URLs. WebKit stores website data in this app’s own persistent profile. The prototype does not access Safari’s data.

## Scope

On macOS 15.4 or newer, Browse → Settings (⌘,) installs and manages Browse's own extension copies. Use **Install from File** for downloaded ZIP, Firefox XPI, Chrome CRX, or unpacked packages. Safari Web Extensions can also be imported as independent resource copies. Review requested access before enabling. **Update from File** replaces a package while retaining its Browse identity and data; additional permissions require approval. Updates are manual, and importing a package does not establish full browser API compatibility or verify its publisher. The puzzle-piece menu opens extension actions; Settings exposes options pages. Reload open pages after enabling or disabling extensions. Native Safari App Extensions are not supported.

**Discover** offers a curated, searchable collection with installation and compatibility notes. uBlock Origin Lite imports the Safari package from this Mac, or links to its official App Store listing if missing. 1Password downloads the reviewed Firefox package from Mozilla and verifies its pinned checksum and package identity. Both start disabled; use **Enable** to review permissions. **Installed** retains the full management controls. Catalog additions and updates are curated in the app, not fetched from a live store feed.

**1Password for Safari is not currently supported.** Its web extension bundle loads, but its native companion connection fails in Browse with “Native messaging is not supported.” Enabling the extension does not establish working unlock or autofill. Settings displays this limitation alongside its runtime errors.

**Firefox 1Password has experimental standalone support.** Install it from **Settings → Discover**, turn off the Safari 1Password copy in Browse, then enable it and approve its requested access. Choose it from a pane's puzzle-piece menu, complete onboarding, and choose **Sign in**. Initial startup can take roughly 20–30 seconds while desktop-app connection attempts time out. Toolbar vault items have been confirmed after sign-in; autofill, save, and account persistence still need testing. Desktop-app unlock is unavailable. Browse's adapters leave the downloaded package unchanged.

This embeds **system WebKit**, the engine Safari uses. macOS has no supported API for embedding the Safari app itself into arbitrary tiled views. Safari extensions, Safari profiles, Safari tab sync, and existing Safari logins are not inherited.

The prototype supports normal web navigation, search, browsing history and address suggestions, pop-up links as new tabs, JavaScript dialogs, and WebKit’s developer inspector. It does not yet implement downloads, permission prompts for camera/microphone, bookmarks, tab reordering, or full browser settings. It is a local prototype, not a hardened or notarized browser distribution.

## Verify

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox
lat check
```

The core tests cover nested split collapse, focus repair, persisted session integrity, resize bounds, and address/search resolution.

History tests cover visit recording, title updates, matching, ranking, completion, retention, persistence, deletion, corrupt-file preservation, and successful-navigation callbacks.

Extension compatibility tests exercise notification permissions and isolation, native event delivery, and main-frame link-opening events. An optional real-package smoke test runs without opening windows or using existing browser data:

```sh
BROWSE_TEST_FIREFOX_PACKAGE=/absolute/path/to/1password.xpi swift test --disable-sandbox --filter firefoxOnboardingSmoke
```

The catalog downloader can also be checked against the pinned official package without enabling it:

```sh
BROWSE_TEST_CATALOG_DOWNLOAD=1 swift test --disable-sandbox --filter catalogDownloadSmoke
```
