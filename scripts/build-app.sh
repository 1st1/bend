#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build -c release --disable-sandbox
app="$PWD/dist/Browse.app"
mkdir -p "$app/Contents/MacOS"
bin_dir="$(swift build -c release --show-bin-path)"
cp "$bin_dir/Browse" "$app/Contents/MacOS/Browse"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Browse</string>
  <key>CFBundleDisplayName</key><string>Browse</string>
  <key>CFBundleIdentifier</key><string>dev.yury.browse.prototype</string>
  <key>CFBundleExecutable</key><string>Browse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict></plist>
PLIST
# @lat: [[architecture#Development signing]]
codesign --force --sign "${BROWSE_SIGNING_IDENTITY:-Apple Development: Yury Selivanov (H8TFDJMW7E)}" "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
if [[ "${1:-}" == "--open" ]]; then open "$app"; fi
