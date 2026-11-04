#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/BrowseExtensionProbe.XXXXXX")"
trap 'rm -rf "$probe_root"' EXIT
app="$probe_root/BrowseExtensionProbe.app"
mkdir -p "$app/Contents/MacOS"
clang -fobjc-arc -framework AppKit -framework SafariServices \
    Tools/ExtensionProbe/native-host.m -o "$app/Contents/MacOS/BrowseExtensionProbe"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'dev.yury.browse.extension-probe',
                  'CFBundleExecutable': 'BrowseExtensionProbe',
                  'CFBundleName': 'Browse Extension Probe',
                  'CFBundlePackageType': 'APPL', 'LSUIElement': True}, f)
PY
signing_options=(--force --sign "${BROWSE_PROBE_SIGNING_IDENTITY:-Browse Dev}")
if [[ "${BROWSE_PROBE_HOST_ENTITLEMENT:-0}" == "1" ]]; then
    cat > "$probe_root/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.private.can-load-any-content-blocker</key><true/>
</dict></plist>
PLIST
    signing_options+=(--entitlements "$probe_root/entitlements.plist")
fi
codesign "${signing_options[@]}" "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/BrowseExtensionProbe" "${1:-com.1password.safari.extension}"
