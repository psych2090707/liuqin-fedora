#!/usr/bin/env python3
"""Regression: scripts/assemble-firmware-pool.sh reproduces the reviewed pool.

An earlier task assembled the pool with a local script and verified on hardware that
the resulting initramfs stages every firmware category.  That work promoted the
step into the build path, so the pool digest now has to stay stable: a change in
the layout or in the copied files must fail here instead of silently changing
what the release builds ship.

The upstream clone is a build input (scripts/fetch-upstream.sh), not part of the
repository, so the test SKIPs when it is absent.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT / "scripts/assemble-firmware-pool.sh"
UPSTREAM = PROJECT / "upstream/xiaomipad-6pro-mainline/device/firmware"
MANIFEST = UPSTREAM / "firmware.manifest"

# sha256 of the pool.manifest produced from the locked upstream tree; changing
# the layout or the pinned upstream firmware must update this value on purpose.
POOL_MANIFEST_SHA = "d6477af060a8211b620b8ae44e856462f3d29215798bdab2f8da641d4355e550"
POOL_FILES = 195


def run(*args):
    return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True)


@unittest.skipUnless(UPSTREAM.is_dir() and MANIFEST.is_file(),
                     "upstream firmware clone absent (scripts/fetch-upstream.sh)")
class AssembleFirmwarePool(unittest.TestCase):
    def test_verify_only_checks_the_upstream_manifest(self):
        r = run("--verify-only")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("verified against", r.stdout)

    def test_pool_matches_the_reviewed_layout_and_is_deterministic(self):
        with tempfile.TemporaryDirectory() as temp:
            first = Path(temp) / "a"
            second = Path(temp) / "b"
            for out in (first, second):
                r = run("--out", str(out), "--quiet")
                self.assertEqual(r.returncode, 0, r.stderr)
            pool = first / "pool"
            files = [p for p in pool.rglob("*") if p.is_file()]
            self.assertEqual(len(files), POOL_FILES)
            manifest = (first / "pool.manifest").read_text()
            self.assertEqual(len(manifest.splitlines()), POOL_FILES)
            self.assertEqual(
                __import__("hashlib").sha256(manifest.encode()).hexdigest(),
                POOL_MANIFEST_SHA,
                "firmware pool layout changed: update POOL_MANIFEST_SHA together "
                "with the upstream pin if this is intended")
            self.assertEqual(
                (first / "pool.manifest").read_bytes(),
                (second / "pool.manifest").read_bytes())
            record = json.loads((first / "pool.json").read_text())
            self.assertEqual(record["files"], POOL_FILES)
            self.assertEqual(record["layout"], "liuqin-firmware-pool/v1")
            self.assertEqual(
                record["upstream_manifest_sha256"],
                __import__("hashlib").sha256(MANIFEST.read_bytes()).hexdigest())
            self.assertIsNone(record["audio_topology"])

    def test_rejects_an_unpinned_topology(self):
        with tempfile.TemporaryDirectory() as temp:
            bogus = Path(temp) / "tplg.bin"
            bogus.write_bytes(b"not a topology")
            r = run("--out", str(Path(temp) / "out"), "--topology", str(bogus))
            self.assertEqual(r.returncode, 2)
            self.assertIn("accepted baseline", r.stderr)

    def test_accepts_the_project_topology_baseline(self):
        # Keep build inputs independent of disposable install-simulation trees.
        canonical = PROJECT / "out/audio-topology/Xiaomi-Pad-6-Pro-tplg.bin"
        candidates = [canonical] if canonical.is_file() else sorted(PROJECT.glob(
            "out/install-sim/*/staging/usr/lib/firmware/qcom/sm8450/"
            "Xiaomi-Pad-6-Pro-tplg.bin"))
        if not candidates:
            self.skipTest("project topology artifact not present in out/")
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "out"
            r = run("--out", str(out), "--topology", str(candidates[-1]), "--quiet")
            self.assertEqual(r.returncode, 0, r.stderr)
            record = json.loads((out / "pool.json").read_text())
            self.assertEqual(record["audio_topology"]["baseline"], "project")
            self.assertTrue(
                (out / "audio-topology/Xiaomi-Pad-6-Pro-tplg.bin").is_file())


class InstallerFirmwareArguments(unittest.TestCase):
    """Run the real installer stage with captured builder calls, without sudo."""

    def test_installer_forwards_firmware_paths_with_spaces(self):
        script = (PROJECT / 'scripts/build-image.sh').read_text()
        stage = script[script.index('stage_installer_img() {'):]
        stage = stage[:stage.index('\n# ---')]
        with tempfile.TemporaryDirectory(prefix='installer firmware ') as temp:
            root = Path(temp)
            (root / 'scripts').mkdir()
            (root / 'scripts/build-initramfs.sh').write_text(
                '#!/usr/bin/env python3\n'
                'import json, pathlib, sys\n'
                "pathlib.Path('args.json').write_text(json.dumps(sys.argv[1:]))\n"
                "out = pathlib.Path(sys.argv[sys.argv.index('--out')+1]) / 'initramfs'\n"
                'out.mkdir(parents=True)\n'
                "(out / 'liuqin-installer.cpio.gz').touch()\n")
            (root / 'scripts/build-bootimg.sh').write_text('#!/bin/sh\nexit 0\n')
            for builder in (root / 'scripts').iterdir():
                builder.chmod(0o755)
            env = dict(os.environ, work=str(root / 'work'), project_root=str(root),
                       have_installer='1', kernel_out=str(root / 'kernel output'),
                       installer_overlay=str(root / 'overlay tree'),
                       contract_file=str(root / 'contract file'),
                       privileges_file=str(root / 'privileges file'),
                       dtb_source='upstream-artifact', kernel_source='test kernel',
                       firmware_pool=str(root / 'firmware pool'),
                       wlan_hsp2_tuple=str(root / 'HSP2 tuple'),
                       audio_topology=str(root / 'audio topology.bin'))
            helpers = ('stage_header() { :; }; say() { :; }; '
                       'resolve_kernel_payload() { :; }; ensure_contract() { :; }; '
                       'ensure_privileges() { :; }; add_skip() { :; }; '
                       'die() { echo "$*" >&2; exit 1; };\n')
            for with_pool in (True, False):
                with self.subTest(with_pool=with_pool):
                    env['firmware_pool'] = str(root / 'firmware pool') if with_pool else ''
                    result = subprocess.run(['sh', '-eu', '-c', helpers + stage +
                                             '\nstage_installer_img\n'],
                                            cwd=root, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = json.loads((root / 'args.json').read_text())
                    if with_pool:
                        for option, key in (('--firmware-pool', 'firmware_pool'),
                                            ('--wlan-hsp2-tuple', 'wlan_hsp2_tuple'),
                                            ('--audio-topology', 'audio_topology')):
                            self.assertEqual(args[args.index(option)+1], env[key])
                        self.assertNotIn('--allow-missing-firmware', args)
                    else:
                        self.assertIn('--allow-missing-firmware', args)
                        self.assertNotIn('--firmware-pool', args)


if __name__ == "__main__":
    unittest.main()
