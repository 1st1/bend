#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/BrowseRuntimeProbe.XXXXXX")"
trap 'rm -rf "$probe_root"' EXIT
app="$probe_root/BrowseRuntimeProbe.app"
mkdir -p "$app/Contents/MacOS"
clang -fobjc-arc -c Tools/ExtensionProbe/features.m -o "$probe_root/features.o"
swiftc -import-objc-header Tools/ExtensionProbe/features.h Tools/ExtensionProbe/runtime.swift \
    "$probe_root/features.o" -o "$app/Contents/MacOS/BrowseRuntimeProbe"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'dev.yury.browse.runtime-probe',
                  'CFBundleExecutable': 'BrowseRuntimeProbe',
                  'CFBundleName': 'Browse Runtime Probe',
                  'CFBundlePackageType': 'APPL', 'LSUIElement': True}, f)
PY
codesign --force --sign "${BROWSE_PROBE_SIGNING_IDENTITY:-Browse Dev}" "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/BrowseRuntimeProbe" "$@"
