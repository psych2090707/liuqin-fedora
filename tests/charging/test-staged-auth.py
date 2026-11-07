#!/usr/bin/env python3
"""Offline fake-sysfs tests for tasks/charging-power/staged-auth.py.

No device, kernel or root on the host is involved: every scenario builds a
temporary sysfs tree, a stub of the installed liuqin-mipps-auth module and runs
the candidate under `unshare -r` (so the geteuid()==0 guard is satisfied).

Covered branches: full success, missing Xiaomi SVID, rejected host-role write,
invalid adapter ID, HMAC mismatch, held authentication lock and the
one-attempt-per-attach record.  The tests assert both the reported outcome and
the files the script is responsible for cleaning up.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CANDIDATE = HERE.parent.parent / "tasks" / "charging-power" / "staged-auth.py"

STUB = r'''
import hashlib
import hmac
import json
import os

ROOT = os.environ["FAKE_SYSFS"]
TY = os.path.join(ROOT, "typec")
XM = os.path.join(ROOT, "xiaomi")
SCEN = json.loads(os.environ.get("FAKE_SCENARIO", "{}"))
SEEDS = ["%032x" % (0x1000 + i) for i in range(10)]
KEYS = ["%064x" % (0x2000 + i) for i in range(10)]
_current_seed = [None]


def read_node(root, name):
    with open(os.path.join(root, name), "r", encoding="ascii") as handle:
        return handle.read().strip().replace("\x00", "")


def write_node(root, name, value):
    if name == "verify_process" and value.strip() == "1" and SCEN.get("no_latch"):
        return
    if name == "request_vdm_cmd":
        return _vdm(value)
    if name == "data_role":
        return _role(value)
    with open(os.path.join(root, name), "w", encoding="ascii") as handle:
        handle.write(value if value.endswith("\n") else value + "\n")


def write_node_if_present(root, name, value):
    path = os.path.join(root, name)
    if os.path.exists(path):
        write_node(root, name, value)
        return True
    return False


def _role(value):
    if value == "host":
        if SCEN.get("role_timeout"):
            raise OSError(110, "Connection timed out")
        if not SCEN.get("role_ok", True):
            return
        _set("typec", "data_role", "[host] device")
        if SCEN.get("svid", True):
            _set("xiaomi", "adapter_svid", "2717")
            _set("xiaomi", "adapter_id", SCEN.get("adapter_id", "a1b2c3d4"))
    else:
        _set("typec", "data_role", "host [device]")


def _set(tree, name, value):
    with open(os.path.join(ROOT, tree, name), "w", encoding="ascii") as handle:
        handle.write(value + "\n")


def _vdm(value):
    command, _, payload = value.partition(",")
    command = int(command)
    if command == 4:
        _current_seed[0] = payload.strip()
    elif command == 5:
        index = SEEDS.index(_current_seed[0])
        challenge = bytes.fromhex(payload.strip())
        adapter_id = bytes.fromhex(read_node(XM, "adapter_id").strip().lower())
        digest = hmac.new(bytes.fromhex(KEYS[index]), challenge + adapter_id,
                          hashlib.sha256).hexdigest()
        if SCEN.get("hmac_bad"):
            digest = "00" * 32
        _set("xiaomi", "request_vdm_cmd", f"5,{digest}")
        return
    _set("xiaomi", "request_vdm_cmd", f"{command},0")


def find_xiaomi_dir():
    return XM


def find_power_supply(*names):
    for name in names:
        path = os.path.join(ROOT, "ps", name)
        if os.path.exists(path):
            return path
    return None


def find_typec_port():
    return TY


def current_attach_token():
    return SCEN.get("attach", "port0-partner:1:2:3:4")


def verify_fuel_gauge(root, slave, required=True, retries=10):
    print(f"{'slave_authentic' if slave else 'authentic'}_verified=1")
    return True


def write_state_file(path, value):
    return None
'''

BASE_XM = {
    "real_type": "PD",
    "current_state": "SNK_Ready",
    "pdo2": "0002d12c",
    "apdo_max": "33",
    "power_max": "0",
    "authentic": "1",
    "slave_authentic": "1",
    "pd_verifed": "0",
    "verify_process": "0",
    "adapter_svid": "0000",
    "adapter_id": "00000000",
    "fastchg_mode": "0",
    "request_vdm_cmd": "5,00",
}


def build_tree(tmp, scenario):
    root = Path(tmp) / "sys"
    for tree in ("xiaomi", "typec", "ps/qcom-battmgr-usb", "ps/qcom-battmgr-bat"):
        (root / tree).mkdir(parents=True, exist_ok=True)
    for name, value in BASE_XM.items():
        (root / "xiaomi" / name).write_text(value + "\n", encoding="ascii")
    (root / "typec" / "data_role").write_text("host [device]\n", encoding="ascii")
    (root / "typec" / "power_role").write_text("source [sink]\n", encoding="ascii")
    (root / "ps" / "qcom-battmgr-usb" / "online").write_text("1\n", encoding="ascii")
    for name, value in (("voltage_now", "4918000"), ("current_now", "1500000"),
                        ("current_max", "1500000"),
                        ("input_current_limit", "1500000")):
        (root / "ps" / "qcom-battmgr-usb" / name).write_text(value + "\n",
                                                            encoding="ascii")
    (root / "ps" / "qcom-battmgr-bat" / "capacity").write_text("48\n",
                                                              encoding="ascii")
    (root / "ps" / "qcom-battmgr-bat" / "temp").write_text("232\n",
                                                          encoding="ascii")
    stub = Path(tmp) / "stub_mipps.py"
    stub.write_text(STUB, encoding="ascii")
    return root, stub


def run_scenario(name, scenario, expect_exit, expect_ok=True, pre_attach=None,
                 hold_lock=False, extra_args=None):
    tmp = tempfile.mkdtemp(prefix=f"staged-auth-{name}-")
    try:
        root, stub = build_tree(tmp, scenario)
        lock = Path(tmp) / "auth.lock"
        attach = Path(tmp) / "last-attach"
        if pre_attach:
            attach.write_text(pre_attach + "\n", encoding="ascii")
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "FAKE_SYSFS": str(root),
            "FAKE_SCENARIO": json.dumps(scenario),
            "LIUQIN_MIPPS_AUTH": str(stub),
            "LIUQIN_MIPPS_AUTH_LOCK": str(lock),
            "LIUQIN_MIPPS_AUTH_ATTACH": str(attach),
        }
        holder = None
        if hold_lock:
            import fcntl
            holder = open(lock, "w")
            fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            proc = subprocess.run(
                ["unshare", "-r", sys.executable, str(CANDIDATE),
                 "--observe", "0"] + (extra_args or []),
                env=env, capture_output=True, text=True, timeout=60)
        finally:
            if holder:
                holder.close()
        records = [json.loads(line) for line in proc.stdout.splitlines()
                   if line.startswith("{")]
        summary = next((r for r in records if r.get("stage") == "summary"), None)
        assert proc.returncode == expect_exit, (
            f"{name}: exit {proc.returncode} != {expect_exit}\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        if expect_ok:
            assert summary is not None and summary["pd_auth"] is True, \
                f"{name}: expected pd_auth\n{proc.stdout}"
            assert (root / "xiaomi" / "pd_verifed").read_text().strip() == "1"
            assert (root / "xiaomi" / "verify_process").read_text().strip() == "0"
            assert "[host]" in (root / "typec" / "data_role").read_text()
        else:
            assert (root / "xiaomi" / "pd_verifed").read_text().strip() == "0"
            assert (root / "xiaomi" / "verify_process").read_text().strip() == "0"
            assert "[device]" in (root / "typec" / "data_role").read_text(), \
                f"{name}: device role not restored\n{proc.stdout}"
        print(f"ok {name} (exit {proc.returncode})")
        return records
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    run_scenario("success", {"role_ok": True, "svid": True}, 0)
    run_scenario("no-svid", {"role_ok": True, "svid": False}, 1, expect_ok=False)
    run_scenario("role-timeout", {"role_timeout": True}, 1, expect_ok=False)
    run_scenario("bad-id", {"role_ok": True, "svid": True,
                            "adapter_id": "00000000"}, 1, expect_ok=False)
    run_scenario("hmac-mismatch", {"role_ok": True, "svid": True,
                                   "hmac_bad": True}, 1, expect_ok=False)
    run_scenario("lock-held", {"role_ok": True, "svid": True}, 3,
                 expect_ok=False, pre_attach=None, hold_lock=True)
    run_scenario("same-attach", {"role_ok": True, "svid": True}, 5,
                 expect_ok=False, pre_attach="port0-partner:1:2:3:4")
    run_scenario("prepare-no-latch", {"role_ok": True, "svid": True,
                                      "no_latch": True}, 1, expect_ok=False)
    run_scenario("prepare-no-latch-allowed", {"role_ok": True, "svid": True,
                                              "no_latch": True}, 0,
                 extra_args=["--allow-unconfirmed-prepare"])
    print("all staged-auth scenarios passed")


if __name__ == "__main__":
    main()
