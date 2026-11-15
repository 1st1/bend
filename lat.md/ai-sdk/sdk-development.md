# Development

Bend’s root Swift package builds the owned library and example. Offline fixtures separate orchestration and protocol tests from the optional loopback tests that exercise real networking.

## Build and validation

The package uses Swift 6 and its bundled Testing framework; Python 3 is needed only for the HTTP fixture runner.

Run these commands from Bend’s root. [[docs/ai-sdk.md]] contains API examples, and [[Package.swift]] defines targets and platform minimums.

```bash
./scripts/build-app.sh
./scripts/test.sh --filter AITests
python3 scripts/test-ai-http.py
lat check
```

The ordinary test run executes the offline cases and skips the HTTP suite unless its fixture environment variable is set. The Python runner starts the fixture, supplies that variable, runs only the HTTP suite, and shuts down the server. Offline and loopback tests use no model credentials. Functional Gateway and OpenAI account tests use scripted HTTP transports and synthetic credentials; no tests make paid model calls. Bend’s full test runner includes AITests as one non-AppKit group.

## Test infrastructure

Tests replace the provider or HTTP transport at the relevant boundary so failures can be isolated without calling a remote model.

[[Tests/AITests/Support.swift#Script]] records requests and returns scripted model responses through [[Tests/AITests/Support.swift#ScriptedProvider]]. Agent tests can inspect follow-up history and count requests independently of serialization.

[[Tests/AITests/Support.swift#FixtureTransport]] supplies status and body chunks to the real provider. [[Tests/AITests/Support.swift#fixtureProvider]] splits response data into individual bytes to exercise framing and UTF-8 assembly. [[Tests/AITests/Support.swift#drain]] captures events and the final result while arranging cancellation cleanup.

[[scripts/test-ai-http.py]] runs a loopback HTTP server. [[scripts/test-ai-http.py#Handler#do_POST]] sends the first delta before waiting for an acknowledgement; [[scripts/test-ai-http.py#Handler#do_GET]] releases the rest and reports connection cancellation. This distinguishes true incremental delivery from whole-body buffering. [[Tests/AITests/HTTPIntegrationTests.swift#HTTPIntegration]] enables those cases only when AI_HTTP_FIXTURE_URL is present.

[[lat.md/ai-sdk/sdk-tests#Behavior specifications]] records the contracts checked by existing tests. Each leaf specification has one adjacent test-code reference, enforced by Lat.

## Runnable example

The example composes a parent agent, a researcher subagent, and a local facts tool to demonstrate delegation and separate output streams.

[[Sources/AgentExample/main.swift#AgentExample#main]] reads AI_MODEL and uses the Gateway credential path by default. When AI_BASE_URL parses as a URL, it creates a compatible provider using optional AI_API_KEY instead. The command-line arguments form the user prompt, with a default planet question when empty.

The facts tool returns local data; model requests remain remote. Parent text is written to standard output, immediate child text to standard error, and the final line reports parent steps and tokens. With credentials configured, run:

```bash
swift run agent-example 'Tell me about Mars.'
```
