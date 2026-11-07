#!/usr/bin/env python3
"""Collect an isolated, completed build; never deploy or create a boot image."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

here = Path(__file__).resolve().parent
work, out = (Path(p).resolve() for p in sys.argv[1:])
build = work / "build"
release = (build / "include/config/kernel.release").read_text().strip()
if release != "7.3.1-liuqin-exp1":
    raise SystemExit(f"Unexpected release: {release}")


def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


dist = out / "dist"
dist.mkdir(parents=True, exist_ok=True)
files = {
    "Image": "arch/arm64/boot/Image",
    "sm8475-xiaomi-liuqin.dtb": "arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb",
    "config": ".config",
    "vmlinux": "vmlinux",
    "System.map": "System.map",
    "Module.symvers": "Module.symvers",
}
for target, source in files.items():
    shutil.copy2(build / source, dist / target)
module_root = work / "modules"
modules = module_root / "lib/modules" / release
shutil.copytree(module_root, dist / "modules", symlinks=True, dirs_exist_ok=True)
with tarfile.open(dist / "modules.tar.gz", "w:gz") as archive:
    archive.add(module_root, arcname="modules")
manifest = []
for path in sorted(modules.rglob("*")):
    if path.is_file() and not path.is_symlink():
        manifest.append(f"{sha(path)}  {path.relative_to(module_root)}\n")
(dist / "modules.sha256").write_text("".join(manifest))
notes = subprocess.check_output(["aarch64-linux-gnu-readelf", "-n", str(build / "vmlinux")], text=True)
build_id = re.search(r"Build ID: ([0-9a-f]+)", notes).group(1)
shutil.copytree(work / "logs", out / "logs", dirs_exist_ok=True)
spec = json.loads((here / "source.json").read_text())
patches = []
for name in (here / "patches/series").read_text().splitlines():
    if name and not name.startswith("#"):
        patches.append({"path": name, "sha256": sha(here / "patches" / name)})
info = {
    "status": "verified-offline", "hardware_verified": False,
    "kernel_release": release, "gnu_build_id": build_id,
    "source": spec, "patches": patches,
    "config_sha256": sha(dist / "config"),
    "seed_config_sha256": sha(here / "seed.config"),
    "experiment_fragment_sha256": sha(here / "experiment.config"),
    "compiler": subprocess.check_output(["aarch64-linux-gnu-gcc", "--version"], text=True).splitlines()[0],
    "module_count": len(list(modules.rglob("*.ko"))),
    "pon_source_sha256": sha(here / "modules/pon/afk_pon_snapshot.c"),
    "work_root": str(work),
    "device_actions": [],
}
(out / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
checksums = []
for path in sorted(dist.iterdir()):
    if path.is_file():
        checksums.append(f"{sha(path)}  {path.relative_to(out)}\n")
checksums.append(f"{sha(out / 'build-info.json')}  build-info.json\n")
(out / "SHA256SUMS").write_text("".join(checksums))
print(f"{release}, GNU Build ID {build_id}, {info['module_count']} modules")
