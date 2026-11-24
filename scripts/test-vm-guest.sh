#!/bin/bash
# Entry point used only inside a disposable worker. SSH login does not
# unlock the desktop keychain used by WebKit to persist its WebCrypto key.
set -euo pipefail
keychain="$(mktemp -d)/test.keychain-db"
password="$(openssl rand -hex 32)"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$password" "$keychain"
security list-keychains -d user -s "$keychain"
security default-keychain -d user -s "$keychain"
exec /bin/bash "$(dirname "$0")/test.sh" "$@"
