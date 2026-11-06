#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
# SwiftPM's Swift Build backend can stamp the deployment target as the linked
# SDK, which puts AppKit in legacy appearance mode. Supply the actual SDK while
# retaining the package's macOS 14 deployment target.
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c release --disable-sandbox \
  -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version"
app="$PWD/dist/Bend.app"
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
candidate="$staging/Bend.app"
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
cp "$PWD/Assets/AppIcon.icns" "$candidate/Contents/Resources/AppIcon.icns"
bin_dir="$(swift build -c release --show-bin-path)"
cp "$bin_dir/Bend" "$candidate/Contents/MacOS/Bend"
cat > "$candidate/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Bend</string>
  <key>CFBundleDisplayName</key><string>Bend</string>
  <key>CFBundleIdentifier</key><string>dev.yury.browse.prototype</string>
  <key>CFBundleExecutable</key><string>Bend</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict></plist>
PLIST
# @lat: [[architecture#Development signing]]
codesign --force --options runtime --sign "${BEND_SIGNING_IDENTITY:-${BROWSE_SIGNING_IDENTITY:-Apple Development: Yury Selivanov (H8TFDJMW7E)}}" "$candidate"
codesign --verify --strict "$candidate"
# Never overwrite or re-sign files mapped by a running Bend process.
# Publish only after signing succeeds; keep the old bundle for rollback.
if [[ -e "$app" ]]; then mv "$app" "$staging/Previous.app"; fi
mv "$candidate" "$app"
printf 'Built %s\n' "$app"
printf 'Restart Bend to use this build. Extension data is preserved.\n'
if [[ "${1:-}" == "--open" ]]; then open "$app"; fi
