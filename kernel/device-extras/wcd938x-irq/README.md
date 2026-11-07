# WCD938x RX alert: preserve codec IRQ dispatch without NULL regmap access

Local fix for the 2026-11-03 overnight failure investigation. It remains
outside the default patch series. After bounded RAM audio/sleep checks, the
user authorized deployment to B; the full partition readback and a normal
boot were verified on 2026-11-03. Overnight reliability remains unverified.
Current build/test state belongs to the existing task result.

The matching failed-boot trace has `regmap_read(NULL, ...)` called from
`wcd9380_interrupt_callback`, then the SoundWire IRQ thread exits. The driver
creates a register map only for TX, but registers the same alert callback
for RX and TX. Both peripherals use the shared codec IRQ domain initialized
by `wcd938x_bind()`.

The patch keeps `handle_nested_irq()` for both peripherals and returns after
that dispatch if the local regmap is absent. TX retains its original CSR
status-drain loop. RX control-port acknowledgement and rechecking stay in
the SoundWire core after the callback returns. It changes no interrupt mask,
runtime PM operation, system-sleep operation, DTB or driver interface.

This is a locally authored fix, not an upstream backport. The current
[upstream common callback](https://github.com/torvalds/linux/blob/master/sound/soc/codecs/wcd-common.c)
still reads the peripheral's local regmap, so the common-code refactor alone
is not sufficient for this observed NULL access. The
[SoundWire core](https://github.com/torvalds/linux/blob/v6.17/drivers/soundwire/bus.c)
shows the callback, peripheral mutex, acknowledgement and bounded alert loop.
The exact matching local source was also checked; no directly applicable
published fix was identified during the targeted search.

The callback runs with `sdw_dev_lock` held. Its abnormal thread exit bypasses
the unlock and PM reference release in the core. This is a plausible path
to later stalls, but no captured stack proves that it caused the overnight
loss of responsiveness. Fixing this NULL access is not acceptance of sleep
reliability or battery life.

Run the actual callback with mocked IO in
[the regression check](../../../tests/audio-driver/test-wcd938x-irq.py):

```sh
python3 -B tests/audio-driver/test-wcd938x-irq.py \
  --source /tmp/liuqin-wcd938x-irq/src/sound/soc/codecs/wcd938x-sdw.c
```

The original source with `--expect-vulnerable` must reach the invalid-access
sentinel on RX. The candidate must forward RX once without reading a regmap;
TX with cleared/pending status must retain one/two dispatches and three/six
status reads. The harness extracts the real callback instead of copying its
logic. It does not emulate SoundWire hardware or exercise a real interrupt.

Remove this patch when an equivalent upstream repair is integrated and
validated on the tablet. Keep it separate from unrelated audio PM changes
and do not promote it to the default queue before bounded hardware checks.
