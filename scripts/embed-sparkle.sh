#!/bin/bash
set -euo pipefail
# Copy the pinned SwiftPM artifact without losing symlinks, then sign inside-out.
app="$1"
identity="$2"
source_framework='.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
[[ -d "$source_framework" ]] || { printf 'Sparkle artifact missing; resolve Swift packages first.\n' >&2; exit 1; }
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE"
ditto "$source_framework" "$app/Contents/Frameworks/Sparkle.framework"
# SwiftPM adds absolute development framework search paths. Packaged apps must
# use their embedded copy even on a machine that still has the checkout.
runpaths="$(otool -l "$app/Contents/MacOS/Bend" | awk '/cmd LC_RPATH/ { found=1; next } found && /path / { sub(/^ *path /, ""); sub(/ \(offset.*$/, ""); print; found=0 }')"
while IFS= read -r runpath; do
  case "$runpath" in "$PWD"/.build/*) install_name_tool -delete_rpath "$runpath" "$app/Contents/MacOS/Bend" ;; esac
done <<< "$runpaths"
framework="$app/Contents/Frameworks/Sparkle.framework"
for component in Versions/B/XPCServices/Downloader.xpc Versions/B/XPCServices/Installer.xpc Versions/B/Autoupdate Versions/B/Updater.app; do
  codesign --force --options runtime --timestamp --sign "$identity" "$framework/$component"
done
codesign --force --options runtime --timestamp --sign "$identity" "$framework"
codesign --verify --deep --strict "$framework"
