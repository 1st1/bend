#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
environment="$PWD/.build/tools/dmgbuild-1.6.7"
requirements="$PWD/scripts/dmgbuild-requirements.txt"
digest="$(shasum -a 256 "$requirements" | cut -d ' ' -f 1)"
if [[ ! -x "$environment/bin/dmgbuild" || "$(cat "$environment/.requirements-sha256" 2>/dev/null || true)" != "$digest" ]]; then
  python3 -m venv "$environment"
  "$environment/bin/python" -m pip install --disable-pip-version-check -r "$requirements"
  printf '%s\n' "$digest" > "$environment/.requirements-sha256"
fi
exec "$environment/bin/dmgbuild" "$@"
