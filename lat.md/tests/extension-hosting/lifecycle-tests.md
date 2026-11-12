---
lat:
  require-code-mention: true
---
# Extension lifecycle tests

Tests verify extension contexts, permissions, restoration, and private-window boundaries.

See [[lat.md/architecture/extensions/lifecycle|Architecture and behavior]].

## Extension lifecycle and permissions

[ExtensionTests.swift](../../../Tests/BrowseTests/ExtensionTests.swift) verifies disabled imports, permission denial and approval, website scope, copied resources, enable/disable behavior, and stable extension identity and grants after restoration.

## Enabled extension restoration

[ExtensionTests.swift](../../../Tests/BrowseTests/ExtensionTests.swift) recreates the extension host with an isolated persistent profile, verifying enabled state, stable origin, restored grants, and successive storage writes without the original package source.

The fixture unloads runtime contexts without disabling the saved preference. Four iterations read the previous iteration's extension storage, localStorage, and IndexedDB values, including decrypting a fixture ciphertext with a persisted nonextractable WebCrypto key. This exercises host recreation within one test process, not a signed-app upgrade or an authenticated password-manager session.

## Extension startup content injection

[[Tests/BrowseTests/ExtensionTests.swift#extensionStartupContentInjection]] starts navigation during extension restoration and verifies content-script injection across four host recreations.

WebKit compiles request rules asynchronously after context loading. The test awaits an explicit fixture ruleset update before checking blocking on a fresh navigation and before unloading the context. It does not claim first-navigation request blocking.

## Firefox extension restoration smoke test

[ExtensionTests.swift](../../../Tests/BrowseTests/ExtensionTests.swift) optionally exercises Firefox 1Password from `BROWSE_TEST_FIREFOX_PACKAGE`, checking enablement, origin, background loading, and toolbar actions across three host recreations in isolated storage.

The smoke test waits for background errors, invokes the toolbar action, and verifies that the resulting document renders 1Password's welcome page. It uses a fake notification provider and does not display windows, sign in, read a real vault, or verify authenticated autofill. Host recreation within one process is not a signed-app upgrade test.

## Extension content injection and blocking

[ExtensionTests.swift](../../../Tests/BrowseTests/ExtensionTests.swift) loads a local HTTP fixture in real WebKit, verifies content injection and declarative blocking, then checks both disappear after disable/reload. It also verifies pane registration and active-tab changes.

## Private extension access

[[Tests/BrowseTests/ExtensionTests.swift#privateExtensionAccess]] verifies persisted opt-ins, private-tab queries, script injection, request blocking, revocation, and refusal to supply shared extension configurations to private panes.

The restored host completes an awaited ruleset disable/enable cycle and demonstrates content injection and request blocking before unload. This synchronizes teardown with WebKit’s asynchronous rule loading instead of racing its database callbacks or relying on a fixed delay.

## Private extension iframe isolation

[[Tests/BrowseTests/ExtensionTests.swift#privateExtensionIframeIsolation]] verifies private panes reject extension documents that would let HTTP iframes read or write regular-profile cookies, including after opt-in.

A loopback HTTP iframe first demonstrates both cookie access and writes in an isolated regular profile. The regression then exercises configuration lookup, direct controller navigation, extension tab navigation and creation, lazy page loading, and popup rejection. Private views remain nonpersistent, and the regular cookie store remains unchanged both before and after private-window teardown.

## Extension permission presentation

[[Tests/BrowseTests/ExtensionPermissionTests.swift#extensionPermissionPresentation]] verifies readable permission summaries, exact website restrictions, unknown-permission visibility, deduplication, and denial when the native dialog is closed.
