#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-cache}"
# Match the app's linked SDK so AppKit uses the same compatibility behavior.
# Native tests share NSApplication, menus, and focus; run them serially.
# Preserve completion reports when AppKit tests exit through SwiftPM's pipes.
export NSUnbufferedIO=YES
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
# Test binaries use process-local credential storage, never the user's Keychain.
test_command=(swift test --disable-sandbox --no-parallel -Xswiftc -DBEND_TESTING
  -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$sdk_version")
if [[ $# -gt 0 ]]; then
  "${test_command[@]}" "$@"
else
  python3 scripts/test-all.py "${test_command[@]}"
fi
