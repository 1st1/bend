#!/bin/bash
set -euo pipefail
# Exercise the actual packaging script with isolated compiler/signing stand-ins.
root="$(mktemp -d "${TMPDIR:-/tmp}/browse-build-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/scripts" "$root/bin" "$root/dist/Bend Debug.app/Contents/MacOS"
cp "$(dirname "$0")/build-app.sh" "$root/scripts/build-app.sh"
cp "$(dirname "$0")/version.sh" "$root/scripts/version.sh"
cp "$(dirname "$0")/embed-sparkle.sh" "$root/scripts/embed-sparkle.sh"
framework="$root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$framework/Versions/B/XPCServices/Downloader.xpc" "$framework/Versions/B/XPCServices/Installer.xpc" "$framework/Versions/B/Updater.app"
printf 'Sparkle license fixture\n' > "$root/.build/artifacts/sparkle/Sparkle/LICENSE"
printf 'framework binary' > "$framework/Versions/B/Sparkle"
printf 'installer binary' > "$framework/Versions/B/Autoupdate"
ln -s B "$framework/Versions/Current"
ln -s Versions/Current/Sparkle "$framework/Sparkle"
printf '2.3.4\n' > "$root/VERSION"
export BEND_BUILD_NUMBER=42
mkdir -p "$root/Assets"
printf "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n" > "$root/Assets/SparklePublicKey.txt"
cp "$(dirname "$0")/../Assets/AppIcon.icns" "$root/Assets/AppIcon.icns"
export BROWSE_BUILD_TEST_ROOT="$root"
export PATH="$root/bin:$PATH"
cat > "$root/bin/swift" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$BROWSE_BUILD_TEST_ROOT/swift-arguments"
if [[ "$*" == *--show-bin-path* ]]; then printf '%s/bin\n' "$BROWSE_BUILD_TEST_ROOT"; fi
SH
cat > "$root/bin/codesign" <<'SH'
#!/bin/bash
if [[ "${BROWSE_BUILD_TEST_FAIL:-}" == "$1" ]]; then exit 1; fi
if [[ "$1" == "--force" ]]; then
  [[ "$*" == *"--options runtime"* ]] || exit 2
  printf '%s\n' "$@" > "$BROWSE_BUILD_TEST_ROOT/signing-arguments"
fi
SH
cat > "$root/bin/otool" <<'SH'
#!/bin/bash
printf '          cmd LC_RPATH\n         path %s/.build/frameworks (offset 12)\n' "$BROWSE_BUILD_TEST_ROOT"
SH
cat > "$root/bin/install_name_tool" <<'SH'
#!/bin/bash
[[ "$1" == -delete_rpath && "$2" == "$BROWSE_BUILD_TEST_ROOT/.build/frameworks" ]]
printf 'removed build search path\n' >> "$BROWSE_BUILD_TEST_ROOT/rpath-removal"
SH
chmod +x "$root/bin/swift" "$root/bin/codesign" "$root/bin/otool" "$root/bin/install_name_tool"
printf 'previous executable\n' > "$root/dist/Bend Debug.app/Contents/MacOS/Bend"
printf 'new executable\n' > "$root/bin/Bend"
original_inode="$(stat -f %i "$root/dist/Bend Debug.app/Contents/MacOS/Bend")"
# An open descriptor models a running process retaining the old executable.
exec 9< "$root/dist/Bend Debug.app/Contents/MacOS/Bend"
for failure in --force --verify; do
  if BROWSE_BUILD_TEST_FAIL="$failure" bash "$root/scripts/build-app.sh"; then
    printf 'Expected signing/verification failure\n' >&2
    exit 1
  fi
  [[ "$(stat -f %i "$root/dist/Bend Debug.app/Contents/MacOS/Bend")" == "$original_inode" ]]
  [[ "$(cat "$root/dist/Bend Debug.app/Contents/MacOS/Bend")" == 'previous executable' ]]
done
bash "$root/scripts/build-app.sh"
[[ "$(cat "$root/dist/Bend Debug.app/Contents/MacOS/Bend")" == 'new executable' ]]
[[ "$(stat -f %i "$root/dist/Bend Debug.app/Contents/MacOS/Bend")" != "$original_inode" ]]
[[ "$(cat <&9)" == 'previous executable' ]]
exec 9<&-
plist="$root/dist/Bend Debug.app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == 2.3.4 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == 42 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == 26.0 ]]
grep -q -- '-platform_version -Xlinker macos -Xlinker 26.0' "$root/swift-arguments"
for key in CFBundleName CFBundleDisplayName; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")" == "Bend Debug" ]]
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == dev.yury.browse.debug ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" == AppIcon ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleTypeRole' "$plist")" == Viewer ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$plist")" == http ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:1' "$plist")" == https ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes:0' "$plist")" == public.html ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:1:LSItemContentTypes:0' "$plist")" == public.xhtml ]]
for index in 0 1; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:$index:CFBundleTypeRole" "$plist")" == Viewer ]]
  [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:$index:LSHandlerRank" "$plist")" == Alternate ]]
done
cmp "$root/Assets/AppIcon.icns" "$root/dist/Bend Debug.app/Contents/Resources/AppIcon.icns"
BEND_SIGNING_IDENTITY='Bend test signer' BROWSE_SIGNING_IDENTITY='Legacy test signer' bash "$root/scripts/build-app.sh"
[[ "$(sed -n '5p' "$root/signing-arguments")" == 'Bend test signer' ]]
env -u BEND_SIGNING_IDENTITY BROWSE_SIGNING_IDENTITY='Legacy test signer' bash "$root/scripts/build-app.sh"
[[ "$(sed -n '5p' "$root/signing-arguments")" == 'Legacy test signer' ]]
[[ -z "$(find "$root/dist" -maxdepth 1 -name '.build-app.*' -print)" ]]
printf 'Build publication tests passed\n'

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" == Bend ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BendBuildProfile' "$plist")" == debug ]]
grep -q -- '-c debug --disable-sandbox -Xswiftc -DBEND_DEBUG' "$root/swift-arguments"
debug_inode="$(stat -f %i "$root/dist/Bend Debug.app/Contents/MacOS/Bend")"
bash "$root/scripts/build-app.sh" --production --output "$root/release/Bend.app"
[[ "$(stat -f %i "$root/dist/Bend Debug.app/Contents/MacOS/Bend")" == "$debug_inode" ]]
plist="$root/release/Bend.app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == 2.3.4 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == 42 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == 26.0 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist")" == Bend ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == dev.yury.browse.prototype ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BendBuildProfile' "$plist")" == production ]]
grep -q -- '-c release --disable-sandbox -Xswiftc -DBEND_PRODUCTION' "$root/swift-arguments"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")" == https://github.com/1st1/bend/releases/latest/download/appcast.xml ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$plist")" == true ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$plist")" == true ]]
[[ -f "$root/release/Bend.app/Contents/Resources/Sparkle-LICENSE" ]]
[[ -L "$root/release/Bend.app/Contents/Frameworks/Sparkle.framework/Versions/Current" ]]
[[ -f "$root/release/Bend.app/Contents/Frameworks/Sparkle.framework/Sparkle" ]]
if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$root/dist/Bend Debug.app/Contents/Info.plist" >/dev/null 2>&1; then exit 1; fi
printf 'Debug/production build isolation tests passed\n'
production_inode="$(stat -f %i "$root/release/Bend.app/Contents/MacOS/Bend")"
for invalid in 1.2 01.2.3 1.2.3-beta '<invalid>'; do
  printf '%s\n' "$invalid" > "$root/VERSION"
  if bash "$root/scripts/build-app.sh" --production --output "$root/release/Bend.app"; then
    printf 'Expected invalid VERSION rejection\n' >&2; exit 1
  fi
done
printf '2.3.4\n' > "$root/VERSION"
if BEND_BUILD_NUMBER=0 bash "$root/scripts/build-app.sh" --production --output "$root/release/Bend.app"; then
  printf 'Expected invalid build number rejection\n' >&2; exit 1
fi
[[ "$(stat -f %i "$root/release/Bend.app/Contents/MacOS/Bend")" == "$production_inode" ]]
printf 'Version metadata tests passed\n'
