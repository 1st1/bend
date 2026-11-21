#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=0.65.1
if command -v swiftlint >/dev/null && [[ "$(swiftlint version)" == "$version" ]]; then
  lint=swiftlint
else
  lint="$PWD/.build/tools/swiftlint-$version/swiftlint"
  if [[ ! -x "$lint" ]]; then
    mkdir -p "$(dirname "$lint")"
    work="$(mktemp -d "$PWD/.build/tools/.swiftlint.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    curl -fsSL --retry 3 "https://github.com/realm/SwiftLint/releases/download/$version/portable_swiftlint.zip" -o "$work/tool.zip"
    (cd "$work" && echo 'c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0  tool.zip' | shasum -a 256 -c -)
    unzip -q "$work/tool.zip" swiftlint -d "$work"
    mv "$work/swiftlint" "$lint"
  fi
fi
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == */CommandLineTools ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
exec "$lint" lint --strict --no-cache --quiet
