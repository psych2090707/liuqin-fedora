#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(cd -- "$HERE/../../.." && pwd)
export LIUQIN_731_PROFILE=$HERE
export LIUQIN_731_ADDON=${LIUQIN_731_ADDON-$HERE/ubuntu-v080}
export LIUQIN_731_WORK=${LIUQIN_731_WORK:-/tmp/liuqin-linux-7.3.5}
export LIUQIN_731_OUT=${LIUQIN_731_OUT:-$PROJECT/out/kernel-stable-upgrade/kernel}
export LIUQIN_731_ARCHIVE=${LIUQIN_731_ARCHIVE:-$PROJECT/out/kernel-stable-upgrade/downloads/linux-7.3.5.tar.xz}
exec bash "$HERE/../linux-7.3.1/build.sh" "$@"
