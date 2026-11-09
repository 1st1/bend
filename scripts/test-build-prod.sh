#!/bin/bash
set -euo pipefail
root="$(mktemp -d "${TMPDIR:-/tmp}/bend-prod-test.XXXXXX")"
root="$(cd "$root" && pwd)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/scripts" "$root/bin" "$root/dist/Bend.app/Contents/MacOS"
cp "$(dirname "$0")/build-prod.sh" "$root/scripts/"
export BEND_PROD_TEST_ROOT="$root"
export PATH="$root/bin:$PATH"
export BEND_SIGNING_IDENTITY='Developer ID Application: Test (TESTTEAM)'
export BEND_NOTARY_PROFILE='test-profile'
cat > "$root/dist/Bend.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleIdentifier</key><string>dev.yury.browse.prototype</string>
<key>BendBuildProfile</key><string>production</string>
</dict></plist>
PLIST
printf 'executable' > "$root/dist/Bend.app/Contents/MacOS/Bend"
cat > "$root/scripts/build-app.sh" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "$1" == --production && "$2" == --output ]]
ditto "$BEND_PROD_TEST_ROOT/dist/Bend.app" "$3"
SH
mkdir -p "$root/dist/Bend Debug.app"
printf 'debug sentinel' > "$root/dist/Bend Debug.app/sentinel"
cat > "$root/bin/codesign" <<'SH'
#!/bin/bash
if [[ "$1" == --display ]]; then
  printf 'Authority=Developer ID Application: Test (TESTTEAM)\nTimestamp=now\n' >&2
elif [[ "$1" == --force && "${!#}" == *.dmg ]]; then
  printf 'dmg-sign\n' >> "$BEND_PROD_TEST_ROOT/events"
fi
SH
cat > "$root/bin/xcrun" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "$1 $2" == 'notarytool submit' ]]; then
  [[ "$*" == *'--keychain-profile test-profile'* ]]
  if [[ "$3" == *.zip ]]; then label=app; else label=dmg; fi
  printf '%s-notary\n' "$label" >> "$BEND_PROD_TEST_ROOT/events"
  if [[ "${BEND_PROD_TEST_FAIL:-}" == "$label-notary" ]]; then status=Invalid; else status=Accepted; fi
  printf '{"id":"test-%s","status":"%s"}\n' "$label" "$status"
elif [[ "$1 $2" == 'notarytool log' ]]; then
  printf '{"issues":null}\n' > "${!#}"
elif [[ "$1" == stapler ]]; then
  if [[ "$3" == *.app ]]; then label=app; else label=dmg; fi
  if [[ "$2" == staple ]]; then
    printf '%s-staple\n' "$label" >> "$BEND_PROD_TEST_ROOT/events"
    if [[ "$label" == app ]]; then touch "$3/.ticket"; fi
  elif [[ "${BEND_PROD_TEST_FAIL:-}" == "$label-validate" ]]; then exit 1; fi
else exit 2; fi
SH
cat > "$root/bin/hdiutil" <<'SH'
#!/bin/bash
set -euo pipefail
command="$1"; shift
case "$command" in
  create)
    output="${!#}"
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -volname ]]; then [[ "$2" == 'Bend Installer '* ]]; fi
      if [[ "$1" == -srcfolder ]]; then payload="$2"; shift; fi
      shift
    done
    [[ -f "$payload/Bend.app/.ticket" ]]
    [[ "$(readlink "$payload/Applications")" == /Applications ]]
    [[ -f "$payload/.background/background.tiff" ]]
    printf 'image-create\n' >> "$BEND_PROD_TEST_ROOT/events"
    printf 'new installer' > "$output" ;;
  attach) touch "$BEND_PROD_TEST_ROOT/mounted" ;;
  detach) rm "$BEND_PROD_TEST_ROOT/mounted" ;;
  convert) cp "$1" "${!#}" ;;
  verify) [[ "${BEND_PROD_TEST_FAIL:-}" != dmg-verify ]] ;;
  *) exit 2 ;;
esac
SH
cat > "$root/bin/diskutil" <<'SH'
#!/bin/bash
[[ "$1" == renameVolume && "$2" == "$BEND_PROD_TEST_ROOT"/dist/.build-prod.*/mount && "$3" == Bend ]]
SH
cat > "$root/bin/osascript" <<'SH'
#!/bin/bash
[[ "${BEND_PROD_TEST_FAIL:-}" != layout ]] || exit 1
touch "$2/.DS_Store"
SH
cat > "$root/bin/swift" <<'SH'
#!/bin/bash
touch "$2"
SH
cat > "$root/bin/spctl" <<'SH'
#!/bin/bash
if [[ "${!#}" == *.dmg ]]; then printf 'dmg-assess\n' >> "$BEND_PROD_TEST_ROOT/events"; fi
SH
printf '#!/bin/bash\nprintf "arm64\\n"\n' > "$root/bin/lipo"
chmod +x "$root/bin/"* "$root/scripts/build-app.sh"
installer="$root/dist/Bend-1.2.3-arm64.dmg"
printf 'previous installer' > "$installer"
for failure in app-notary layout dmg-notary dmg-validate dmg-verify; do
  if BEND_PROD_TEST_FAIL="$failure" bash "$root/scripts/build-prod.sh" > "$root/test.log" 2>&1; then
    printf 'Expected failure: %s\n' "$failure" >&2; exit 1
  fi
  [[ "$(cat "$installer")" == 'previous installer' ]]
  [[ ! -e "$root/mounted" ]]
  [[ -z "$(find "$root/dist" -maxdepth 1 -name '.build-prod.*' -print)" ]]
done
failed_logs="$(find "$root/dist" -maxdepth 1 -type d -name 'notary-*' -print | sort)"
[[ "$(printf '%s\n' "$failed_logs" | wc -l | tr -d ' ')" == 5 ]]
while IFS= read -r log_dir; do
  [[ -s "$log_dir/app-submission.json" && -s "$log_dir/app-log.json" ]]
done <<< "$failed_logs"
: > "$root/events"
BEND_NOTARY_PROFILE=ignored bash "$root/scripts/build-prod.sh" --keychain-profile test-profile \
  > "$root/test.log" 2>&1 || { cat "$root/test.log"; exit 1; }
[[ "$(cat "$installer")" == 'new installer' ]]
[[ ! -e "$root/mounted" && ! -e "$root/dist/Bend.app/.ticket" ]]
[[ -z "$(find "$root/dist" -maxdepth 1 -name '.build-prod.*' -print)" ]]
[[ "$(find "$root/dist" -maxdepth 1 -type d -name 'notary-*' -print | sort)" == "$failed_logs" ]]
expected=$'app-notary\napp-staple\nimage-create\ndmg-sign\ndmg-notary\ndmg-staple\ndmg-assess'
[[ "$(cat "$root/events")" == "$expected" ]]
[[ "$(cat "$root/dist/Bend Debug.app/sentinel")" == 'debug sentinel' ]]
printf 'Production installer publication tests passed\n'
