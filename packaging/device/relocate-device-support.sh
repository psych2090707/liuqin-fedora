#!/bin/sh
# SPDX-License-Identifier: MIT
#
# relocate-device-support.sh — stage the distro-neutral liuqin device layer
# into a Fedora FHS buildroot.
#
# Upstream (yzddmr6/xiaomipad-6pro-mainline, v0.6.0) installs its helpers under
# /usr/local/... because the Ubuntu image treats them as local additions.
# Fedora packages must not write /usr/local (rpmlint/guidelines), so this
# script relocates them and rewrites every in-tree reference.  It never edits
# the upstream checkout: the tree it reads was extracted from a staging
# tarball, and every rewrite below is listed explicitly for auditability.
#
# Inputs:
#   --tree DIR        extracted upstream device/ subset (gnome-overlay etc.)
#   --root DIR        %{buildroot}
#   --power-keyd BIN  prebuilt static aarch64 liuqin-power-keyd
#   --reboot BIN      prebuilt static aarch64 liuqin-reboot
#   --action FILE     Fedora/KDE liuqin-power-key-action replacement
#   --chrony-dir DIR  destination directory for the no-RTC chrony drop-in
#
# Relocation map (upstream -> Fedora):
#   etc/systemd/system/...              -> /usr/lib/systemd/system/...
#   etc/systemd/logind.conf.d/...       -> /usr/lib/systemd/logind.conf.d/...
#   etc/udev/rules.d/...                -> /usr/lib/udev/rules.d/...
#   etc/modprobe.d/...                  -> /usr/lib/modprobe.d/...
#   etc/chrony/conf.d/90-...            -> ${chrony-dir}/00-liuqin-no-rtc.conf
#   usr/share/polkit-1/actions/...      -> /usr/share/polkit-1/actions/...
#   usr/local/share/applications/...    -> /usr/share/applications/...
#   usr/local/libexec/<x>               -> /usr/libexec/liuqin/<x>
#   usr/local/sbin/<x>                  -> /usr/libexec/liuqin/<x>
#   usr/local/bin/<x>                   -> /usr/libexec/liuqin/<x>
#
# Rewrites applied to staged text files:
#   /usr/local/libexec/ -> /usr/libexec/liuqin/
#   /usr/local/sbin/    -> /usr/libexec/liuqin/
#   /usr/local/bin/     -> /usr/libexec/liuqin/
#
# Deliberately excluded (GNOME/Ubuntu-specific; see docs/maintenance/device-packages.md):
#   dconf/gdm profiles, gnome-storage-guard, gnome-usb-rescue, snap admission,
#   Snapshot desktop/dbus entries, liuqin-shell, liuqin-camera, liuqin-rescue,
#   power-menu (zenity/GNOME), flash-kernel marker, environment.d dmabuf.
set -eu

tree=
root=
power_keyd=
reboot=
action=
chrony_dir=/etc/chrony.d

die() { printf 'relocate-device-support: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--tree) tree=$2; shift 2 ;;
	--root) root=$2; shift 2 ;;
	--power-keyd) power_keyd=$2; shift 2 ;;
	--reboot) reboot=$2; shift 2 ;;
	--action) action=$2; shift 2 ;;
	--chrony-dir) chrony_dir=$2; shift 2 ;;
	*) die "unknown argument: $1" ;;
	esac
done

for v in tree root power_keyd reboot action; do
	eval "value=\${$v}"
	[ -n "$value" ] || die "missing --$v"
done
[ -d "$tree" ] || die "tree is not a directory: $tree"
[ -d "$root" ] || die "buildroot is not a directory: $root"
[ -f "$power_keyd" ] || die "prebuilt power-keyd missing: $power_keyd"
[ -f "$reboot" ] || die "prebuilt reboot helper missing: $reboot"
[ -f "$action" ] || die "KDE action helper missing: $action"

overlay=$tree/device/gnome-overlay
[ -d "$overlay" ] || die "upstream overlay not found under $tree"

install_dir() { # <mode> <source> <destination>
	install -D -m "$1" "$2" "$3"
}

# --- systemd units -----------------------------------------------------------
for unit in \
	liuqin-power-keyd.service \
	liuqin-power-keyd.service.d/20-liuqin-session-runtime.conf \
	liuqin-backlight-default.service \
	liuqin-bt-preconfigure.service \
	liuqin-wlan-mac.service \
	liuqin-mipps-auth.service \
	liuqin-mipps-auth.service.d/10-allow-unverified-adapter.conf \
	liuqin-hide-gunyah-node.service \
	bluetooth.service.d/20-liuqin-public-address.conf \
	NetworkManager.service.d/20-liuqin-wlan-mac.conf; do
	install_dir 0644 "$overlay/etc/systemd/system/$unit" "$root/usr/lib/systemd/system/$unit"
done
install_dir 0644 "$overlay/etc/systemd/logind.conf.d/90-liuqin.conf" \
	"$root/usr/lib/systemd/logind.conf.d/90-liuqin.conf"

# --- udev / modprobe / polkit / desktop entry --------------------------------
for rule in \
	70-liuqin-camera-heap.rules \
	70-liuqin-touchpad-external.rules \
	90-liuqin-mipps-auth.rules; do
	install_dir 0644 "$overlay/etc/udev/rules.d/$rule" "$root/usr/lib/udev/rules.d/$rule"
done
install_dir 0644 "$overlay/etc/modprobe.d/liuqin-camera.conf" \
	"$root/usr/lib/modprobe.d/liuqin-camera.conf"
install_dir 0644 "$overlay/usr/share/polkit-1/actions/io.github.liuqin.switch.policy" \
	"$root/usr/share/polkit-1/actions/io.github.liuqin.switch.policy"
install_dir 0644 "$overlay/usr/local/share/applications/liuqin-reboot-to-android.desktop" \
	"$root/usr/share/applications/liuqin-reboot-to-android.desktop"

# --- helper scripts (renamed verbatim first, rewritten below) ----------------
for script in liuqin-mipps-auth liuqin-backlight-default; do
	install_dir 0755 "$overlay/usr/local/libexec/$script" "$root/usr/libexec/liuqin/$script"
done
for script in liuqin-wlan-mac liuqin-bt-public-addr liuqin-switch; do
	install_dir 0755 "$overlay/usr/local/sbin/$script" "$root/usr/libexec/liuqin/$script"
done

# --- prebuilt aarch64 helpers and the Fedora/KDE power-key action ------------
install_dir 0755 "$power_keyd" "$root/usr/libexec/liuqin/liuqin-power-keyd"
install_dir 0755 "$reboot" "$root/usr/libexec/liuqin/liuqin-reboot"
install_dir 0755 "$action" "$root/usr/libexec/liuqin/liuqin-power-key-action"

# --- chrony no-RTC bootstrap -------------------------------------------------
# Fedora's /etc/chrony.conf has no confdir/include drop-in mechanism, so the
# package ships an aggregate config: it includes the distribution file first
# (so Fedora's pool/sourcedir/driftfile stay authoritative) and then applies
# the upstream liuqin no-RTC directives.  A chronyd.service drop-in switches
# the daemon to that aggregate with the same -n option as the Fedora unit.
chrony_src=$overlay/etc/chrony/conf.d/90-liuqin-no-rtc-bootstrap.conf
chrony_out=$root$chrony_dir/00-liuqin-no-rtc.conf
mkdir -p "$root$chrony_dir"
{
	printf '%s\n' \
		'# Generated by liuqin-device-support from the upstream no-RTC bootstrap' \
		'# drop-in.  Fedora reads a single config file, so this file includes the' \
		'# distribution configuration first and then appends the liuqin directives.' \
		'include /etc/chrony.conf'
	printf '\n'
	cat "$chrony_src"
} >"$chrony_out"
chmod 0644 "$chrony_out"
mkdir -p "$root/usr/lib/systemd/system/chronyd.service.d"
cat >"$root/usr/lib/systemd/system/chronyd.service.d/20-liuqin-no-rtc.conf" <<'DROPIN'
[Service]
# Fedora's chronyd reads exactly one config file; use the liuqin aggregate
# (distribution config + no-RTC bootstrap directives) with the same -n that
# the distribution unit uses.
ExecStart=
ExecStart=/usr/sbin/chronyd -n -f /etc/chrony.d/00-liuqin-no-rtc.conf
DROPIN
chmod 0644 "$root/usr/lib/systemd/system/chronyd.service.d/20-liuqin-no-rtc.conf"

# --- rewrite upstream /usr/local references ----------------------------------
# Every staged text file goes through the same three substitutions; the
# assertion at the end proves no /usr/local path survived.
for text in \
	"$root"/usr/lib/systemd/system/liuqin-*.service \
	"$root"/usr/lib/systemd/system/liuqin-*.service.d/*.conf \
	"$root"/usr/lib/systemd/system/bluetooth.service.d/*.conf \
	"$root"/usr/lib/systemd/system/NetworkManager.service.d/*.conf \
	"$root"/usr/lib/systemd/logind.conf.d/*.conf \
	"$root"/usr/lib/udev/rules.d/*-liuqin-*.rules \
	"$root"/usr/lib/modprobe.d/liuqin-*.conf \
	"$root"/usr/share/polkit-1/actions/io.github.liuqin.*.policy \
	"$root"/usr/share/applications/liuqin-*.desktop \
	"$root"/usr/libexec/liuqin/liuqin-mipps-auth \
	"$root"/usr/libexec/liuqin/liuqin-backlight-default \
	"$root"/usr/libexec/liuqin/liuqin-wlan-mac \
	"$root"/usr/libexec/liuqin/liuqin-bt-public-addr \
	"$root"/usr/libexec/liuqin/liuqin-switch \
	"$root"/usr/libexec/liuqin/liuqin-power-key-action; do
	[ -f "$text" ] || die "staged file disappeared: $text"
	sed -i \
		-e 's|/usr/local/libexec/|/usr/libexec/liuqin/|g' \
		-e 's|/usr/local/sbin/|/usr/libexec/liuqin/|g' \
		-e 's|/usr/local/bin/|/usr/libexec/liuqin/|g' \
		"$text"
done

# --- assertions --------------------------------------------------------------
if grep -rIl '/usr/local/' "$root" >/dev/null 2>&1; then
	echo 'relocate-device-support: /usr/local reference survived relocation:' >&2
	grep -rIl '/usr/local/' "$root" >&2
	exit 1
fi
# No GNOME/Ubuntu payload may be present.
for forbidden in \
	"$root/usr/share/gnome" \
	"$root/etc/dconf" \
	"$root/etc/gdm3" \
	"$root/usr/share/gdm" \
	"$root/etc/flash-kernel" \
	"$root/usr/share/liuqin/power" \
	"$root/usr/libexec/liuqin/liuqin-power-menu" \
	"$root/usr/libexec/liuqin/liuqin-shell"; do
	[ ! -e "$forbidden" ] || die "GNOME/Ubuntu-specific path leaked into package: $forbidden"
done
# The Fedora/KDE action helper must be the one we ship, not upstream's GNOME
# implementation (upstream version is 200+ lines and talks to Mutter).
grep -q 'Fedora/KDE replacement' "$root/usr/libexec/liuqin/liuqin-power-key-action" ||
	die 'power-key-action is not the Fedora/KDE replacement'
# The dual-boot switcher must invoke the relocated path through pkexec.
grep -qx 'Exec=pkexec /usr/libexec/liuqin/liuqin-switch to-android' \
	"$root/usr/share/applications/liuqin-reboot-to-android.desktop" ||
	die 'desktop entry does not use the relocated liuqin-switch'
grep -q 'org.freedesktop.policykit.exec.path\">/usr/libexec/liuqin/liuqin-switch<' \
	"$root/usr/share/polkit-1/actions/io.github.liuqin.switch.policy" ||
	die 'polkit action does not use the relocated liuqin-switch'

printf 'relocate-device-support: staged %s files under %s\n' \
	"$(find "$root" -type f | wc -l)" "$root"
