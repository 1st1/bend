#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BROWSE_TEST_FIREFOX_PACKAGE:?Set BROWSE_TEST_FIREFOX_PACKAGE to a local official 1Password XPI}"
export BROWSE_TEST_WASM_PROFILE
BROWSE_TEST_WASM_PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/browse-wasm-restart.XXXXXX")"
trap 'rm -rf "$BROWSE_TEST_WASM_PROFILE"' EXIT
# Separate runners ensure the WebKit host really exits between the two phases.
# Both phases use the same unique, persistent stores, never the default profile.
BROWSE_TEST_WASM_PHASE=install swift test --disable-sandbox --no-parallel --filter firefoxWasmProcessRestart
BROWSE_TEST_WASM_PHASE=restore swift test --skip-build --disable-sandbox --no-parallel --filter firefoxWasmProcessRestart
