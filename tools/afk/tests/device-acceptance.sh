#!/bin/bash
# AFK channel (TN0048) — device acceptance checklist, one step at a time.
#
# Turns RESULT.md §5 ("待实机联调") into a repeatable, fail-fast run.  Each step
# prints PASS/FAIL and the evidence path; on the first failure it stops and
# prints what to look at.  It only uses tools/afk/afk.sh.
#
# Usage:
#   tests/device-acceptance.sh                 # all steps, starting at 1
#   tests/device-acceptance.sh --from 4        # resume at step 4 (after a reboot)
#   tests/device-acceptance.sh --only 1,2      # selected steps
#   tests/device-acceptance.sh --list          # show steps
#
# Steps:
#   1 read-only link check (status/doctor)
#   2 overlay install dry-run
#   3 overlay install (RPM bundle auto-detected)
#   4 reboot --wait + post-reboot SSH/RDP listener check
#   5 screenshot (autologin + spectacle)
#   6 RDP listener + client availability
#   7 log bundle (persistent journal + pstore across reboot)
#   8 watchdog capability report
#
# Nothing here is destructive beyond steps 3/4 (which the operator explicitly
# opts into by running them; the installer backs up every file it replaces).
set -uo pipefail

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$TOOLS_DIR/lib/common.sh"

AFK="$TOOLS_DIR/afk.sh"
LOG_DIR="$AFK_STATE_DIR/evidence"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/device-acceptance-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1

pass=0
fail=0
okc()   { printf '\033[32m[pass]\033[0m %s\n' "$*"; pass=$((pass + 1)); }
failc() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; fail=$((fail + 1)); }
sect()  { printf '\n===== %s =====\n' "$*"; }

steps=(
    "1|read-only link check (status + doctor)"
    "2|overlay install --dry-run"
    "3|overlay install (real)"
    "4|reboot --wait + post-reboot listeners"
    "5|screenshot of the live Plasma session"
    "6|RDP listener + host RDP client"
    "7|log bundle (journal/pstore across reboot)"
    "8|watchdog capability report"
)
FROM=1
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:?}"; shift 2 ;;
        --from=*) FROM="${1#*=}"; shift ;;
        --only) ONLY="${2:?}"; shift 2 ;;
        --only=*) ONLY="${1#*=}"; shift ;;
        --list) printf '%s\n' "${steps[@]}" | sed 's/|/: /'; exit 0 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

selected() {
    local n="$1"
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in *",$n,"*) return 0 ;; *) return 1 ;; esac
    fi
    [ "$n" -ge "$FROM" ]
}

say "device acceptance run: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "host: iface=$(afk_detect_iface 2>/dev/null || echo none)  device=$AFK_DEV_HOST  user=$AFK_DEV_USER"
say "log: $LOG"

step1() {
    sect "1. read-only link check"
    bash "$AFK" status || { failc "status: link/SSH not ready"; say "-> check cable, tablet booted past initramfs; try: $AFK up"; return 1; }
    okc "status reports the device reachable"
    if bash "$AFK" doctor; then
        okc "doctor: no failures"
    else
        # Before step 3 the overlay is not installed yet, so doctor MUST fail.
        warn "doctor reported failures (expected before step 3: overlay not installed)"
        say "   continuing is allowed; re-run doctor after step 4 for the real check"
    fi
    return 0
}

step2() {
    sect "2. overlay install --dry-run"
    bash "$AFK" overlay-install --dry-run >"$LOG_DIR/dry-run.txt" 2>&1
    local rc=$?
    if [ "$rc" = 0 ]; then okc "dry-run completed (log: $LOG_DIR/dry-run.txt)"
    else failc "dry-run failed (log: $LOG_DIR/dry-run.txt)"; tail -n 20 "$LOG_DIR/dry-run.txt"; return 1; fi
    return 0
}

step3() {
    sect "3. overlay install (real)"
    say "this writes device config and installs the offline RPM bundle; every replaced file is backed up"
    bash "$AFK" overlay-install || { failc "overlay install failed"; return 1; }
    okc "overlay installed"
    bash "$AFK" run 'cat /var/lib/afk/version' >/dev/null 2>&1 && okc "device reports an overlay version" \
        || failc "device has no /var/lib/afk/version"
    return 0
}

step4() {
    sect "4. reboot and come back"
    bash "$AFK" reboot --wait 300 || { failc "device did not return after reboot"; return 1; }
    okc "SSH returned after reboot"
    sleep 5
    if port_open "$AFK_DEV_HOST" 22; then okc "sshd listening"; else failc "sshd not listening"; return 1; fi
    local addr
    addr="$(ssh_run "$AFK_DEV_HOST" 'ip -4 -o addr show dev usb0' 2>/dev/null || true)"
    if printf '%s' "$addr" | grep -q '192\.168\.7\.2'; then okc "usb0 has 192.168.7.2/24 after reboot"
    else failc "usb0 address missing after reboot: $addr"; return 1; fi
    if ssh_run "$AFK_DEV_HOST" 'test -f /etc/NetworkManager/conf.d/90-afk-unmanaged.conf' 2>/dev/null; then
        okc "NetworkManager still leaves usb0 unmanaged"
    else
        failc "NM unmanaged config missing"; return 1
    fi
    if port_open "$AFK_DEV_HOST" "$AFK_RDP_PORT"; then okc "KRDP listener up after reboot"
    else warn "KRDP listener not up yet (autologin/user unit may still be starting)"; fi
    bash "$AFK" doctor && okc "doctor: no failures after reboot" || warn "doctor still reports failures (see above)"
    return 0
}

step5() {
    sect "5. screenshot the live session"
    local out
    if ! out="$(bash "$AFK" shot 2>/dev/null | tail -n1)"; then
        failc "screenshot failed"; say "-> $AFK diag | grep -E 'plasmashell|kwin|session'"; return 1
    fi
    [ -s "$out" ] || { failc "screenshot file missing: $out"; return 1; }
    okc "screenshot: $out ($(stat -c %s "$out") bytes)"
    # A pure-black PNG is the usual symptom of a stopped/blanked compositor.
    if python3 - "$out" <<'PY'
import sys, zlib, struct
p = sys.argv[1]
data = open(p, 'rb').read()
if not data.startswith(b'\x89PNG\r\n\x1a\n'):
    sys.exit(1)
pos, idat = 8, b''
while pos < len(data):
    ln, typ = struct.unpack('>I4s', data[pos:pos+8])
    if typ == b'IDAT':
        idat += data[pos+8:pos+8+ln]
    pos += 12 + ln
raw = zlib.decompress(idat)
if not raw or max(raw[:65536]) == 0:
    sys.exit(2)   # decompressed scanlines are all zero -> black frame
PY
    then okc "screenshot is not an all-black frame"
    else warn "screenshot looks black/empty (DPMS off or no Plasma session?)"; fi
    return 0
}

step6() {
    sect "6. RDP listener + client"
    if port_open "$AFK_DEV_HOST" "$AFK_RDP_PORT"; then okc "KRDP listening on $AFK_DEV_HOST:$AFK_RDP_PORT"
    else failc "KRDP not listening"; say "-> $AFK diag | grep -E 'krdp|rdp_listener'"; return 1; fi
    local client=""
    for c in xfreerdp xfreerdp3 wlfreerdp wlfreerdp3; do
        have_cmd "$c" && { client="$c"; break; }
    done
    if [ -n "$client" ]; then okc "host RDP client: $client"
    else warn "no host RDP client; install freerdp to actually open the session"; fi
    say "parameters: $AFK_DEV_HOST:$AFK_RDP_PORT  user=$AFK_DEV_USER  pass(\$AFK_DEV_PASS)  self-signed cert"
    return 0
}

step7() {
    sect "7. log bundle"
    local dir
    if ! dir="$(bash "$AFK" logs | tail -n1)"; then failc "logs failed"; return 1; fi
    okc "bundle: $dir"
    for f in bundle/logs/journal-current.log bundle/logs/journal-previous.log bundle/logs/failed-units.txt; do
        if [ -s "$dir/$f" ]; then okc "contains $f ($(stat -c %s "$dir/$f") bytes)"
        else failc "missing/empty $f"; fi
    done
    if ssh_run "$AFK_DEV_HOST" 'test -d /var/log/journal && journalctl --list-boots --no-pager | wc -l' 2>/dev/null | grep -qE '^[2-9]'; then
        okc "persistent journald keeps more than one boot"
    else
        warn "only one boot in the journal so far (see persistent journal check)"
    fi
    return 0
}

step8() {
    sect "8. watchdog capability"
    bash "$AFK" watchdog show || { failc "watchdog query failed"; return 1; }
    okc "watchdog state reported (see above; enabling is a separate opt-in decision)"
    return 0
}

for entry in "${steps[@]}"; do
    n="${entry%%|*}"
    name="${entry#*|}"
    selected "$n" || continue
    step_log="$LOG_DIR/acceptance-step-$n.txt"
    "step$n" >"$step_log" 2>&1
    step_rc=$?
    cat "$step_log"
    # A printed [FAIL] (not the lowercase [fail] from tools/afk/afk.sh helpers)
    # or a non-zero step return stops the run.
    if grep -q '\[FAIL\]' "$step_log" || [ "$step_rc" != 0 ]; then
        break
    fi
done

sect "summary"
printf 'pass=%d fail=%d  log=%s\n' "$pass" "$fail" "$LOG"
if [ "$fail" -eq 0 ]; then
    say "all selected acceptance steps passed; record evidence paths in the current goal RESULT; see tasks/README.md"
else
    say "stopped on a failing step; see the FAIL lines and the log above"
fi
[ "$fail" -eq 0 ]
