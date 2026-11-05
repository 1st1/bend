#!/bin/bash
set -euo pipefail
# Exercise the actual packaging script with isolated compiler/signing stand-ins.
root="$(mktemp -d "${TMPDIR:-/tmp}/browse-build-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/scripts" "$root/bin" "$root/dist/Browse.app/Contents/MacOS"
cp "$(dirname "$0")/build-app.sh" "$root/scripts/build-app.sh"
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
fi
SH
chmod +x "$root/bin/swift" "$root/bin/codesign"
printf 'previous executable\n' > "$root/dist/Browse.app/Contents/MacOS/Browse"
printf 'new executable\n' > "$root/bin/Browse"
original_inode="$(stat -f %i "$root/dist/Browse.app/Contents/MacOS/Browse")"
# An open descriptor models a running process retaining the old executable.
exec 9< "$root/dist/Browse.app/Contents/MacOS/Browse"
for failure in --force --verify; do
  if BROWSE_BUILD_TEST_FAIL="$failure" bash "$root/scripts/build-app.sh"; then
    printf 'Expected signing/verification failure\n' >&2
    exit 1
  fi
  [[ "$(stat -f %i "$root/dist/Browse.app/Contents/MacOS/Browse")" == "$original_inode" ]]
  [[ "$(cat "$root/dist/Browse.app/Contents/MacOS/Browse")" == 'previous executable' ]]
done
bash "$root/scripts/build-app.sh"
[[ "$(cat "$root/dist/Browse.app/Contents/MacOS/Browse")" == 'new executable' ]]
[[ "$(stat -f %i "$root/dist/Browse.app/Contents/MacOS/Browse")" != "$original_inode" ]]
[[ "$(cat <&9)" == 'previous executable' ]]
exec 9<&-
[[ -z "$(find "$root/dist" -maxdepth 1 -name '.build-app.*' -print)" ]]
printf 'Build publication tests passed\n'
