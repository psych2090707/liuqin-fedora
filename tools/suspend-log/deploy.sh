#!/bin/bash
# Deploy suspend/resume evidence tools to the liuqin tablet.
#
# Usage: tools/suspend-log/deploy.sh
#
# Installs these targets (early-wake helper is inactive without explicit opt-in):
#   /usr/local/sbin/liuqin-suspend-log
#   /usr/local/sbin/liuqin-early-wake-log
#   /usr/lib/systemd/system-sleep/50-liuqin-suspend-log
#   /usr/local/bin/liuqin-notify-log
#   $DEV_HOME/.config/systemd/user/liuqin-notify-log.service
# Restarts the already-running user service (enable --now alone would leave the
# old process in place), reads the hashes back, then runs one pre/post self-test
# in /tmp (not in the real state directory) and one labelled test notification.
# It does not suspend the device, restart the desktop, or change power policy.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV_USER="${LIUQIN_DEV_USER:-user}"
DEV_HOME="${LIUQIN_DEV_HOME:-/home/$DEV_USER}"
AFK="$ROOT/tools/afk/afk.sh"
SRC="$ROOT/tools/suspend-log"
TEST_STATE="/tmp/liuqin-suspend-log-selftest"
USER_ENV="XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
TARGETS=(
    /usr/local/sbin/liuqin-suspend-log
    /usr/local/sbin/liuqin-early-wake-log
    /usr/lib/systemd/system-sleep/50-liuqin-suspend-log
    /usr/local/bin/liuqin-notify-log
    "$DEV_HOME/.config/systemd/user/liuqin-notify-log.service"
)
NOTIFY_LOG="$DEV_HOME/.local/state/liuqin-notify-log/notifications.jsonl"
SCREEN_LOG="$DEV_HOME/.local/state/liuqin-notify-log/screen-events.jsonl"

[ -x "$AFK" ] || { echo "missing $AFK" >&2; exit 1; }
for name in liuqin-suspend-log liuqin-early-wake-log 50-liuqin-suspend-log liuqin-notify-log \
            liuqin-notify-log.service; do
    [ -f "$SRC/$name" ] || { echo "missing $SRC/$name" >&2; exit 1; }
done

"$AFK" status >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
install -m 0755 "$SRC/liuqin-suspend-log" "$tmp/liuqin-suspend-log"
install -m 0755 "$SRC/liuqin-early-wake-log" "$tmp/liuqin-early-wake-log"
install -m 0755 "$SRC/50-liuqin-suspend-log" "$tmp/50-liuqin-suspend-log"
install -m 0755 "$SRC/liuqin-notify-log" "$tmp/liuqin-notify-log"
install -m 0644 "$SRC/liuqin-notify-log.service" "$tmp/liuqin-notify-log.service"

for name in liuqin-suspend-log liuqin-early-wake-log 50-liuqin-suspend-log liuqin-notify-log \
            liuqin-notify-log.service; do
    "$AFK" push "$tmp/$name" "/tmp/$name"
done

service_before="$("$AFK" run "env $USER_ENV systemctl --user show liuqin-notify-log.service -p ActiveState -p UnitFileState -p ExecMainStartTimestampMonotonic")"
before_active="$(sed -n 's/^ActiveState=//p' <<<"$service_before")"
if [ "$before_active" != active ]; then
    echo "WARN: recorder was not active before deploy (was: ${before_active:-missing})" >&2
fi
before_start="$(sed -n 's/^ExecMainStartTimestampMonotonic=//p' <<<"$service_before")"

"$AFK" sudo "
set -euo pipefail
install -D -m 0755 /tmp/liuqin-suspend-log /usr/local/sbin/liuqin-suspend-log
install -D -m 0755 /tmp/liuqin-early-wake-log /usr/local/sbin/liuqin-early-wake-log
install -D -m 0755 /tmp/50-liuqin-suspend-log /usr/lib/systemd/system-sleep/50-liuqin-suspend-log
rm -f /etc/systemd/system-sleep/50-liuqin-suspend-log
install -D -m 0755 /tmp/liuqin-notify-log /usr/local/bin/liuqin-notify-log
install -D -o $DEV_USER -g $DEV_USER -m 0644 /tmp/liuqin-notify-log.service $DEV_HOME/.config/systemd/user/liuqin-notify-log.service
install -d -m 0700 /var/lib/liuqin-suspend-log
rm -f /tmp/liuqin-suspend-log /tmp/liuqin-early-wake-log /tmp/50-liuqin-suspend-log /tmp/liuqin-notify-log /tmp/liuqin-notify-log.service
"

"$AFK" run "env $USER_ENV systemctl --user daemon-reload"
# The service is already running, so an explicit restart is required.
"$AFK" run "env $USER_ENV systemctl --user restart liuqin-notify-log.service"

remote_hashes="$("$AFK" sudo "sha256sum /usr/local/sbin/liuqin-suspend-log /usr/local/sbin/liuqin-early-wake-log /usr/lib/systemd/system-sleep/50-liuqin-suspend-log /usr/local/bin/liuqin-notify-log $DEV_HOME/.config/systemd/user/liuqin-notify-log.service")"
python3 - "$SRC" "$remote_hashes" "$DEV_HOME" <<'PY'
import hashlib
import sys
from pathlib import Path

src = Path(sys.argv[1])
dev_home = sys.argv[3]
remote = {}
for line in sys.argv[2].splitlines():
    parts = line.split()
    if len(parts) == 2:
        remote[parts[1]] = parts[0]
mapping = {
    "liuqin-suspend-log": "/usr/local/sbin/liuqin-suspend-log",
    "liuqin-early-wake-log": "/usr/local/sbin/liuqin-early-wake-log",
    "50-liuqin-suspend-log": "/usr/lib/systemd/system-sleep/50-liuqin-suspend-log",
    "liuqin-notify-log": "/usr/local/bin/liuqin-notify-log",
    "liuqin-notify-log.service": f"{dev_home}/.config/systemd/user/liuqin-notify-log.service",
}
for local, target in mapping.items():
    expected = hashlib.sha256((src / local).read_bytes()).hexdigest()
    if remote.get(target) != expected:
        raise SystemExit(f"FAIL: hash mismatch for {target}")
print("PASS: five deployed files match the repository")
PY

sleep 1
service_after="$("$AFK" run "env $USER_ENV systemctl --user show liuqin-notify-log.service -p ActiveState -p UnitFileState -p ExecMainStartTimestampMonotonic")"
after_active="$(sed -n 's/^ActiveState=//p' <<<"$service_after")"
after_start="$(sed -n 's/^ExecMainStartTimestampMonotonic=//p' <<<"$service_after")"
[ "$after_active" = active ] || { echo "FAIL: service ActiveState=$after_active" >&2; exit 1; }
[ -n "$after_start" ] && [ "$after_start" -gt "${before_start:-0}" ] || {
    echo "FAIL: recorder did not restart (before=${before_start:-?} after=${after_start:-?})" >&2
    exit 1
}
echo "PASS: recorder restarted (ActiveState=active)"

# One labelled test notification: it must land within 2 s and send no body.
before_lines="$("$AFK" run "wc -l < $NOTIFY_LOG 2>/dev/null || echo 0" | tr -d ' ')"
"$AFK" run "env $USER_ENV notify-send -a liuqin-deploy-test 'deploy self-test' 'control notification'"
sleep 2
after_lines="$("$AFK" run "wc -l < $NOTIFY_LOG 2>/dev/null || echo 0" | tr -d ' ')"
added=$(( ${after_lines:-0} - ${before_lines:-0} ))
[ "$added" -eq 1 ] || {
    echo "FAIL: expected exactly one new notification row within 2 s, got $added" >&2
    exit 1
}
tail_line="$("$AFK" run "tail -n 1 $NOTIFY_LOG")"
case "$tail_line" in
    *'"app":"liuqin-deploy-test"'*) ;;
    *) echo "FAIL: unexpected app in last row: $tail_line" >&2; exit 1 ;;
esac
case "$tail_line" in
    *'"summary":"deploy self-test"'*) ;;
    *) echo "FAIL: unexpected summary in last row: $tail_line" >&2; exit 1 ;;
esac
case "$tail_line" in
    *body*) echo "FAIL: notification row contains a body field" >&2; exit 1 ;;
esac
echo "PASS: single notification recorded immediately (one row, no forward duplicate)"

"$AFK" run "test -s $SCREEN_LOG"
snapshots="$("$AFK" run "grep -c '\"kind\":\"snapshot\"' $SCREEN_LOG || true" | tr -d ' ')"
[ "${snapshots:-0}" -ge 1 ] || { echo "FAIL: no initial screen-event snapshot" >&2; exit 1; }
echo "PASS: screen-event snapshot present ($snapshots rows)"

"$AFK" sudo "set -euo pipefail
rm -rf $TEST_STATE
LIUQIN_SUSPEND_LOG_STATE=$TEST_STATE /usr/lib/systemd/system-sleep/50-liuqin-suspend-log pre suspend
LIUQIN_SUSPEND_LOG_STATE=$TEST_STATE /usr/lib/systemd/system-sleep/50-liuqin-suspend-log post suspend
echo '--- self-test report (head) ---'
sed -n '1,40p' $TEST_STATE/events/*/report.txt
rm -rf $TEST_STATE"

echo
echo "installed: /usr/local/sbin/liuqin-suspend-log"
echo "installed: /usr/local/sbin/liuqin-early-wake-log (auto mode remains opt-in)"
echo "installed: /usr/lib/systemd/system-sleep/50-liuqin-suspend-log"
echo "installed: /usr/local/bin/liuqin-notify-log"
echo "logs:      /var/lib/liuqin-suspend-log (root only)"
echo
echo "self-test does not sleep; real_sleep=unknown or no there is expected."
echo "next: let the tablet suspend on battery, then run"
echo "  tools/afk/afk.sh sudo 'liuqin-suspend-log latest'"
