#!/bin/bash
# Sourced by the app builder before compilation or touching an existing bundle.
version="$(cat VERSION)"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'VERSION must contain a numeric MAJOR.MINOR.PATCH version\n' >&2
  exit 1
fi
# Local builds use 1; release CI supplies a monotonically increasing integer.
build_number="${BEND_BUILD_NUMBER:-1}"
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  printf 'BEND_BUILD_NUMBER must be a positive integer\n' >&2
  exit 1
fi
