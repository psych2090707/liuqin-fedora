/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Offline probe for the liuqin FPC1264 TOD stack.
 *
 * Creates an FpContext exactly like fprintd does, enumerates fingerprint
 * devices and prints what was found. It is run by
 * verify-libfprint-tod.sh inside a throwaway arm64 container with:
 *
 *   FP_TOD_DRIVERS_DIR=<dir containing libfprint-tod-fpc1264-oem.so>
 *   FP_DRIVERS_ALLOWLIST=fpc1264_oem
 *   FP_LIUQIN_FPC1264_OEM_ENABLE=1
 *   LD_LIBRARY_PATH=<private TOD libfprint dir>
 *
 * A fake char device is bind-mounted at /dev/fpc1020 so the adapter's probe
 * (lstat + S_ISCHR) succeeds. THIS IS NOT A HARDWARE TEST: it only proves the
 * TOD driver discovery + adapter loading + virtual device plumbing work with
 * the rebuilt packages. Real enrollment/unlock stays pending-device.
 */
#include <glib.h>
#include <stdio.h>

#include <fprint.h>

int
main (void)
{
  g_autoptr (FpContext) ctx = NULL;
  GPtrArray *devices = NULL;
  guint i;

  ctx = fp_context_new ();
  if (ctx == NULL)
    {
      fprintf (stderr, "PROBE_ERROR=no-context\n");
      return 2;
    }

  /* Blocks and iterates the main loop until enumeration is complete. */
  fp_context_enumerate (ctx);
  devices = fp_context_get_devices (ctx);

  printf ("PROBE_DEVICE_COUNT=%u\n", devices ? devices->len : 0);
  for (i = 0; devices != NULL && i < devices->len; i++)
    {
      FpDevice *dev = g_ptr_array_index (devices, i);

      printf ("PROBE_DEVICE_INDEX=%u DRIVER=%s NAME=%s DEVICE_ID=%s\n",
              i,
              fp_device_get_driver (dev),
              fp_device_get_name (dev),
              fp_device_get_device_id (dev));
    }

  return devices != NULL && devices->len == 1 ? 0 : 1;
}
