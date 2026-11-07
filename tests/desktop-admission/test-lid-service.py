#!/usr/bin/env python3
"""Integration smoke test for the lid service on a private D-Bus.

The state machine and helper are also covered by test-lid-policy.py and
test-power-helper.py. This test runs the real service against a fake UPower,
logind and Mutter in a separate process; it never contacts the desktop or a
device.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import types
from importlib.machinery import SourceFileLoader
from pathlib import Path

import gi

os.environ.setdefault("GIO_USE_VFS", "local")
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

PROJECT = Path(__file__).resolve().parents[2]
SERVICE = PROJECT / "overlays/gnome-local/power/usr/local/libexec/liuqin-lid-policy"

FAKE = r'''#!/usr/bin/python3
import sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

props = {"LidIsClosed": True, "OnBattery": True, "PowerSaveMode": 0,
         "ActiveSession": "1"}
state = {"suspend": 0, "inhibitor": False, "gnome_inhibited": False,
         "locked": False}
conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)

def interface(xml):
    return Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]

UPOWER = interface("""<node><interface name="org.freedesktop.UPower">
<property name="LidIsClosed" type="b" access="read"/>
<property name="OnBattery" type="b" access="read"/>
</interface></node>""")
MANAGER = interface("""<node><interface name="org.freedesktop.login1.Manager">
<method name="ListInhibitors"><arg direction="out" type="a(ssssuu)"/></method>
<method name="Suspend"><arg direction="in" type="b"/></method>
<signal name="PrepareForSleep"><arg type="b"/></signal>
</interface></node>""")
SEAT = interface("""<node><interface name="org.freedesktop.login1.Seat">
<property name="ActiveSession" type="s" access="read"/>
</interface></node>""")
MUTTER = interface("""<node><interface name="org.gnome.Mutter.DisplayConfig">
<property name="PowerSaveMode" type="u" access="readwrite"/>
</interface></node>""")
SESSION = interface("""<node><interface name="org.gnome.SessionManager">
<method name="IsInhibited"><arg direction="in" type="u"/><arg direction="out" type="b"/></method>
</interface></node>""")
SCREENSAVER = interface("""<node><interface name="org.gnome.ScreenSaver">
<method name="Lock"/>
<method name="GetActive"><arg direction="out" type="b"/></method>
</interface></node>""")
CONTROL = interface("""<node><interface name="com.example.LidTestControl">
<method name="SetLid"><arg direction="in" type="b"/></method>
<method name="SetBattery"><arg direction="in" type="b"/></method>
<method name="SetMode"><arg direction="in" type="u"/></method>
<method name="SetInhibitor"><arg direction="in" type="b"/></method>
<method name="SetGnomeInhibited"><arg direction="in" type="b"/></method>
<method name="PrepareSleep"><arg direction="in" type="b"/></method>
<method name="GetSuspendCount"><arg direction="out" type="u"/></method>
<method name="GetMode"><arg direction="out" type="u"/></method>
</interface></node>""")

def changed(iface, name, value):
    conn.emit_signal(None, "/org/freedesktop/UPower", "org.freedesktop.DBus.Properties",
                     "PropertiesChanged",
                     GLib.Variant("(sa{sv}as)", (iface, {name: GLib.Variant("b", value)}, [])))

def upower_get(c, s, p, iface, name):
    return GLib.Variant("b", props[name])

def seat_get(c, s, p, iface, name):
    return GLib.Variant("s", props[name])

def mutter_get(c, s, p, iface, name):
    return GLib.Variant("u", props[name])

def mutter_set(c, s, p, iface, name, value):
    props[name] = value.unpack()
    conn.emit_signal(None, p, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                     GLib.Variant("(sa{sv}as)", (iface, {name: value}, [])))
    return True

def manager_method(c, s, p, iface, name, params, inv):
    if name == "ListInhibitors":
        items = []
        if state["inhibitor"]:
            items.append(("sleep", "test", "test", "block", 1000, 1))
        inv.return_value(GLib.Variant("(a(ssssuu))", (items,)))
    elif name == "Suspend":
        state["suspend"] += 1
        inv.return_value(None)

def session_method(c, s, p, iface, name, params, inv):
    inv.return_value(GLib.Variant("(b)", (state["gnome_inhibited"],)))

def screensaver_method(c, s, p, iface, name, params, inv):
    if name == "Lock":
        state["locked"] = True
        inv.return_value(None)
    elif name == "GetActive":
        inv.return_value(GLib.Variant("(b)", (state["locked"],)))

def control_method(c, s, p, iface, name, params, inv):
    if name == "SetLid":
        props["LidIsClosed"] = params.unpack()[0]
        changed("org.freedesktop.UPower", "LidIsClosed", props["LidIsClosed"])
        inv.return_value(None)
    elif name == "SetBattery":
        props["OnBattery"] = params.unpack()[0]
        changed("org.freedesktop.UPower", "OnBattery", props["OnBattery"])
        inv.return_value(None)
    elif name == "SetMode":
        props["PowerSaveMode"] = params.unpack()[0]
        conn.emit_signal(None, "/org/gnome/Mutter/DisplayConfig",
                         "org.freedesktop.DBus.Properties", "PropertiesChanged",
                         GLib.Variant("(sa{sv}as)",
                                      ("org.gnome.Mutter.DisplayConfig",
                                       {"PowerSaveMode": GLib.Variant("u", props["PowerSaveMode"])}, [])))
        inv.return_value(None)
    elif name == "SetInhibitor":
        state["inhibitor"] = params.unpack()[0]
        inv.return_value(None)
    elif name == "SetGnomeInhibited":
        state["gnome_inhibited"] = params.unpack()[0]
        inv.return_value(None)
    elif name == "PrepareSleep":
        conn.emit_signal(None, "/org/freedesktop/login1",
                         "org.freedesktop.login1.Manager", "PrepareForSleep",
                         GLib.Variant("(b)", (params.unpack()[0],)))
        inv.return_value(None)
    elif name == "GetSuspendCount":
        inv.return_value(GLib.Variant("(u)", (state["suspend"],)))
    elif name == "GetMode":
        inv.return_value(GLib.Variant("(u)", (props["PowerSaveMode"],)))

conn.register_object("/org/freedesktop/UPower", UPOWER, None, upower_get, None)
conn.register_object("/org/freedesktop/login1", MANAGER, manager_method, None, None)
conn.register_object("/org/freedesktop/login1/seat/seat0", SEAT, None, seat_get, None)
conn.register_object("/org/gnome/Mutter/DisplayConfig", MUTTER, None, mutter_get, mutter_set)
conn.register_object("/org/gnome/SessionManager", SESSION, session_method, None, None)
conn.register_object("/org/gnome/ScreenSaver", SCREENSAVER, screensaver_method,
                     None, None)
conn.register_object("/com/example/LidTestControl", CONTROL, control_method, None, None)
for name in ("org.freedesktop.UPower", "org.freedesktop.login1",
             "org.gnome.Mutter.DisplayConfig", "org.gnome.SessionManager",
             "org.gnome.ScreenSaver", "com.example.LidTestControl"):
    Gio.bus_own_name_on_connection(conn, name, Gio.BusNameOwnerFlags.NONE, None, None)
GLib.MainLoop().run()
'''


def pump(ms):
    context = GLib.MainContext.default()
    end = time.monotonic() + ms / 1000
    while time.monotonic() < end:
        context.iteration(False)
        time.sleep(0.01)


def main():
    work = Path(tempfile.mkdtemp(prefix="liuqin-lid-service-"))
    bus = subprocess.Popen(
        ["dbus-daemon", "--session", "--nofork", "--print-address=1"],
        stdout=subprocess.PIPE,
        text=True,
    )
    try:
        address = bus.stdout.readline().strip()
        assert address, "dbus-daemon did not print an address"
        os.environ["DBUS_SESSION_BUS_ADDRESS"] = address
        os.environ["DBUS_SYSTEM_BUS_ADDRESS"] = address
        fake_path = work / "fake.py"
        fake_path.write_text(FAKE)
        fake = subprocess.Popen([sys.executable, str(fake_path)])
        try:
            conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            for _ in range(100):
                reply = conn.call_sync(
                    "org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "NameHasOwner",
                    GLib.Variant("(s)", ("com.example.LidTestControl",)),
                    GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NONE, 300, None,
                )
                if reply.unpack()[0]:
                    break
                time.sleep(0.05)
            else:
                raise SystemExit("fake services did not start")

            socket_path = address.split("path=")[1].split(",")[0]
            runtime = work / "runtime"
            runtime.mkdir()
            (runtime / "bus").symlink_to(socket_path)
            runtime = str(runtime)

            config = work / "power-policy.conf"
            config.write_text("LID_ACTION=blank\nLID_RESUSPEND=1\n")
            calls = work / "calls"
            helper = work / "helper.sh"
            helper.write_text(f'#!/bin/sh\nprintf "%s\\n" "$1" >> {calls}\n')
            helper.chmod(0o755)

            module = types.ModuleType("liuqin_lid_policy")
            SourceFileLoader("liuqin_lid_policy", str(SERVICE)).exec_module(module)
            module.RESUSPEND_DELAY_MS = 250
            module.RESUME_CONFIRM_MS = 100
            module.FIX_INTERVAL_MS = 50
            module.CONFIG = str(config)
            module.POLICY_HELPER = str(helper)
            module.active_session = lambda: {
                "uid": "1000", "gid": "1000", "name": "user",
                "home": str(work), "runtime": runtime,
            }

            service = module.LidService()
            # Never read the host's real input devices from an offline test.
            module.LidService.start_input_watch = lambda self: None
            assert service.start() == 0
            pump(400)
            lines = calls.read_text().splitlines()
            assert lines == ["ensure-off"], lines

            # Phase 1: the helper-facing state file exists, is private, and
            # reflects the actual lid state.
            state_file = Path(runtime) / "liuqin-power-keyd" / "power-state.json"
            assert state_file.is_file(), state_file
            assert stat.S_IMODE(state_file.stat().st_mode) == 0o600
            state = json.loads(state_file.read_text())
            assert state["lid_closed"] is True, state
            assert state["on_battery"] is True, state
            assert state["state"] in ("AWAKE", "BLANK", "RETRY_WAIT"), state
            assert "last_resume_monotonic_ms" in state, state

            def control(method, signature=None, value=None):
                params = GLib.Variant(signature, value) if signature else None
                conn.call_sync("com.example.LidTestControl", "/com/example/LidTestControl",
                               "com.example.LidTestControl", method, params, None,
                               Gio.DBusCallFlags.NONE, 3000, None)

            def count(action):
                return calls.read_text().splitlines().count(action)

            # GNOME resume actions turn the panel on again -> re-blank.
            control("SetMode", "(u)", (0,))
            pump(300)
            assert count("ensure-off") == 2, calls.read_text()

            # Lid open must wake; a later display change must not blank.
            control("SetLid", "(b)", (False,))
            pump(500)
            assert count("ensure-on") == 1, calls.read_text()
            before = count("ensure-off")
            control("SetMode", "(u)", (0,))
            pump(300)
            assert count("ensure-off") == before, calls.read_text()

            # Lid close blanks again.
            control("SetLid", "(b)", (True,))
            pump(500)
            assert count("ensure-off") == before + 1, calls.read_text()

            # Automatic resume with the lid closed starts the re-suspend window.
            control("PrepareSleep", "(b)", (True,))
            pump(100)
            control("PrepareSleep", "(b)", (False,))
            pump(700)
            reply = conn.call_sync("com.example.LidTestControl", "/com/example/LidTestControl",
                                   "com.example.LidTestControl", "GetSuspendCount", None,
                                   GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 3000, None)
            assert reply.unpack()[0] == 1, reply.unpack()
            state = json.loads(state_file.read_text())
            assert state["last_resume_monotonic_ms"] > 0, state
            assert state["wake_cause"] in ("abnormal", "user", "scheduled"), state
            assert state["retry_count"] == 1, state

            # A logind block inhibitor cancels the next automatic suspend.
            control("SetInhibitor", "(b)", (True,))
            control("PrepareSleep", "(b)", (True,))
            pump(100)
            control("PrepareSleep", "(b)", (False,))
            pump(700)
            reply = conn.call_sync("com.example.LidTestControl", "/com/example/LidTestControl",
                                   "com.example.LidTestControl", "GetSuspendCount", None,
                                   GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 3000, None)
            assert reply.unpack()[0] == 1, "inhibited resume must not suspend"
            control("SetInhibitor", "(b)", (False,))

            # A GNOME session inhibitor also cancels it.
            control("SetGnomeInhibited", "(b)", (True,))
            control("PrepareSleep", "(b)", (True,))
            pump(100)
            control("PrepareSleep", "(b)", (False,))
            pump(700)
            reply = conn.call_sync("com.example.LidTestControl", "/com/example/LidTestControl",
                                   "com.example.LidTestControl", "GetSuspendCount", None,
                                   GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 3000, None)
            assert reply.unpack()[0] == 1, "GNOME-inhibited resume must not suspend"
            control("SetGnomeInhibited", "(b)", (False,))

            # A deliberate power-key press cancels protection.
            marker = Path(runtime) / "liuqin-power-keyd" / "power-key-action"
            marker.write_text("1\n")
            pump(300)
            before = count("ensure-off")
            control("SetMode", "(u)", (0,))
            pump(300)
            assert count("ensure-off") == before, "power-key override was not honoured"

            print("PASS: service startup, display protection, lid, re-suspend, override")
        finally:
            fake.terminate()
            fake.wait(timeout=5)
    finally:
        bus.terminate()
        bus.wait(timeout=5)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
