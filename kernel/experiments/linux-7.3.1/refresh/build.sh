#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(cd -- "$HERE/../../../.." && pwd)
export LIUQIN_731_PROFILE=$HERE
export LIUQIN_731_WORK=${LIUQIN_731_WORK:-/tmp/liuqin-upstream-rebuild}
export LIUQIN_731_OUT=${LIUQIN_731_OUT:-$PROJECT/out/upstream-refresh/kernel}
exec bash "$HERE/../build.sh" "$@"
