#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build -c release --disable-sandbox
app="$PWD/dist/Browse.app"
mkdir -p "$PWD/dist"
staging="$(mktemp -d "$PWD/dist/.build-app.XXXXXX")"
cleanup() {
  # If publication failed after moving the previous bundle, put it back.
  if [[ ! -e "$app" && -d "$staging/Previous.app" ]]; then
    mv "$staging/Previous.app" "$app"
  fi
  rm -rf "$staging"
}
trap cleanup EXIT
candidate="$staging/Browse.app"
mkdir -p "$candidate/Contents/MacOS"
bin_dir="$(swift build -c release --show-bin-path)"
cp "$bin_dir/Browse" "$candidate/Contents/MacOS/Browse"
cat > "$candidate/Contents/Info.plist" <<'PLIST'
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
codesign --force --sign "${BROWSE_SIGNING_IDENTITY:-Apple Development: Yury Selivanov (H8TFDJMW7E)}" "$candidate"
codesign --verify --strict "$candidate"
# Never overwrite or re-sign files mapped by a running Browse process.
# Publish only after signing succeeds; keep the old bundle for rollback.
if [[ -e "$app" ]]; then mv "$app" "$staging/Previous.app"; fi
mv "$candidate" "$app"
printf 'Built %s\n' "$app"
printf 'Restart Browse to use this build. Extension data is preserved.\n'
if [[ "${1:-}" == "--open" ]]; then open "$app"; fi
