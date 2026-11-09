#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh
configuration=debug
profile=debug
app_name='Bend Debug'
bundle_id=dev.yury.browse.debug
open_app=false
output=''
compiler_flags=(-Xswiftc -DBEND_DEBUG)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --production)
      configuration=release; profile=production; app_name=Bend; bundle_id=dev.yury.browse.prototype
      compiler_flags=(-Xswiftc -DBEND_PRODUCTION); shift ;;
    --open) open_app=true; shift ;;
    --output)
      [[ $# -ge 2 && -n "$2" ]] || { printf 'Missing --output path\n' >&2; exit 2; }
      output="$2"; shift 2 ;;
    *) printf 'Usage: %s [--production] [--output PATH] [--open]\n' "$0" >&2; exit 2 ;;
  esac
done
app="${output:-$PWD/dist/$app_name.app}"
# Normalize the publication path before creating its sibling staging directory.
mkdir -p "$(dirname "$app")"
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
# Retain the real linked SDK while deploying to macOS 26.
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c "$configuration" --disable-sandbox "${compiler_flags[@]}" \
  -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$sdk_version"
mkdir -p "$PWD/dist"
staging="$(mktemp -d "$(dirname "$app")/.build-app.XXXXXX")"
cleanup() {
  # If publication failed after moving the previous bundle, put it back.
  if [[ ! -e "$app" && -d "$staging/Previous.app" ]]; then
    mv "$staging/Previous.app" "$app"
  fi
  rm -rf "$staging"
}
trap cleanup EXIT
candidate="$staging/$app_name.app"
mkdir -p "$candidate/Contents/MacOS" "$candidate/Contents/Resources"
cp "$PWD/Assets/AppIcon.icns" "$candidate/Contents/Resources/AppIcon.icns"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
cp "$bin_dir/Bend" "$candidate/Contents/MacOS/Bend"
cat > "$candidate/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$app_name</string>
  <key>CFBundleDisplayName</key><string>$app_name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>BendBuildProfile</key><string>$profile</string>
  <key>CFBundleExecutable</key><string>Bend</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>HTML document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.html</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>XHTML document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.xhtml</string></array>
    </dict>
  </array>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Web URLs</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict></plist>
PLIST
# @lat: [[architecture#Development signing]]
codesign --force --options runtime --sign "${BEND_SIGNING_IDENTITY:-${BROWSE_SIGNING_IDENTITY:-Developer ID Application: Yury Selivanov (QA7X6JBN4H)}}" "$candidate"
codesign --verify --strict "$candidate"
# Never overwrite or re-sign files mapped by a running Bend process.
# Publish only after signing succeeds; keep the old bundle for rollback.
if [[ -e "$app" ]]; then mv "$app" "$staging/Previous.app"; fi
mv "$candidate" "$app"
printf 'Built %s\n' "$app"
printf 'Restart %s to use this build.\n' "$app_name"
if [[ "$open_app" == true ]]; then open "$app"; fi
