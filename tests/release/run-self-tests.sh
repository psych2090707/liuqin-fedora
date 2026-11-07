#!/bin/sh
# SPDX-License-Identifier: MIT
# Self-tests for the release tooling (synthetic fixtures only).
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$project_root"
status=0
run() { name=$1; shift; printf "\n=== %s ===\n" "$name"; "$@" || status=1; }
run "bundle acceptance runner" python3 tests/release/test-accept-bundle.py
run "release assets packaging" sh tests/release/test-release-assets.sh
if [ "$status" = 0 ]; then printf "\nRELEASE TOOLING SELF-TESTS PASSED\n"; else printf "\nRELEASE TOOLING SELF-TESTS FAILED\n" >&2; exit 1; fi
