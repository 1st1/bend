#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Pin both the tool and archive digest; never execute an unchecked download.
version=1.26.0
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin_arm64; digest=ba1a14e0eb220fb9c7d4dc90af462e7f7178a313cdb1299a17aafbb37838a458 ;;
  Darwin-x86_64) platform=darwin_amd64; digest=9a1a4dc8a6901ccd9724b3b9b5ec1354e5038b1b1aa4dceef65976f6462ac7d2 ;;
  Linux-x86_64) platform=linux_amd64; digest=eab168c8287a6e91912e1c02e5260911232d945bfd3c89d8a0e1ace6bb7b6161 ;;
  Linux-aarch64) platform=linux_arm64; digest=ec1e542014b5134f1cf86b3a12e86d566ab5ec9bd3901bf66f42a09cd9865b6e ;;
  *) printf 'Unsupported Changie platform\n' >&2; exit 1 ;;
esac
cache="$PWD/.build/tools/changie-$version-$platform"
if [[ ! -x "$cache/changie" ]]; then
  mkdir -p "$PWD/.build/tools"
  work="$(mktemp -d "$PWD/.build/tools/.changie.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/miniscruff/changie/releases/download/v$version/changie_${version}_${platform}.tar.gz" \
    -o "$work/archive.tar.gz"
  actual="$(shasum -a 256 "$work/archive.tar.gz" | cut -d ' ' -f 1)"
  [[ "$actual" == "$digest" ]] || { printf 'Changie checksum mismatch\n' >&2; exit 1; }
  tar -xzf "$work/archive.tar.gz" -C "$work" changie
  mkdir -p "$cache"
  mv "$work/changie" "$cache/changie"
  rm -rf "$work"
  trap - EXIT
fi
exec "$cache/changie" "$@"
