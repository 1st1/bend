# uBlock Origin Lite: Safari and Mozilla package comparison

Direct comparison of the installed Safari resources and Mozilla XPI on 2026-11-09. Both declare version **2026.1103.1743**. This is source/package analysis, not a performance benchmark or a full filtering-coverage test.

## Packages examined

- Safari: `/Applications/uBlock Origin Lite.app/Contents/PlugIns/uBlock Origin Lite Extension.appex/Contents/Resources`. The app bundle is already unpacked; its resources were copied to a temporary comparison directory without changing the installed app.
- Mozilla: [official XPI, file 5203987](https://addons.mozilla.org/firefox/downloads/file/5203987/ublock_origin_lite-2026.1103.1743.xpi), extracted after verifying SHA-256 `cca96aed8355bb59168c4af3da638a92dda18378d286af996fbf2013f45d7cc7` against Mozilla metadata.
- Temporary resource snapshot and unified diffs: `/tmp/bend-ubol-comparison/`; extracted Mozilla resources: `/tmp/bend-ubol-mozilla/`. These are disposable analysis artifacts, not dependencies of Bend.

## Shared code

Both packages contain 112 JavaScript files under `js/`; **108 are byte-for-byte identical**. The background, popup, dashboard, mode manager, ruleset manager, scripting manager, and browser-detection module are identical. Only four JavaScript files differ:

| File | Safari build | Mozilla build |
| --- | --- | --- |
| `js/ext-compat.js` | Dedicated WebKit DNR adapter and ruleset reload workaround | Mostly direct native DNR calls |
| `js/ext-offscreen.js` | Explicitly disables offscreen-document support | Emulates an offscreen document with an iframe in the background page |
| `js/scripting/css-api.js` | Retains inserted CSS and reinserts it on `pagereveal` | Can apply a constructed stylesheet immediately; no equivalent reinsertion listener |
| `js/scripting/css-user.js` | Retries custom-filter initialization on `pagereveal` and includes plain-selector insertion | Simpler one-shot initialization focused on procedural selectors |

Across all resource paths, Safari has 909 files and Mozilla has 934. Of the 909 common paths, 791 are byte-identical and 118 differ. Differences include generated rules, translations, manifest metadata, and those four JavaScript modules. Mozilla's additional files include signing metadata and filter resources omitted from Safari.

## The Safari build has material compatibility adaptations

Its `ext-compat.js` filters out dynamic/session rules using header modification or `tabIds`, removes the `object` resource type, and rewrites domain-condition fields for native calls. It normalizes returned domain fields back to the representation used by shared code. These are deliberate compatibility adaptations in the shipped package; their presence alone does not establish which restrictions still apply to the particular WebKit version running Bend.

The adapter also reloads enabled rulesets once for each normal/private realm when a window receives focus, referencing upstream WebKit issue 300236. The Mozilla build lacks this workaround.

Allowlisting differs: Safari constructs an `allow` rule with a wildcard URL and domain restrictions. Mozilla constructs an `allowAllRequests` main-frame rule plus a session rule scoped to `TAB_ID_NONE`. Passing the local site-toggle test does not prove equivalent behavior across subframes, third-party resources, and navigation transitions.

The CSS changes matter to restoring pages and custom filtering. They are not a second ad-blocking engine; both packages still ask the host browser to perform network filtering.

## Filter data and encoding differ substantially

These counts describe the shipped manifest's initially enabled static JSON rules, before startup adjustments, language selection, or user choices. Dynamic and regex rules are separate.

| Measurement | Safari | Mozilla |
| --- | ---: | ---: |
| Declared static rulesets | 51 | 56 |
| Initially enabled static rulesets | 3 | 6 |
| Initially enabled static rule objects | 112,062 | 18,834 |
| Static rule objects across all declared rulesets | 194,373 | 70,299 |
| EasyList static rule objects | 48,903 | 3,718 |
| Unpacked resource bytes | 41,717,648 | 33,216,175 |

The rule-count difference is largely an encoding difference, not a sixfold difference in filtering work or coverage. One Mozilla EasyList rule groups **43,504 domains** in `requestDomains`. Safari expands domain blocking into individual `urlFilter` rules. For example, Mozilla includes `000491b06a.com` in the grouped rule; Safari has an individual `||000491b06a.com/` rule. Both EasyList metadata files report the same 52,951 input filters and identical cosmetic-selector counts.

Safari initially enables `ublock-filters`, `easylist`, and `easyprivacy`. Mozilla additionally enables `pgl`, `ublock-badware`, and `urlhaus-full`. Those three lists are absent from the Safari resources, as are the optional `adguard-spyware-url` and `pol-3` lists. This does not mean their domains are all absent from other Safari lists; overlap was not measured.

Mozilla's initially enabled static rules contain 51 `modifyHeaders` actions; Safari's contain none. Even at the same release version, some input totals and cosmetic resources differ by platform. These packages are not identical filter databases wrapped in different archives.

## Manifest and feature differences

Both use Manifest V3 and the same module background script. Safari explicitly sets `background.persistent` to false; Mozilla omits it. Omission does not establish a persistent background in WebKit. Safari additionally requests `declarativeNetRequestWithHostAccess`; Mozilla requests optional `userScripts` and opens its options page in a tab.

Mozilla's iframe-based offscreen implementation enables code paths that Safari deliberately disables, including paths used for compiling imported/custom filters. The successful smoke test did not exercise those paths, `userScripts`, advanced cosmetic filtering, strict blocking, or long-lived background behavior.

## Bend's uBlock-specific browser detection

The identical `js/ext.js` in both packages detects Safari only when `browser.runtime.getURL('')` starts with `safari-web-extension:`; it detects Firefox for `moz-extension:` and otherwise chooses Chromium.

[ExtensionManager.makeContext](../Sources/Browse/ExtensionManager.swift) now assigns only the Safari uBlock Lite package identity a registered `safari-web-extension://<uuid>/` origin. Other extensions retain `webkit-extension://<uuid>/`. This makes the supported Safari package choose Safari through its own detector, without rewriting its source or returning fictitious resource URLs. Mozilla uBlock Lite is not offered in Bend.

The UUID and native `browser.storage` namespace are preserved. Saved uBlock page URLs using the old scheme are translated after extension restoration; the compatibility bridge recognizes both schemes while retaining its native authorization checks. Origin-scoped web databases are distinct from native extension storage; this change does not implement a general migration of IndexedDB/localStorage for arbitrary extensions. The compared uBlock settings implementation uses native extension storage.

The original `webkit-extension:` scheme falls through to Chromium in the packages' detector. That would skip Safari branches controlling strict blocking, certain subframe CSS operations, and procedural CSS preloading. The per-package origin override enables those branches. It does not supply the Mozilla package with Safari's separate build-time DNR or CSS adaptations.

## Performance conclusion and test limits

The shared code and common host engine provide no evidence of an inherent Mozilla-package slowdown during ordinary browsing. Conversely, fewer JSON rule objects do not prove a speedup: WebKit may translate grouped conditions internally, and the two packages ship different enabled lists and feature paths. Startup, rule-update cost, memory, and real-page rendering require measurement with comparable lists and settings.

The Safari build is specifically adapted for WebKit and is the stronger compatibility baseline. Bend offers only the Safari package. The Mozilla package passed the earlier isolated trial's initial request blocking, popup site-mode changes, disable/re-enable behavior, and package integrity, but is not a supported installation option. Those tests validate a local EasyList-matched script and basic controls, not broad correctness or performance parity. The several-second mode-change delay was observed without a matched Safari timing benchmark.

## Direct Safari distribution

The official [2026.1103.1743 Safari ZIP](https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1103.1743/uBOLite_2026.1103.1743.safari.zip) has SHA-256 `7be53009c38dd47726ce26b3fa02e93ac93e77ac5d276543e855997650128a9c`, matching GitHub release metadata. All 909 resource files from the installed App Store extension are byte-identical in this archive; the archive adds only `README.md`. Bend can load these web-extension resources directly, so its catalog and updater use this Safari archive without requiring the App Store container app. This does not add support for the Mozilla uBlock package.
