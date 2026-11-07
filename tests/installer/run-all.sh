#!/bin/sh
# SPDX-License-Identifier: MIT
# Run the complete offline installer test suite.  No device, no real Fastboot:
# the host flow runs against tests/installer/fake-fastboot on PATH, the layout
# tests against synthetic sparse images, the device-side suite against ext4
# images mounted through fuse2fs, and the tooling tests against temporary
# directories.
set -u

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$project_root" || exit 1
status=0

run() { # NAME COMMAND...
	name=$1
	shift
	printf '\n=== %s ===\n' "$name"
	if "$@"; then
		printf 'PASS suite: %s\n' "$name"
	else
		printf 'FAIL suite: %s\n' "$name"
		status=1
	fi
}

for tool in python3 sh sgdisk; do
	command -v "$tool" >/dev/null 2>&1 || {
		printf 'missing host tool: %s (see docs/build/installer.md)\n' "$tool" >&2
		exit 1
	}
done

run 'partition layout engine' python3 tests/installer/test-layout.py
run 'device-side GPT script' sh tests/installer/test-layout-sh.sh
run 'host installer (upstream suite + Fedora gates)' python3 tests/installer/test-host.py
run 'host installer dry-run flow' python3 tests/installer/test-dry-run.py
run 'installer tooling and simulator' python3 tests/installer/test-tools.py
run 'extra-root overlay injection' python3 tests/installer/test-extra-root.py

# Root, /dev/fuse and fuse2fs are needed for the device-side install test; skip
# it (not fail) where the host cannot provide them, as documented.
if command -v fuse2fs >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 &&
	sudo -n true 2>/dev/null && [ -e /dev/fuse ]; then
	run 'device-side install-root (fuse2fs e2e)' sh tests/installer/test-install-root.sh
else
	printf '\nSKIP suite: device-side install-root (needs root, /dev/fuse and fuse2fs)\n'
fi

if [ "$status" = 0 ]; then
	printf '\nALL INSTALLER TESTS PASSED (offline; no device access)\n'
else
	printf '\nINSTALLER TEST FAILURES (see above)\n' >&2
	exit 1
fi
