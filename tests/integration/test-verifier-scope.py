#!/usr/bin/env python3
"""Regression: a selected bundle must not borrow another build's rootfs tree.

An earlier review found that verify-bundle.sh --bundle X fell back to the newest
out/image-build tree when X had no tree of its own (e.g. custom --work), which
would attribute dev-v3's rootfs checks to a different bundle.  A bundle without
its own assembled tree must SKIP rootfs checks instead.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class BundleRootfsScope(unittest.TestCase):
    def test_missing_own_tree_skips_instead_of_borrowing(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp) / "repo"
            unrelated = repo / "out/image-build/unrelated-bundle/rootfs/root"
            unrelated.mkdir(parents=True)
            bundle = Path(temp) / "bundle-scope-fixture"
            bundle.mkdir()
            (bundle / "bundle.json").write_text(json.dumps({
                "format": "liuqin-fedora-bundle/v1",
                "name": "bundle-scope-fixture",
                "files": {},
            }))
            report = Path(temp) / "report.json"
            subprocess.run(
                [str(PROJECT / "scripts/verify-bundle.sh"), "--repo-root", str(repo),
                 "--bundle", str(bundle),
                 "--json", str(report), "--no-color", "--quiet"],
                capture_output=True, text=True, timeout=300, check=False)
            data = json.loads(report.read_text())
            auto = [c for c in data["checks"] if c["id"] == "rootfs.auto"]
            self.assertTrue(auto, "rootfs.auto check must exist")
            self.assertEqual(auto[0]["status"], "SKIP")
            detail = auto[0].get("detail", "")
            self.assertIn("no assembled rootfs tree associated with bundle", detail)
            self.assertIn("bundle-scope-fixture", detail)
            borrowed = [c for c in data["checks"]
                        if c["id"].startswith("rootfs.") and c["status"] == "PASS"]
            self.assertEqual(borrowed, [], "no rootfs PASS may come from another build")

    def test_own_bundle_tree_is_used_when_present(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp) / "repo"
            bundle = repo / "images/bundle-scope-fixture"
            bundle.mkdir(parents=True)
            (bundle / "bundle.json").write_text(json.dumps({
                "format": "liuqin-fedora-bundle/v1",
                "name": "bundle-scope-fixture",
                "files": {},
            }))
            (repo / "out/image-build/bundle-scope-fixture/rootfs/root").mkdir(parents=True)
            report = Path(temp) / "report.json"
            subprocess.run(
                [str(PROJECT / "scripts/verify-bundle.sh"), "--repo-root", str(repo),
                 "--bundle", str(bundle),
                 "--json", str(report), "--no-color", "--quiet"],
                capture_output=True, text=True, timeout=300, check=False)
            data = json.loads(report.read_text())
            rootfs = {c["id"]: c["status"] for c in data["checks"]
                      if c["id"].startswith("rootfs.")}
            self.assertEqual(rootfs.get("rootfs.exists"), "PASS",
                             "the bundle's own out/image-build tree must still be found")


if __name__ == "__main__":
    unittest.main()
