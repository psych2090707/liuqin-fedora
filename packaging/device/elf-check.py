#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline ELF identity checks for the liuqin helper binaries.

The RPM build hosts are x86_64 and the packaged helpers are aarch64, so the
usual build-id/strip/debuginfo post-processing is disabled in the specs and
the architecture is asserted here instead (no target binutils required).
"""
import struct
import sys

EM_AARCH64 = 0xB7
PT_DYNAMIC = 2
PT_INTERP = 3


def check(path: str, want_static: bool) -> None:
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF":
        raise SystemExit(f"{path}: not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise SystemExit(f"{path}: not ELF64 little-endian")
    e_type, e_machine = struct.unpack_from("<HH", data, 16)
    if e_machine != EM_AARCH64:
        raise SystemExit(f"{path}: machine {e_machine:#x} is not aarch64 ({EM_AARCH64:#x})")
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
    has_interp = has_dynamic = False
    for index in range(e_phnum):
        p_type = struct.unpack_from("<I", data, e_phoff + index * e_phentsize)[0]
        has_interp |= p_type == PT_INTERP
        has_dynamic |= p_type == PT_DYNAMIC
    if has_interp:
        raise SystemExit(f"{path}: has PT_INTERP (dynamically linked)")
    if want_static and has_dynamic:
        raise SystemExit(f"{path}: has PT_DYNAMIC (expected a fully static binary)")
    print(f"OK {path}: aarch64 ELF64 e_type={e_type} static={not has_dynamic} bytes={len(data)}")


def main(argv: list[str]) -> int:
    want_static = False
    paths = []
    for arg in argv:
        if arg == "--static":
            want_static = True
        else:
            paths.append(arg)
    if not paths:
        raise SystemExit("usage: elf-check.py [--static] FILE...")
    for path in paths:
        check(path, want_static)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
