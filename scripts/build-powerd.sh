#!/bin/sh
# SPDX-License-Identifier: MIT
# Build the aarch64 liuqin-powerd binary with the pinned official Rust
# toolchain.  The host's Arch rust package is intentionally left alone; the
# official 1.99.1 toolchain lives in /opt/rust-1.99.1 (see rust/README.md).
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cargo_bin=${LIUQIN_CARGO:-/opt/rust-1.99.1/bin/cargo}
rustc_bin=${LIUQIN_RUSTC:-/opt/rust-1.99.1/bin/rustc}

if [ ! -x "$cargo_bin" ] || [ ! -x "$rustc_bin" ]; then
	echo "missing official Rust 1.99.1 at /opt/rust-1.99.1" >&2
	echo "install it as described in rust/README.md, or set LIUQIN_CARGO/LIUQIN_RUSTC" >&2
	exit 1
fi

PATH=$(dirname -- "$cargo_bin"):$PATH
export PATH

cd "$project_root/rust"
"$cargo_bin" fmt --check
"$cargo_bin" test -p liuqin-power-core
"$cargo_bin" build --release --target aarch64-unknown-linux-gnu -p liuqin-powerd

binary="$project_root/rust/target/aarch64-unknown-linux-gnu/release/liuqin-powerd"
[ -x "$binary" ] || {
	echo "build did not produce $binary" >&2
	exit 1
}
printf 'built %s\n' "$binary"
