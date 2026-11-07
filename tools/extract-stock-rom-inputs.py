#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Extract the liuqin boot.img stock-ROM inputs from a user-supplied ROM.

The Fedora liuqin boot.img canonical DTB path needs inputs that exist only in
the user's own Xiaomi Pad 6 Pro Fastboot ROM:

  * 44 DTBO overlay entries from ``images/dtbo.img`` (Android DT table format),
  * 14 base DTBs from the dtb section of ``images/vendor_boot.img``,
  * optionally ``images/boot.img`` -- recorded and identity-checked only.

Output layout matches the boot builder (``scripts/build-bootimg.sh``):

    <out>/analysis/dtbo/entry.NN            (44 entries, raw DTBO payloads)
    <out>/analysis/vendor_boot/dtbs/dtb-NN.dtb   (14 base DTBs)
    <out>/analysis/vendor_boot/dtb-02.dtb   (convenience copy, --no-dtb-02)
    <out>/dtbo/entry.NN                     (flat layout for /usr/share/liuqin/stock)
    <out>/vendor_boot/dtbs/dtb-NN.dtb
    <out>/manifest.json

The tool only reads the ROM you provide; it never downloads a ROM and never
writes outside the output directory.  Exit codes: 0 success, 2 usage,
3 unusable/malformed ROM, 4 fail-closed entry count, 5 manifest mismatch.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
PROJECT = TOOL_DIR.parent
LIB_PATH = TOOL_DIR / "lib/stock-rom.py"

_spec = importlib.util.spec_from_file_location("liuqin_stock_rom", LIB_PATH)
if _spec is None or _spec.loader is None:  # pragma: no cover - installation bug
    raise SystemExit(f"panic: cannot load {LIB_PATH}")
stock_rom = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = stock_rom  # dataclasses/Python 3.13+ need the module registered
_spec.loader.exec_module(stock_rom)

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_INPUT = 3
EXIT_COUNT = 4
EXIT_MANIFEST = 5


def log(message: str) -> None:
    print(f"extract-stock-rom-inputs: {message}", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Extract liuqin boot.img stock-ROM inputs (44 DTBO entries + 14 base DTBs).",
        epilog=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--rom", type=Path, metavar="PATH",
                      help="extracted Fastboot ROM directory or ROM archive (.tgz/.tar.gz/.zip)")
    mode.add_argument("--verify-manifest", nargs="?", const="auto", metavar="MANIFEST",
                      help="verify a previous extraction manifest (default: <out>/manifest.json)")
    mode.add_argument("--inspect", type=Path, metavar="IMAGE",
                      help="parse one dtbo.img/vendor_boot.img/boot.img and print its structure (no writes)")
    parser.add_argument("--out", type=Path, metavar="DIR",
                        help="output directory (default: <project>/out/stock-rom)")
    parser.add_argument("--layout", choices=list(stock_rom.LAYOUTS), default="both",
                        help="output layout (default: both)")
    parser.add_argument("--expected-dtbo", type=stock_rom.parse_size,
                        default=stock_rom.DEFAULT_EXPECTED_DTBO_ENTRIES,
                        help="fail-closed DTBO entry count (default: 44)")
    parser.add_argument("--expected-dtb", type=stock_rom.parse_size,
                        default=stock_rom.DEFAULT_EXPECTED_VENDOR_DTBS,
                        help="fail-closed vendor_boot base DTB count (default: 14)")
    parser.add_argument("--rom-images-json", type=Path, metavar="PATH",
                        help="override the pinned stock-ROM identity table")
    parser.add_argument("--no-dtb-02", action="store_true",
                        help="do not write the convenience analysis/vendor_boot/dtb-02.dtb copy")
    parser.add_argument("--strict-known", action="store_true",
                        help="refuse a ROM whose dtbo.img/vendor_boot.img do not match the pinned table")
    parser.add_argument("--dry-run", action="store_true",
                        help="parse and validate only; write nothing")
    parser.add_argument("--force", action="store_true",
                        help="overwrite a non-empty output directory")
    parser.add_argument("--allow-outside", action="store_true",
                        help="allow --out outside the project out/cache or /tmp (explicit user action)")
    parser.add_argument("--json", action="store_true",
                        help="print a JSON summary to stdout")
    return parser


def _default_out() -> Path:
    return PROJECT / "out/stock-rom"


def _check_out_dir(out_dir: Path, allow_outside: bool) -> Path:
    resolved = out_dir.resolve()
    project_out = (PROJECT / "out").resolve()
    project_cache = (PROJECT / "cache").resolve()
    if not allow_outside:
        allowed = resolved.is_relative_to(project_out) or resolved.is_relative_to(project_cache) or \
            resolved.is_relative_to(Path("/tmp")) or resolved.is_relative_to(Path("/var/tmp"))
        if not allowed:
            raise stock_rom.UsageError(
                f"refusing to write outside the project out/cache (or /tmp): {resolved}; "
                f"pass --allow-outside if this is intentional (e.g. /usr/share/liuqin/stock)"
            )
    return resolved


def _print_json(payload: dict) -> None:
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def cmd_inspect(args) -> int:
    path = args.inspect
    if not path.is_file():
        raise stock_rom.InputError(f"image does not exist: {path}")
    data = path.read_bytes()
    name = path.name.lower()
    if name.endswith("dtbo.img") or (data[:4] == b"\x1e\xab\xb7\xd7"):
        table = stock_rom.parse_dt_table(data, source=str(path))
        result = {"file": str(path), "bytes": len(data), "type": "dt_table", "table": table.summary(),
                  "entries": [entry.summary() for entry in table.entries]}
    elif data[:8] == stock_rom.VENDOR_BOOT_MAGIC:
        image = stock_rom.parse_vendor_boot(data, source=str(path))
        table = stock_rom.parse_dtb_container(image.dtb_bytes, source="vendor_boot dtb section")
        result = {"file": str(path), "bytes": len(data), "type": "vendor_boot",
                  "header": image.summary(), "dtb_table": table.summary(),
                  "dtbs": [entry.summary() for entry in table.entries]}
    elif data[:8] == stock_rom.BOOT_MAGIC:
        image = stock_rom.parse_boot_image_v2(data, source=str(path))
        result = {"file": str(path), "bytes": len(data), "type": "boot_v2",
                  "header": image.summary(),
                  "kernel_sha256": stock_rom.sha256_bytes(image.kernel),
                  "ramdisk_sha256": stock_rom.sha256_bytes(image.ramdisk),
                  "dtb_sha256": stock_rom.sha256_bytes(image.dtb),
                  "dtb": stock_rom.fdt_info(image.dtb)}
    else:
        raise stock_rom.FormatError(
            f"{path}: unrecognised image (not a DT table, VNDRBOOT or ANDROID! image)"
        )
    _print_json(result)
    return EXIT_OK


def cmd_verify(args) -> int:
    out_dir = _check_out_dir(args.out or _default_out(), args.allow_outside)
    manifest = args.verify_manifest
    if manifest == "auto":
        manifest = out_dir / "manifest.json"
    else:
        manifest = Path(manifest)
    report = stock_rom.verify_manifest(
        manifest,
        expected_dtbo=args.expected_dtbo,
        expected_dtb=args.expected_dtb,
    )
    if args.json:
        _print_json(report)
    else:
        for check in report["checks"]:
            status = "PASS" if check["ok"] else "FAIL"
            print(f"{status}  {check['id']:<40} {check['detail']}")
        print(f"manifest: {report['manifest']}")
        print(f"counts:   {report['counts']}")
        print(f"known ROM version: {report['known_rom_version']}")
        for warning in report["warnings"]:
            log(f"warning: {warning}")
    if not report["ok"]:
        for problem in report["problems"]:
            log(f"manifest verification failed: {problem}")
        return EXIT_MANIFEST
    log("manifest verified")
    return EXIT_OK


def cmd_extract(args) -> int:
    out_dir = _check_out_dir(args.out or _default_out(), args.allow_outside)
    if not args.rom.exists():
        raise stock_rom.InputError(f"ROM input does not exist: {args.rom}")
    rom_images = stock_rom.RomImages.load(args.rom_images_json) if args.rom_images_json \
        else stock_rom.RomImages.load()
    manifest = stock_rom.extract(
        args.rom,
        out_dir,
        layout=args.layout,
        expected_dtbo=args.expected_dtbo,
        expected_dtb=args.expected_dtb,
        write_dtb02=not args.no_dtb_02,
        rom_images=rom_images,
        allow_unknown_version=not args.strict_known,
        dry_run=args.dry_run,
        force=args.force,
        log=log,
    )
    if args.json:
        _print_json(manifest)
    else:
        rom = manifest["rom"]
        version = rom["version"]
        print(f"ROM input:       {rom['source']['path']} ({rom['source']['type']})")
        for name, entry in rom["files"].items():
            if entry.get("present"):
                print(f"  {name:<16} {entry['bytes']:>12} B  sha256 {entry['sha256'][:16]}…  "
                      f"known={entry['known_version_image']}")
            else:
                print(f"  {name:<16} absent")
        print(f"ROM version:     "
              f"{version['name'] if version['known'] else 'unknown (not in pinned table)'}")
        print(f"dtbo.img:        {manifest['counts']['dtbo_entries']} entries "
              f"(expected {manifest['expected']['dtbo_entries']})")
        print(f"vendor_boot.img: {manifest['counts']['vendor_boot_base_dtbs']} base DTBs "
              f"(expected {manifest['expected']['vendor_boot_base_dtbs']})")
        if not args.dry_run:
            for layout_name, tree in manifest["outputs"]["directories"].items():
                print(f"layout {layout_name}: {tree['dtbo_dir']} + {tree['dtbs_dir']}")
            print(f"manifest:        {manifest['outputs']['manifest']}")
        for warning in manifest["warnings"]:
            log(f"warning: {warning}")
        for note in manifest["notes"]:
            log(f"note: {note}")
        if version["known"] and not args.dry_run:
            log("ROM matches the pinned known version; inputs are canonical for this port")
    return EXIT_OK


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.inspect is not None:
            return cmd_inspect(args)
        if args.verify_manifest is not None:
            if args.out is None and args.verify_manifest != "auto":
                args.out = Path(args.verify_manifest).resolve().parent
            return cmd_verify(args)
        return cmd_extract(args)
    except stock_rom.UsageError as error:
        log(f"usage error: {error}")
        return EXIT_USAGE
    except stock_rom.CountError as error:
        log(f"FAIL-CLOSED: {error}")
        return EXIT_COUNT
    except stock_rom.ManifestError as error:
        log(f"manifest error: {error}")
        return EXIT_MANIFEST
    except (stock_rom.InputError, stock_rom.FormatError) as error:
        log(f"ROM error: {error}")
        return EXIT_INPUT
    except OSError as error:
        log(f"I/O error: {error}")
        return EXIT_INPUT


if __name__ == "__main__":
    raise SystemExit(main())
