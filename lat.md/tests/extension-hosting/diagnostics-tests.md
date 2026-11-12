---
lat:
  require-code-mention: true
---
# Extension diagnostics tests

Tests verify redacted runtime logs, WebAssembly diagnostics, and native connection probes.

See [[lat.md/architecture/extensions/diagnostics|Architecture and behavior]].

## Extension WASM diagnostic behavior

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) checks real WASM MIME rejection, ArrayBuffer fallback, invalid-module errors, observer failure isolation, and redaction in an isolated WebKit extension page.

The observer preserves results and the original rejection object, does not consume fetched module bodies, excludes sentinel resource/error text from metadata, and rejects invalid diagnostic enums at the native bridge.

## Firefox WASM process restart

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) optionally verifies real Firefox 1Password WASM startup and account-free onboarding across two separate test processes using shared, unique persistent stores.

Run [test-extension-wasm-restart.sh](../../../scripts/test-extension-wasm-restart.sh) with BROWSE_TEST_FIREFOX_PACKAGE pointing to a local official XPI. The install phase saves store identifiers and extension origin; the restore phase must instantiate background WASM, retain the origin, and open onboarding without context errors. Both phases decline optional onboarding choices. A dummy native helper prevents desktop-app access. This does not test authenticated accounts, unlock, Touch ID, or the user's existing profile.

## Extension diagnostic logging

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies diagnostic persistence across logger instances, bounded rotation, owner-only files, safe error categories, and a memory fallback when disk writes fail.

Native-message integration checks require request, resolution, launch, first-send/receive, disconnect, rejection, and exit events, while excluding fixture payloads and Gecko IDs. An extension-page error containing a synthetic secret must emit only its category and error type; arbitrary categories are rejected. These diagnostics do not assert that the user's 1Password account or desktop handshake succeeds.

## 1Password protocol diagnostic redaction

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies that native response summaries expose only known protocol types and error names, never arbitrary response fields or synthetic account secrets.

Success contents are excluded entirely, unknown enum values become a generic label, recognized failure names survive redaction without callback IDs or error prose, and browser identities are decoded only from the protocol's browser_state field with bounded identifier validation. These unit checks do not establish desktop authentication or Touch ID compatibility.
