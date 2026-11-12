# Extension diagnostics

Redacted runtime logs, WebAssembly diagnostics, and native connection probes.

See [[lat.md/tests/extension-hosting/diagnostics-tests|Test coverage]].

## Extension diagnostic log

[ExtensionDiagnostics.swift](../../../Sources/Browse/ExtensionDiagnostics.swift) records bounded, structured extension lifecycle and desktop-transport metadata across browser restarts without recording account data or message contents.

Each host run and native connection has a correlation UUID. Events identify extension import, restoration, loading, disabling, updates, removal, storage persistence and origin consistency, native-host resolution, process launch/exit, first queued/supplied messages, and final message counts. Process exit status and sanitized error categories distinguish missing helpers, permission failures, framing errors, disconnects, and initialization failures. A launched helper does not establish authenticated desktop integration.

[ExtensionCompatibility.swift](../../../Sources/Browse/ExtensionCompatibility.swift) reports extension-page API availability and categorizes error/rejection events before crossing the native bridge. The host validates the finite category set, rejects website callers, and deduplicates error categories per extension/run. WebKit errors are reduced to known domains, numeric codes, and fixed categories; raw error strings, stacks, URLs, helper stderr, and native-message payloads are excluded from the log and export.

The log lives beside extension metadata as diagnostics.jsonl, with one rotated predecessor; each file is capped at 256 KiB and created with owner-only permissions. Writes happen when events occur so a later process can inspect startup and shutdown. Failed disk writes retain a bounded in-memory fallback and surface a Settings warning. [SettingsWindowController.swift](../../../Sources/Browse/SettingsWindowController.swift) offers Copy Diagnostics, including fresh context snapshots and up to a thousand recent events, plus current native-helper status. Runtime errors appear in this export as sanitized categories and codes rather than inline raw text in extension cards. The export contains metadata from all installed extensions so reinstall-generated identities can be correlated.

## Extension WASM diagnostics

[ExtensionWasmDiagnostics.swift](../../../Sources/Browse/ExtensionWasmDiagnostics.swift) observes WASM resource fetches and asynchronous compilation/instantiation inside extension pages, distinguishing the original failure from later core-not-initialized errors.

The adapter observes only same-extension .wasm fetches and WebAssembly's asynchronous compile/instantiate methods. It forwards fulfillment values and rejection objects, never consumes response bodies, and does not supply a MIME workaround or retry. Observers add a promise continuation; they do not diagnose vendor initialization after instantiation completes. Each page emits at most 96 observations. The host validates finite metadata values and deduplicates identical observations per context/run before recording wasmOperation events in [[lat.md/architecture/extensions/diagnostics#Extension diagnostic log]].

Metadata includes background versus other extension page, operation/stage, response type, success flag, MIME category, and classified failures such as MIME rejection, CSP, compilation, linking, and runtime traps. URLs, resource names, module contents, exports, stacks, and raw errors never cross the diagnostic bridge. [[lat.md/tests/extension-hosting/diagnostics-tests#Firefox WASM process restart]] exercises fresh and restored account-free startup with separate test processes; authenticated startup and desktop unlock are outside its coverage.

## 1Password connection probe

[OnePasswordConnectionProbe.swift](../../../Sources/Browse/OnePasswordConnectionProbe.swift) provides a status-only diagnostic invocation under Bend's own signed identity and application path, without creating browser windows or opening the user profile.

Running the built Bend executable with --diagnose-1password launches the registered helper and requests native-autofill feature status. It does not request accounts, credentials, delegated sessions, or unlocking. The probe waits up to ten seconds and prints only response types and allowlisted protocol error names, exiting successfully only for a matching Success response. It does not change the desktop app's trust configuration.

The same summary is included in production nativeProtocolStatus events for 1Password connections. It exposes known protocol types/error names and bounded, validated browser bundle identities from browser_state, never Success contents, callback IDs, account fields, or arbitrary error prose. These events distinguish protocol rejection from a pipe failure.

The probe and Settings perform a certificate preflight against the Apple distribution-certificate requirement observed in the installed 1Password helper, and inspect the Hardened Runtime flag. The default Developer ID Application build passes both checks; Apple Development signing fails the certificate requirement. Settings explains that blocker rather than suggesting reinstalling. The signed app must be installed in Applications and added through 1Password's Settings → Browser → Add Browser. The user has manually confirmed accounts available without separate extension sign-in and successful Touch ID unlock from the extension after locking the desktop app with this setup. The standalone status-only probe still times out from Applications even when the actual extension works, so that timeout does not establish integration failure. The preflight does not replace 1Password's own validation or change its trust settings.

## Extension runtime diagnostics

[runtime.swift](../../../Tools/ExtensionProbe/runtime.swift) exercises real extension startup, actions, and extension-owned pages in a windowless app with temporary WebKit storage. It is separate from the production extension host.

The [runtime wrapper](../../../scripts/probe-extension-runtime.sh) signs a disposable app, enforces a bounded runtime, and removes its bundle on exit. The controller, background views, and test tab share an explicitly nonpersistent website data store. The diagnostic context grants private-data access only for that isolated store because WebKit otherwise filters its events. Bend's production permission policy remains unchanged. External tab requests fail explicitly; extension-owned tabs load invisibly. Diagnostics report page errors, selected console messages, action delivery, and rendered text without signing into an account.

The [Firefox 1Password reproduction](../../../scripts/probe-onepassword-firefox.sh) verifies a pinned Mozilla package checksum before extraction. Its baseline uses unmodified resources. The explicit diagnostic-startup mode guards one unsupported navigation listener in a temporary copy and injects [notification registration placeholders](../../../Tools/ExtensionProbe/startup-notifications.js); notification operations throw errors. This mode tests later startup stages, not API compatibility. It does not install or modify production packages. Research results and remaining limitations live in [extension-support-research.md](../../../docs/extension-support-research.md).
