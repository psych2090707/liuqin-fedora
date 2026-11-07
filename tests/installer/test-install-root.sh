#!/bin/sh
# SPDX-License-Identifier: MIT
# End-to-end offline test of the Fedora device-side installer
# (installer/lib/install-root.sh).
#
# The RAM-image environment cannot run on an x86 host, so this suite runs the
# real script text on a fixture: only the absolute /sys,/dev,/mnt,/run,/etc
# paths are rewritten, and the three "partitions" are ext4 image files.  The
# host kernel of this machine has no loop driver (CONFIG_BLK_DEV_LOOP is not
# built in and the module is absent), so the images are mounted through
# usermode ext4 (fuse2fs) instead of loop devices, and the two block-device
# behaviours the script relies on are provided by small stubs:
#
#   * `mount`/`umount`      -> fuse2fs / umount, with the tmpfs download
#                              directory as a plain directory;
#   * `blockdev --getro`    -> a state file per image, so the fail-closed
#     `--setro`/`--setrw`      read-only posture is still asserted;
#   * `[ -b … ]`            -> `[ -e … ]` (the images are regular files).
#
# Everything else is real: mkfs.ext4/e2fsck/e2label on the images, GNU tar
# extraction with numeric owners/modes/ACLs/xattrs/capabilities, the persist
# provisioning script, the Fedora contract verification, the fstab write,
# KEPT-HOME handling, and a local HTTP server standing in for the host that
# serves rootfs.tar.gz.  Nothing outside the temporary directory is touched
# and no real device is involved.
#
# Requires root (fuse mounts), busybox, fuse2fs and a writable temporary
# directory; it skips cleanly when those are unavailable.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

if [ "$(id -u)" != 0 ] || [ "${LIUQIN_INSTALL_ROOT_FIXTURE:-0}" != 1 ]; then
	if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
		printf '%s\n' 'SKIP: test-install-root needs root (sudo NOPASSWD), fuse2fs and busybox'
		exit 0
	fi
	exec sudo -n env LIUQIN_INSTALL_ROOT_FIXTURE=1 sh "$0" "$@"
fi

fail() { printf 'test-install-root: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

for tool in busybox mkfs.ext4 e2fsck e2label getcap fuse2fs fusermount3 mount umount \
	tar sha256sum stat python3; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"
done
[ -e /dev/fuse ] || { printf '%s\n' 'SKIP: /dev/fuse is unavailable'; exit 0; }

# The fixture path must not contain spaces: the rewritten script is plain shell
# text and a space would split its unquoted sysfs globs.
work=$(mktemp -d "${LIUQIN_TEST_TMP:-/var/tmp}/liuqin-install-root-test.XXXXXX")
fixture=$work/fixture
serve=$work/serve
rootfs=$work/rootfs
serve_port=
server_pid=
cleanup() {
	set +eu
	if [ -n "$server_pid" ]; then
		kill "$server_pid" 2>/dev/null || true
	fi
	fusermount3 -u "$fixture/mnt/install" 2>/dev/null || true
	fusermount3 -u "$fixture/mnt/install-home" 2>/dev/null || true
	fusermount3 -u "$fixture/run/persist" 2>/dev/null || true
	fusermount3 -u "$work/verify-root" 2>/dev/null || true
	fusermount3 -u "$work/verify-home" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# Fixture directories, sysfs, power supply, boot_id and RAM-image markers.
# ---------------------------------------------------------------------------
bin=$work/bin
mkdir -p "$bin" "$fixture/dev/disk/by-partlabel" "$fixture/sys/power_supply/BAT0" \
	"$fixture/etc" "$fixture/run/persist" "$fixture/mnt/install-download" \
	"$fixture/mnt/install" "$fixture/mnt/install-home" "$fixture/usr/lib/liuqin" \
	"$fixture/blockdev-state" "$serve" "$rootfs/etc" "$rootfs/usr/bin" \
	"$rootfs/usr/lib/systemd/system" "$rootfs/usr/libexec" \
	"$rootfs/usr/share/liuqin" "$rootfs/home/liuqin"
printf 'Battery\n' >"$fixture/sys/power_supply/BAT0/type"
printf '80\n' >"$fixture/sys/power_supply/BAT0/capacity"
printf 'liuqin\n' >"$fixture/etc/liuqin-installer"
printf '%s\n' 'c0ffee00-0000-4000-8000-000000000abc' >"$fixture/boot_id"
printf '%s\n' 'feedc0de-0000-4000-8000-000000000123' >"$fixture/random-uuid"

# Stub blockdev: the images are regular files, so the read-only posture is
# recorded per node in a state file.  The shipped script names
# /bin/busybox blockdev; the sed below redirects exactly that call.
cat >"$bin/blockdev" <<STUB
#!/bin/sh
state=$fixture/blockdev-state
node=\${2##*/}
case \$1 in
--getro) cat "\$state/\$node" 2>/dev/null || echo 0 ;;
--setro) printf '1\\n' >"\$state/\$node" ;;
--setrw) printf '0\\n' >"\$state/\$node" ;;
--rereadpt) exit 0 ;;
*) exit 0 ;;
esac
STUB
# Stub mount/umount: tmpfs becomes a plain directory; ext4 images go through
# fuse2fs.  The script only ever mounts the fixture paths (rewritten below).
cat >"$bin/mount" <<STUB
#!/bin/sh
case "\$*" in
*"-t tmpfs"*) exit 0 ;;
esac
[ "\$1" = -t ] && [ "\$2" = ext4 ] || { echo "mount stub: unsupported: \$*" >&2; exit 1; }
shift 2
mode=
if [ "\$1" = -o ]; then
	case \$2 in ro|ro,*) mode=ro ;; esac
	shift 2
fi
[ "\$#" = 2 ] || { echo "mount stub: unsupported: \$*" >&2; exit 1; }
if [ -n "\$mode" ]; then
	exec fuse2fs -o ro "\$1" "\$2" 2>/dev/null
fi
exec fuse2fs "\$1" "\$2" 2>/dev/null
STUB
cat >"$bin/umount" <<'STUB'
#!/bin/sh
# Absolute paths: a bare `umount` here would resolve back to this stub because
# its directory is first on PATH inside the installer fixture.
/usr/bin/umount "$1" 2>/dev/null || /usr/bin/fusermount3 -u "$1" 2>/dev/null || true
exit 0
STUB
chmod 0755 "$bin"/*

# The synthetic persist partition: exactly the factory data the installer
# reads, on a real ext4 image mounted read-only later by the script.
truncate -s 64M "$work/persist.img"
mkfs.ext4 -q -F -L PERSIST "$work/persist.img"
mkdir -p "$work/persist-src"
fuse2fs "$work/persist.img" "$work/persist-src" 2>/dev/null
ln -s "$work/persist.img" "$fixture/dev/disk/by-partlabel/persist"
mkdir -p "$work/persist-src/wlan" "$work/persist-src/bluetooth" \
	"$work/persist-src/audio" "$work/persist-src/sensors/registry/registry"
printf 'wlan0=020000000001\n' >"$work/persist-src/wlan/wlan_mac.bin"
printf '\002\000\000\000\000\002' >"$work/persist-src/bluetooth/.bt_nv.bin"
python3 - "$work/persist-src/audio/crus_calr.bin" <<'PY'
import sys
open(sys.argv[1], 'wb').write(bytes(range(16)))
PY
index=0
while [ "$index" -lt 101 ]; do
	printf 'registry-item-%03d\n' "$index" >"$work/persist-src/sensors/registry/registry/item$index"
	index=$((index + 1))
done
sync
umount "$work/persist-src"
printf '1\n' >"$fixture/blockdev-state/persist"
ln -s /proc/self/fd/0 "$fixture/dev/stdin"
cp "$project_root/installer/lib/provision.sh" "$fixture/usr/lib/liuqin/provision.sh"
cp "$project_root/installer/lib/install-privileges.sh" \
	"$fixture/usr/lib/liuqin/install-privileges.sh"
[ -f "$fixture/usr/lib/liuqin/install-privileges.sh" ] ||
	fail 'the privileged-file validator is missing from installer/lib'

# The two target "partitions", resolved by PARTNAME through the fixture sysfs.
add_part() { # IMAGE PARTNAME NODE
	ap_image=$1
	ap_label=$2
	ap_name=$3
	ap_size=$(stat -c %s "$ap_image")
	mkdir -p "$fixture/devices/sda/$ap_name"
	printf 'PARTNAME=%s\n' "$ap_label" >"$fixture/devices/sda/$ap_name/uevent"
	printf '%s\n' "$((ap_size / 512))" >"$fixture/devices/sda/$ap_name/size"
	printf '8:%s\n' "${ap_name#sda}" >"$fixture/devices/sda/$ap_name/dev"
	ln -s "../devices/sda/$ap_name" "$fixture/sys/$ap_name"
	ln -s "$ap_image" "$fixture/dev/$ap_name"
	printf '1\n' >"$fixture/blockdev-state/$ap_name"
}
truncate -s 17G "$work/root.img"
truncate -s 9G "$work/home.img"
ln -s "$work/root.img" "$fixture/dev/sda"
printf '1\n' >"$fixture/blockdev-state/sda"
add_part "$work/root.img" linux_root sda36
add_part "$work/home.img" linux_home sda37

# A dummy Fedora KDE root with the ADR-0004 D2 topology the contract v2 checks:
# root marker, plasmalogin login manager, Plasma session programs, PID1 handoff,
# kernel identity interface, plus the privileged files tar must restore with
# their modes/capabilities.
mkdir -p "$rootfs/etc/liuqin" "$rootfs/etc/systemd/system" "$rootfs/usr/sbin"
printf 'NAME="Fedora Linux"\nID=fedora\nVERSION_ID=44\n' >"$rootfs/etc/os-release"
printf 'root:x:0:0:root:/root:/bin/bash\nliuqin:x:1000:1000::/home/liuqin:/bin/bash\nfastrpc:x:1001:1001::/:/bin/false\n' >"$rootfs/etc/passwd"
printf 'root:x:0:\nliuqin:x:1000:\nfastrpc:x:1001:\n' >"$rootfs/etc/group"
: >"$rootfs/etc/machine-id"
printf 'liuqin-fedora-root-v1\n' >"$rootfs/etc/liuqin-fedora-root"
chmod 0644 "$rootfs/etc/liuqin-fedora-root"
printf 'IMAGE_ID=liuqin-fedora-kde\nLOGIN_MANAGER=plasmalogin\nROOT_LABEL=LIUQIN_ROOT\n' \
	>"$rootfs/etc/liuqin/image-contract"
cat >"$rootfs/usr/lib/systemd/system/plasmalogin.service" <<'UNIT'
[Unit]
Description=Plasma Login Manager (fixture)
PartOf=graphical.target
[Service]
ExecStart=/usr/bin/plasmalogin
[Install]
Alias=display-manager.service
UNIT
printf '[Unit]\nDescription=Graphical Interface\n' >"$rootfs/usr/lib/systemd/system/graphical.target"
for executable in usr/lib/systemd/systemd usr/bin/plasmalogin usr/bin/plasmashell \
	usr/bin/kwin_wayland usr/bin/startplasma-wayland usr/libexec/kscreenlocker_greet; do
	printf '#!/bin/sh\nexit 0\n' >"$rootfs/$executable"
	chmod 0755 "$rootfs/$executable"
done
ln -s ../lib/systemd/systemd "$rootfs/usr/sbin/init"
printf '#!/bin/sh\nexit 0\n' >"$rootfs/usr/bin/sudo"
chmod 4111 "$rootfs/usr/bin/sudo"
# Real Fedora 44 facts (the P0 this test previously missed): iputils ping is
# mode 0755 with NO file capability (it uses net.ipv4.ping_group_range), while
# /usr/bin/kwin_wayland DOES carry cap_sys_nice=ep.  The installer's expectation
# list is derived from the tree, so the fixture must contain the same shape and
# may not forge a ping capability.
printf '#!/bin/sh\nexit 0\n' >"$rootfs/usr/bin/ping"
chmod 0755 "$rootfs/usr/bin/ping"
setcap cap_sys_nice=ep "$rootfs/usr/bin/kwin_wayland" ||
	fail 'cannot set capabilities on the fixture kwin_wayland'
printf '#!/bin/sh\nexit 0\n' >"$rootfs/usr/libexec/liuqin-power-keyd"
chmod 0755 "$rootfs/usr/libexec/liuqin-power-keyd"
printf '6.17.0-liuqin-fixture\n' >"$rootfs/usr/share/liuqin/kernel.release"
printf '# fixture modules\n/usr/lib/modules/6.17.0-liuqin-fixture/fixture.ko\n' \
	>"$rootfs/usr/share/liuqin/kernel-modules.manifest"
printf 'profile\n' >"$rootfs/home/liuqin/.profile"
tar -C "$rootfs" -czf "$serve/rootfs.tar.gz" --numeric-owner --acls --xattrs \
	--xattrs-include='*' .
rootfs_sha=$(sha256sum "$serve/rootfs.tar.gz" | cut -d' ' -f1)
rootfs_bytes=$(stat -c %s "$serve/rootfs.tar.gz")
# A complete-but-non-Fedora archive for the "wrong distribution" refusal: the
# same root with only os-release changed, so the refusal comes from the Fedora
# identity gate rather than from a missing file.
cp -a "$rootfs" "$work/other-root"
sed -i 's/^ID=fedora$/ID=ubuntu/' "$work/other-root/etc/os-release"
tar -C "$work/other-root" -czf "$serve/rootfs-ubuntu.tar.gz" \
	--numeric-owner --acls --xattrs --xattrs-include='*' .
ubuntu_sha=$(sha256sum "$serve/rootfs-ubuntu.tar.gz" | cut -d' ' -f1)
ubuntu_bytes=$(stat -c %s "$serve/rootfs-ubuntu.tar.gz")

# Privileged-file expectations derived from the fixture tree exactly like
# scripts/build-image.sh derives them from the real assembled rootfs: every
# setuid/setgid file plus every security.capability xattr.  Nothing is
# hardcoded (in particular there is no "ping must have a cap" entry).
write_privileges() { # valid|missing-cap
	{
		printf '%s\n' '# fixture privileged-file expectations (derived from the tree)'
		find "$rootfs" -type f \( -perm -4000 -o -perm -2000 \) -printf '%p\t%m\n' |
			while IFS="$(printf '\t')" read -r path mode; do
				rel=${path#"$rootfs"}
				if [ "$((0$mode & 04000))" -ne 0 ]; then kind=setuid; else kind=setgid; fi
				printf '%s %s %s\n' "$kind" "$mode" "$rel"
			done
		getcap -r "$rootfs" 2>/dev/null | while IFS= read -r line; do
			path=${line%% *}
			caps=${line#* }
			printf 'cap %s %s\n' "$caps" "${path#"$rootfs"}"
		done
	} >"$fixture/etc/liuqin-installer-privileges"
	if [ "$1" = missing-cap ]; then
		printf 'cap cap_net_admin=ep /usr/bin/kwin_wayland\n' \
			>>"$fixture/etc/liuqin-installer-privileges"
	fi
}
write_privileges valid

# The Fedora root admission contract v2 (ADR-0004 D2): topology only.  The
# "corrupt" variant stays structurally valid so it passes the pre-write format
# gate and is rejected by the post-extraction topology check (marker content).
write_contract() { # valid|corrupt
	marker_sha=$(sha256sum "$rootfs/etc/liuqin-fedora-root" | cut -d' ' -f1)
	[ "$1" = valid ] || marker_sha=$(head -c 64 /dev/zero | tr '\000' f)
	{
		printf '%s\n' 'LIUQIN_FEDORA_ROOT_CONTRACT_V2'
		printf '%s\n' '# install-root.sh execution-test fixture (real grammar, synthetic tree)'
		printf 'marker /etc/liuqin-fedora-root 0644 %s\n' "$marker_sha"
		printf '%s\n' 'file /usr/lib/systemd/system/plasmalogin.service'
		for executable in /usr/lib/systemd/systemd /usr/bin/plasmalogin /usr/bin/plasmashell \
			/usr/bin/kwin_wayland /usr/bin/startplasma-wayland /usr/libexec/kscreenlocker_greet; do
			printf 'exec %s\n' "$executable"
		done
		printf '%s\n' 'file /usr/share/liuqin/kernel.release'
		printf '%s\n' 'file /usr/share/liuqin/kernel-modules.manifest'
		printf '%s\n' 'resolve /usr/sbin/init systemd'
		printf '%s\n' 'resolve /etc/systemd/system/default.target graphical.target'
		printf '%s\n' 'display-manager plasmalogin.service'
	} >"$fixture/etc/liuqin-fedora-root.contract"
}
write_contract valid

# Rewrite only absolute fixture paths plus the two facilities the fixture
# replaces (blockdev state stub, regular files instead of block devices);
# every guard, message and status stays the shipped text.
script=$work/install-root.sh
sed "
	s|/sys/class/block|$fixture/sys|g
	s|/sys/class/power_supply|$fixture/sys/power_supply|g
	s|/proc/sys/kernel/random/uuid|$fixture/random-uuid|g
	s|/proc/sys/kernel/random/boot_id|$fixture/boot_id|g
	s|/usr/lib/liuqin/install-privileges.sh|$fixture/usr/lib/liuqin/install-privileges.sh|g
	s|/etc/liuqin-fedora-root.contract|$fixture/etc/liuqin-fedora-root.contract|g
	s|/etc/liuqin-installer|$fixture/etc/liuqin-installer|g
	s|/usr/lib/liuqin/provision.sh|$fixture/usr/lib/liuqin/provision.sh|g
	s|/run/persist|$fixture/run/persist|g
	s|/mnt/install-download|@MNTDL@|g
	s|/mnt/install-home|@MNTHOME@|g
	s|/mnt/install|@MNTINST@|g
	s|/dev/|$fixture/dev/|g
	s|/bin/busybox blockdev|$bin/blockdev|g
	s|\\[ -b |[ -e |g
	s|@MNTDL@|$fixture/mnt/install-download|g
	s|@MNTHOME@|$fixture/mnt/install-home|g
	s|@MNTINST@|$fixture/mnt/install|g
" "$project_root/installer/lib/install-root.sh" >"$script"
# Every occurrence of a rewritten absolute path must now carry the fixture
# prefix (a rewritten path still contains its original substring).
for original in '/sys/class/block' '/proc/sys/kernel/random/boot_id' '/dev/' \
	'/usr/lib/liuqin/provision.sh' '/usr/lib/liuqin/install-privileges.sh' \
	'/run/persist' '/mnt/install'; do
	remaining=$(grep -nF -- "$original" "$script" | grep -vF "$fixture" | head -1 || true)
	[ -z "$remaining" ] || fail "the fixture rewrite missed $original: $remaining"
done
for absent in '[ -b ' '/bin/busybox blockdev'; do
	! grep -qF -- "$absent" "$script" || fail "the fixture rewrite missed $absent; the script paths changed"
done
grep -qF "$fixture/dev/\${" "$script" || fail 'the /dev rewrite matched nothing'
grep -qF "$bin/blockdev" "$script" || fail 'the blockdev stub rewrite matched nothing'

# Local HTTP server standing in for the host that serves the bundle.
serve_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$serve_port" --bind 127.0.0.1 --directory "$serve" >"$work/http.log" 2>&1 &
server_pid=$!
ready=0
while [ "$ready" -lt 50 ]; do
	if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1',$serve_port),0.2); sys.exit(0)" 2>/dev/null; then
		break
	fi
	ready=$((ready + 1))
	sleep 0.1
done
[ "$ready" -lt 50 ] || fail 'the local HTTP server did not start'

run_install() { # [URL SHA BYTES] [extra installer options...]
	if [ "$#" -ge 3 ] && [ "${1#http}" != "$1" ]; then
		ri_url=$1
		ri_sha=$2
		ri_bytes=$3
		shift 3
	else
		ri_url="http://127.0.0.1:$serve_port/rootfs.tar.gz"
		ri_sha=$rootfs_sha
		ri_bytes=$rootfs_bytes
	fi
	ri_status=0
	env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
		"PATH=$bin:/usr/bin:/usr/sbin:/bin:/sbin" \
		sh "$script" "$(cat "$fixture/boot_id")" "$ri_url" "$ri_sha" "$ri_bytes" \
		ERASE-LIUQIN-USERDATA linux_root linux_home "$@" >"$work/output" 2>&1 || ri_status=$?
}
expect_ok() {
	[ "$ri_status" = 0 ] || fail "$1: expected success, got $ri_status: $(cat "$work/output")"
	pass "$1"
}
expect_die() { # NAME FRAGMENT
	[ "$ri_status" != 0 ] || fail "$1: expected a refusal, got success: $(cat "$work/output")"
	grep -qF -- "$2" "$work/output" || fail "$1: expected '$2', got: $(cat "$work/output")"
	pass "$1"
}
image_mount() { # IMAGE DIR [ro]
	mkdir -p "$2"
	if [ "${3:-}" = ro ]; then
		fuse2fs -o ro "$1" "$2" 2>/dev/null
	else
		fuse2fs "$1" "$2" >/dev/null 2>&1
	fi
}
image_unmount() { # DIR
	umount "$1" || fusermount3 -u "$1" || fail "cannot unmount $1"
}
assert_ro() { # NAME NODE
	[ "$(cat "$fixture/blockdev-state/$2")" = 1 ] || fail "$1: $2 was left writable"
}

# --- pre-write refusal: battery below 30 percent ---------------------------
printf '20\n' >"$fixture/sys/power_supply/BAT0/capacity"
run_install
expect_die 'low battery stops before any formatting' 'charge the tablet to at least 30 percent'
assert_ro 'low battery' sda36
printf '80\n' >"$fixture/sys/power_supply/BAT0/capacity"

# --- pre-write refusal: KEEP-HOME against a foreign home filesystem --------
mkfs.ext4 -q -F -L SOMETHING_ELSE "$work/home.img"
run_install KEEP-HOME
expect_die 'KEEP-HOME refuses a home that is not LIUQIN_HOME' 'does not hold the LIUQIN_HOME filesystem'
assert_ro 'KEEP-HOME refusal' sda36

# --- a complete installation ----------------------------------------------
run_install ENABLE-USB-RESCUE
expect_ok 'a complete Fedora root installation reports ROOT_INSTALLED'
grep -qF 'desktop user: liuqin' "$work/output" || fail 'the desktop user was not reported'
grep -qF 'liuqin-install: ROOT_INSTALLED' "$work/output" || fail 'ROOT_INSTALLED was not printed'
assert_ro 'after the install' sda36
assert_ro 'after the install' sda37
assert_ro 'after the install' sda

image_mount "$work/root.img" "$work/verify-root" ro
verify_root=$work/verify-root
[ ! -e "$verify_root/native-root" ] || fail 'the install is not FLAT (native-root/ exists)'
grep -qE '^UUID=[0-9a-f-]+[[:space:]]/home[[:space:]]ext4[[:space:]]' "$verify_root/etc/fstab" ||
	fail 'the installer did not write a UUID-based /home entry to /etc/fstab'
grep -q '^ID=fedora' "$verify_root/etc/os-release" || fail 'the Fedora root was not unpacked'
[ -L "$verify_root/etc/systemd/system/display-manager.service" ] ||
	fail 'the display-manager.service alias was not created'
case $(readlink "$verify_root/etc/systemd/system/display-manager.service") in
*/usr/lib/systemd/system/plasmalogin.service) ;;
*) fail 'the display manager is not plasmalogin' ;;
esac
[ -L "$verify_root/etc/systemd/system/default.target" ] ||
	fail 'default.target was not pointed at graphical.target'
case $(readlink "$verify_root/etc/systemd/system/default.target") in
*/usr/lib/systemd/system/graphical.target) ;;
*) fail 'default.target does not resolve to graphical.target' ;;
esac
[ -e "$verify_root/etc/liuqin-rescue-enabled" ] || fail 'ENABLE-USB-RESCUE did not write its marker'
[ "$(stat -c %s "$verify_root/etc/machine-id")" = 0 ] ||
	fail 'the build-host machine-id was not reset'
[ ! -e "$verify_root/var/lib/systemd/random-seed" ] || fail 'random-seed was not removed'
[ "$(stat -c %a "$verify_root/usr/bin/sudo")" = 4111 ] ||
	fail 'the setuid mode was not preserved by the extraction'
# Derived expectation list: kwin_wayland's capability must survive tar --xattrs...
case $(getcap "$verify_root/usr/bin/kwin_wayland") in
*cap_sys_nice=ep) ;;
*) fail 'the derived file capability (kwin_wayland cap_sys_nice=ep) was not preserved' ;;
esac
# ...and a real Fedora ping with no capability must NOT be required to have one.
[ "$(stat -c %a "$verify_root/usr/bin/ping")" = 755 ] ||
	fail 'the fixture ping mode changed'
[ -z "$(getcap "$verify_root/usr/bin/ping")" ] ||
	fail 'the fixture ping unexpectedly carries a capability'
[ "$(cat "$verify_root/var/lib/liuqin-private/wlan-mac")" = '02:00:00:00:00:01' ] ||
	fail 'the WLAN MAC was not provisioned from persist'
[ "$(cat "$verify_root/var/lib/liuqin-private/bluetooth-address")" = '02:00:00:00:00:02' ] ||
	fail 'the Bluetooth address was not provisioned from persist'
python3 - "$verify_root/usr/lib/firmware/cirrus" <<'PY' || fail 'the cirrus calibration was not provisioned'
import pathlib
import sys

base = pathlib.Path(sys.argv[1])
for index, channel in enumerate(('TL', 'TR', 'BL', 'BR')):
    data = (base / f'cs35l41-liuqin-{channel}-calr.bin').read_bytes()
    assert data == bytes(range(index * 4, index * 4 + 4)), (channel, data)
PY
[ "$(ls "$verify_root/var/lib/liuqin-sensors/registry" | grep -c '^item')" = 101 ] ||
	fail 'the sensor registry was not provisioned'
[ -f "$verify_root/var/lib/liuqin-sensors/registry/SHA256SUMS" ] ||
	fail 'the sensor registry has no SHA256SUMS'
[ "$(stat -c %u "$verify_root/var/lib/liuqin-sensors/registry")" = 1001 ] ||
	fail 'the sensor registry is not owned by the fastrpc account'
grep -qF 'liuqin-install: privileged metadata preserved' "$work/output" ||
	fail 'the derived privileged-file validation did not run'
grep -qF 'liuqin-install: admission contract v2 validated' "$work/output" ||
	fail 'the pre-write contract format validation did not run'
grep -qF 'liuqin-install: admission topology PASS' "$work/output" ||
	fail 'the post-extraction contract topology check did not pass'
image_unmount "$work/verify-root"

image_mount "$work/home.img" "$work/verify-home" ro
[ -f "$work/verify-home/liuqin/.profile" ] || fail 'the /home skeleton was not seeded'
image_unmount "$work/verify-home"

# --- post-write refusal: contract mismatch --------------------------------
write_contract corrupt
run_install
expect_die 'a root that fails the admission contract is rejected' 'marker content mismatch'
write_contract valid

# --- post-write refusal: a capability recorded at build time is missing -----
write_privileges missing-cap
run_install
expect_die 'a root with a missing file capability is rejected' \
	'file capabilities were not restored'
write_privileges valid

# --- post-write refusal: a non-Fedora root archive ------------------------
run_install http://127.0.0.1:"$serve_port"/rootfs-ubuntu.tar.gz "$ubuntu_sha" "$ubuntu_bytes"
expect_die 'a non-Fedora root archive is rejected' 'does not say ID=fedora'

# --- KEEP-HOME reinstall keeps the existing /home ------------------------
# Written after the two non-KEEP-HOME runs above, which reformat linux_home by
# design; this marker must survive the KEEP-HOME reinstall.
image_mount "$work/home.img" "$work/verify-home"
printf 'keep me\n' >"$work/verify-home/liuqin/kept-marker"
sync
image_unmount "$work/verify-home"
run_install KEEP-HOME
expect_ok 'a KEEP-HOME reinstall reports ROOT_INSTALLED'
grep -qF 'keeping existing /home' "$work/output" || fail 'KEEP-HOME did not report keeping /home'
image_mount "$work/home.img" "$work/verify-home" ro
[ -f "$work/verify-home/liuqin/kept-marker" ] || fail 'KEEP-HOME lost the existing home contents'
image_unmount "$work/verify-home"

# --- the RAM image guards on the real script -----------------------------
status=0
env -u http_proxy -u https_proxy "PATH=$bin:/usr/bin:/usr/sbin:/bin:/sbin" \
	sh "$script" "not-this-boot" "unused" "unused" "unused" \
	ERASE-LIUQIN-USERDATA linux_root linux_home >"$work/output" 2>&1 || status=$?
[ "$status" != 0 ] || fail 'a different boot_id was not refused'
grep -qF 'RAM boot identity changed' "$work/output" ||
	fail "a different boot_id was not refused: $(cat "$work/output")"
pass 'a different RAM boot_id is refused'
printf 'android\n' >"$fixture/etc/liuqin-installer"
status=0
env -u http_proxy -u https_proxy "PATH=$bin:/usr/bin:/usr/sbin:/bin:/sbin" \
	sh "$script" "$(cat "$fixture/boot_id")" "unused" "unused" "unused" \
	ERASE-LIUQIN-USERDATA linux_root linux_home >"$work/output" 2>&1 || status=$?
[ "$status" != 0 ] || fail 'a non-installer marker was not refused'
grep -qF 'not the installer RAM image' "$work/output" ||
	fail "a non-installer marker was not refused: $(cat "$work/output")"
pass 'a non-installer RAM image is refused'
printf 'liuqin\n' >"$fixture/etc/liuqin-installer"

printf '%s\n' 'liuqin install-root execution tests: PASS'
