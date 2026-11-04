#!/bin/bash
# Pinned real-package reproduction; this does not install into Browse.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != "--diagnostic-startup" ) ]]; then
    echo 'usage: bash scripts/probe-onepassword-firefox.sh official-8.12.41.1.xpi [--diagnostic-startup]' >&2
    exit 2
fi
probe_package="$(mktemp -d "${TMPDIR:-/tmp}/BrowseFirefoxPackage.XXXXXX")"
trap 'rm -rf "$probe_package"' EXIT
# Keep the named baseline and diagnostic modes reproducible.
unset BROWSE_PROBE_SCRIPT BROWSE_PROBE_NOTIFICATIONS BROWSE_PROBE_PAGE
python3 - "$1" "$probe_package" "${2:-}" <<'PY'
import hashlib, pathlib, sys, zipfile
archive = pathlib.Path(sys.argv[1])
expected = '6b00acff73253865303af49e99329245a940348484cbd931ea39f9fa215134f5'
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit('Expected the Mozilla-hosted 1Password 8.12.41.1 package; SHA-256 does not match.')
root = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(archive) as package:
    package.extractall(root)
if sys.argv[3] == '--diagnostic-startup':
    script = root / 'background/background.js'
    source = script.read_text()
    original = 'chrome.webNavigation.onCreatedNavigationTarget.addListener(yyt)'
    if source.count(original) != 1:
        raise SystemExit('Expected exactly one navigation listener registration; refusing to patch.')
    script.write_text(source.replace(original, 'chrome.webNavigation.onCreatedNavigationTarget?.addListener(yyt)'))
    print('DIAGNOSTIC COPY: unsupported navigation listener skipped. Notifications are placeholders.', flush=True)
PY
if [[ "${2:-}" == "--diagnostic-startup" ]]; then
    export BROWSE_PROBE_SCRIPT="$PWD/Tools/ExtensionProbe/startup-notifications.js"
fi
bash scripts/probe-extension-runtime.sh "$probe_package"
