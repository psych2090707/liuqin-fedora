// SPDX-License-Identifier: MIT
/* Make the two charger-mode exits explicit; never request system shutdown. */
/* Upstream: xiaomipad-6pro-mainline commit
 * f5a535f5c1c980f042b58cb77467ff8f02a5518e device/charger-mode/liuqin-charger-mode-exit.c
 * (MIT).  Copied verbatim: build-runtime.py compiles it into the static
 * usr/sbin/liuqin-reboot helper the RAM installer runs. */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	const char *reason;

	if (argc != 2 || (strcmp(argv[1], "normal") && strcmp(argv[1], "bootloader"))) {
		fprintf(stderr, "usage: %s normal|bootloader\n", argv[0]);
		return 64;
	}
	if (geteuid() != 0) {
		fprintf(stderr, "liuqin-charger-mode-exit: root is required\n");
		return 2;
	}
	reason = argv[1];
	sync();
	if (syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		    LINUX_REBOOT_CMD_RESTART2, reason) < 0) {
		fprintf(stderr, "liuqin-charger-mode-exit: %s reboot failed: %s\n",
			reason, strerror(errno));
		return 1;
	}
	return 0;
}
