#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-cache}"
# Match the app's linked SDK so AppKit uses the same compatibility behavior.
# Native tests share NSApplication, menus, and focus; run them serially.
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
# Test binaries use process-local credential storage, never the user's Keychain.
test_command=(swift test --disable-sandbox --no-parallel -Xswiftc -DBEND_TESTING
  -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$sdk_version")
# The standalone CLT ships Swift Testing outside the SDK framework search path.
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$developer_dir" == */CommandLineTools ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  test_command+=(--enable-swift-testing --disable-xctest
    -Xswiftc "-F$frameworks" -Xlinker "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks"
    -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib"
    -Xswiftc -load-plugin-library -Xswiftc "$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib")
fi
if [[ $# -gt 0 ]]; then
  if [[ "${BEND_VM_PREBUILT:-0}" == 1 ]]; then test_command+=(--skip-build); fi
  "${test_command[@]}" "$@"
else
  python3 scripts/test-all.py "${test_command[@]}"
fi
