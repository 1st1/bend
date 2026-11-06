#!/bin/bash
set -euo pipefail
# Exercise the actual packaging script with isolated compiler/signing stand-ins.
root="$(mktemp -d "${TMPDIR:-/tmp}/browse-build-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/scripts" "$root/bin" "$root/dist/Bend.app/Contents/MacOS"
cp "$(dirname "$0")/build-app.sh" "$root/scripts/build-app.sh"
mkdir -p "$root/Assets"
cp "$(dirname "$0")/../Assets/AppIcon.icns" "$root/Assets/AppIcon.icns"
export BROWSE_BUILD_TEST_ROOT="$root"
export PATH="$root/bin:$PATH"
cat > "$root/bin/swift" <<'SH'
#!/bin/bash
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
chmod +x "$root/bin/swift" "$root/bin/codesign"
printf 'previous executable\n' > "$root/dist/Bend.app/Contents/MacOS/Bend"
printf 'new executable\n' > "$root/bin/Bend"
original_inode="$(stat -f %i "$root/dist/Bend.app/Contents/MacOS/Bend")"
# An open descriptor models a running process retaining the old executable.
exec 9< "$root/dist/Bend.app/Contents/MacOS/Bend"
for failure in --force --verify; do
  if BROWSE_BUILD_TEST_FAIL="$failure" bash "$root/scripts/build-app.sh"; then
    printf 'Expected signing/verification failure\n' >&2
    exit 1
  fi
  [[ "$(stat -f %i "$root/dist/Bend.app/Contents/MacOS/Bend")" == "$original_inode" ]]
  [[ "$(cat "$root/dist/Bend.app/Contents/MacOS/Bend")" == 'previous executable' ]]
done
bash "$root/scripts/build-app.sh"
[[ "$(cat "$root/dist/Bend.app/Contents/MacOS/Bend")" == 'new executable' ]]
[[ "$(stat -f %i "$root/dist/Bend.app/Contents/MacOS/Bend")" != "$original_inode" ]]
[[ "$(cat <&9)" == 'previous executable' ]]
exec 9<&-
plist="$root/dist/Bend.app/Contents/Info.plist"
for key in CFBundleName CFBundleDisplayName CFBundleExecutable; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")" == Bend ]]
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == dev.yury.browse.prototype ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" == AppIcon ]]
cmp "$root/Assets/AppIcon.icns" "$root/dist/Bend.app/Contents/Resources/AppIcon.icns"
BEND_SIGNING_IDENTITY='Bend test signer' BROWSE_SIGNING_IDENTITY='Legacy test signer' bash "$root/scripts/build-app.sh"
[[ "$(sed -n '5p' "$root/signing-arguments")" == 'Bend test signer' ]]
env -u BEND_SIGNING_IDENTITY BROWSE_SIGNING_IDENTITY='Legacy test signer' bash "$root/scripts/build-app.sh"
[[ "$(sed -n '5p' "$root/signing-arguments")" == 'Legacy test signer' ]]
[[ -z "$(find "$root/dist" -maxdepth 1 -name '.build-app.*' -print)" ]]
printf 'Build publication tests passed\n'
