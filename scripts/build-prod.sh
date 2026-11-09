#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'HELP'
Usage: ./scripts/build-prod.sh [--keychain-profile NAME]

Build a signed, notarized drag-to-Applications installer in dist/.
Requires a logged-in macOS desktop session (Finder configures the DMG layout).

Environment:
  BEND_NOTARY_PROFILE    Keychain credentials profile (default: bend-notary)
  BEND_SIGNING_IDENTITY  Developer ID Application certificate
HELP
}
profile="${BEND_NOTARY_PROFILE:-bend-notary}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keychain-profile)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      profile="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
identity="${BEND_SIGNING_IDENTITY:-${BROWSE_SIGNING_IDENTITY:-Developer ID Application: Yury Selivanov (QA7X6JBN4H)}}"
mkdir -p dist
work="$(mktemp -d "$PWD/dist/.build-prod.XXXXXX")"
logs="$(mktemp -d "$PWD/dist/notary-$(date +%Y%m%d-%H%M%S).XXXXXX")"
mount="$work/mount"
attached=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$attached" == true ]]; then
    if ! hdiutil detach "$mount"; then
      printf 'Could not detach installer volume; retained working files at %s\n' "$work" >&2
      exit 1
    fi
  fi
  rm -rf "$work"
  if [[ $status -ne 0 ]]; then printf 'Production build failed. Notarization logs: %s\n' "$logs" >&2; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# @lat: [[architecture#Production installer]]
notarize() {
  local artifact="$1" label="$2" result="$logs/$2-submission.json"
  printf 'Notarizing %s (Keychain profile: %s)…\n' "$label" "$profile"
  local submitted=0
  xcrun notarytool submit "$artifact" --keychain-profile "$profile" \
    --wait --timeout 30m --output-format json > "$result" || submitted=$?
  local submission status
  submission="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  if [[ -n "$submission" ]]; then
    printf 'Submission %s: %s\n' "$submission" "$status"
    xcrun notarytool log "$submission" --keychain-profile "$profile" "$logs/$label-log.json" || true
  fi
  if [[ $submitted -ne 0 || "$status" != Accepted ]]; then
    cat "$result" >&2
    printf 'Notarization did not accept %s. See %s\n' "$label" "$logs" >&2
    return 1
  fi
}

staple() {
  local artifact="$1" attempt
  for attempt in 1 2 3 4 5; do
    if xcrun stapler staple "$artifact"; then
      xcrun stapler validate "$artifact"
      return
    fi
    [[ $attempt -eq 5 ]] || sleep 5
  done
  printf 'Could not staple ticket to %s\n' "$artifact" >&2
  return 1
}

payload="$work/payload"
mkdir -p "$payload/.background"
app="$payload/Bend.app"
./scripts/build-app.sh --production --output "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BendBuildProfile' "$app/Contents/Info.plist")" == production ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == dev.yury.browse.prototype ]]
# Sign the private release copy with an explicit secure timestamp.
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict "$app"
codesign --display --verbose=4 "$app" 2> "$logs/app-signature.txt"
if ! grep -q '^Authority=Developer ID Application:' "$logs/app-signature.txt"; then
  printf 'Production builds require a Developer ID Application certificate.\n' >&2
  exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9A-Za-z._-]+$ ]] || { printf 'Invalid version for installer filename\n' >&2; exit 1; }
architectures="$(lipo -archs "$app/Contents/MacOS/Bend")"
case "$architectures" in
  arm64|x86_64) architecture="$architectures" ;;
  *arm64*x86_64*|*x86_64*arm64*) architecture=universal ;;
  *) printf 'Unsupported executable architectures: %s\n' "$architectures" >&2; exit 1 ;;
esac
output="$PWD/dist/Bend-$version-$architecture.dmg"
ditto -c -k --keepParent "$app" "$work/Bend.zip"
notarize "$work/Bend.zip" app
staple "$app"
spctl --assess --type execute --verbose=2 "$app"

ln -s /Applications "$payload/Applications"
swift scripts/render-dmg-background.swift "$payload/.background/background.tiff"
size_kb="$(du -sk "$payload" | awk '{print $1}')"
size_mb=$((size_kb / 1024 + 40))
# Finder resolves root-folder aliases through volume names. Avoid targeting an
# already-mounted, read-only Bend installer while configuring this writable one.
volume_name="Bend Installer ${work##*.}"
hdiutil create -volname "$volume_name" -fs HFS+ -format UDRW -size "${size_mb}m" \
  -srcfolder "$payload" "$work/installer.dmg"
mkdir -p "$mount"
hdiutil attach "$work/installer.dmg" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$mount"
attached=true
osascript scripts/layout-dmg.applescript "$mount"
# Finder writes its icon layout asynchronously when the window closes.
for attempt in 1 2 3 4 5; do
  [[ ! -f "$mount/.DS_Store" ]] || break
  sleep 1
done
[[ -f "$mount/.DS_Store" ]] || { printf 'Finder did not save the installer layout\n' >&2; exit 1; }
diskutil renameVolume "$mount" Bend
sync
hdiutil detach "$mount"
attached=false
hdiutil convert "$work/installer.dmg" -format UDZO -imagekey zlib-level=9 -o "$work/Bend.dmg"
codesign --force --timestamp --sign "$identity" "$work/Bend.dmg"
codesign --verify --strict "$work/Bend.dmg"
notarize "$work/Bend.dmg" dmg
staple "$work/Bend.dmg"
hdiutil verify "$work/Bend.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$work/Bend.dmg"
# Replace an earlier release only after every validation succeeds.
mv -f "$work/Bend.dmg" "$output"
printf '\nReady to distribute: %s\nNotarization logs: %s\n' "$output" "$logs"
