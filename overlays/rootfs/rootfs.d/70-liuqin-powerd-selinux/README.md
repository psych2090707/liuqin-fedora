# 70-liuqin-powerd-selinux — keep the state-file writes out of the audit log

`liuqin-powerd` writes a small diagnostic state file at
`/run/liuqin-powerd/power-state.json` (see
[`rust/README.md`](../../../../rust/README.md)).  On the current F45 bring-up the
policy loads late enough that PID 1 runs as `kernel_t`, so a system service
launched from `/usr/local/libexec/` gets `kernel_generic_helper_t`.  That
domain may not write `var_run_t`, so every state-file write was recorded as an
AVC even though SELinux is permissive.

That was harmless while the daemon wrote on changes only.  The 2026-11-08
regression made it write ten times per second (a timestamp in the dedupe key),
which produced about 70 AVC records per second, kept `setroubleshootd` at a full
CPU core and grew the journal to 1.3 GB.  The code fix removes the 10 Hz rewrite
and a one-minute heartbeat remains.  This module stops the remaining heartbeat
records by giving `/run/liuqin-powerd` its own type and allowing exactly the
two service domains that may own it.

- `install.sh` — carries the minimal type + allow rules inline (the image
  builder copies only this script into the chroot), builds and installs the
  module and the file-context rule.

The module is optional for correctness: without it the daemon still works and
only logs a few AVCs per minute in permissive mode.  The install script warns
and skips if `checkmodule`/`semodule`/`semanage` are not available in the image.

If SELinux is ever switched to enforcing, keep this module (or the state
directory writable by the actual service domain); otherwise the state file
cannot be updated.  Test with `restorecon -Rv /run/liuqin-powerd` and a service
restart before enabling enforcement.
