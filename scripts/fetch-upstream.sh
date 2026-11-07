#!/usr/bin/env bash
# Recreate/refresh the read-only upstream checkouts used by this project.
# Pins are recorded in this script and in kernel/patches/manifest.json; update together.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UP="$ROOT/upstream"
mkdir -p "$UP"

clone_pinned() { # name url branch commit
    local name=$1 url=$2 branch=$3 commit=$4 dir="$UP/$1"
    if [ -d "$dir/.git" ]; then
        echo "== $name: updating to $branch @ $commit"
        git -C "$dir" fetch --depth 1 origin "$branch" "$commit"
        git -C "$dir" checkout -q --detach "$commit"
    else
        echo "== $name: shallow clone $branch"
        git clone --depth 1 --single-branch --branch "$branch" --no-tags "$url" "$dir"
        git -C "$dir" fetch --depth 1 origin "$commit"
        git -C "$dir" checkout -q --detach "$commit"
    fi
    echo "   -> $(git -C "$dir" rev-parse HEAD)"
}

# Keep in sync with kernel/patches/manifest.json
clone_pinned xiaomipad-6pro-mainline \
    https://github.com/yzddmr6/xiaomipad-6pro-mainline.git main \
    f5a535f5c1c980f042b58cb77467ff8f02a5518e
clone_pinned pipa-fedora-builder-43 \
    https://github.com/rr1111/pipa-fedora-builder-43.git main \
    1c9cbd3983210a2c585311ee86b46ef8cb2c3c32

# Kernel: branch head moves; the product-lock commit is what we build.
KDIR="$UP/linux-sm8450-liuqin"
if [ -d "$KDIR/.git" ]; then
    git -C "$KDIR" fetch --depth 1 origin liuqin-6.17
    git -C "$KDIR" tag -f branch-head FETCH_HEAD >/dev/null
else
    git clone --depth 1 --single-branch --branch liuqin-6.17 --no-tags \
        https://github.com/yzddmr6/linux-sm8450-liuqin.git "$KDIR"
fi
git -C "$KDIR" fetch --depth 1 origin fe81794b5e1b8a3f11a165f3acbfdb8fa671dbb3
git -C "$KDIR" tag -f product-lock fe81794b5e1b8a3f11a165f3acbfdb8fa671dbb3 >/dev/null
git -C "$KDIR" checkout -q --detach product-lock
echo "== linux-sm8450-liuqin: product-lock $(git -C "$KDIR" rev-parse HEAD)"
