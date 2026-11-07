# `ipcc-suspend` — mask the IPCC summary IRQ across deep sleep

**Candidate only. Not in the default series.** It is deployed to B as of
2026-11-02 after RAM tests passed 20.6-minute and 44.85-minute natural deep
sleeps with no IPCC early wake; four battery notifications arrived during
the second sleep without waking it. After the first overnight observation,
the tablet was unresponsive and the user recovered it with a long power-key
press on 2026-11-03. A pre-suspend SoundWire Oops and incomplete sleep record
were preserved; causality is unproven and overnight validation has not passed.
See the task result for evidence and the stop condition.

`0001-mailbox-qcom-ipcc-remove-IRQF-NO-SUSPEND.patch` removes
`IRQF_NO_SUSPEND` from the IPCC summary IRQ. The ADSP charger service can then
no longer pull the AP out of `deep` by ringing the mailbox for a battery
notification.

Source: [ROCKNIX PR #3115](https://github.com/ROCKNIX/distribution/pull/3115),
the same one-line change already carried for SM8750 and merged for SM8550.
The local patch text is unchanged apart from the baseline/context note.

## Why it matches this device

On the archived 2026-11-02 audio+GENI build, every natural early return
(16 events) has the same first dispatch:

```text
GIC 261 ipcc_0 -> IPCC client 3 / signal 0 -> GLINK opcode 0x7
-> notification 0x80 (BATTMGR_NOTIFICATION) -> qcom-battmgr-bat event+1
```

Controlled RTC wakes in the same archive instead show `pm8xxx_rtc_alarm`
and no battery event, so the correlation is not a generic resume artifact.
See the task result.

## Scope and known risk

Removing the flag masks **all** IPCC clients during system suspend, not only
the charger service. Pending doorbells are handled after resume. This is
acceptable for a bounded RAM test on this tablet, but it is broader than a
battery-client-only filter. Watch for:

- suspend entry failure / `PM: Some devices failed to suspend`;
- charger or USB-C state not updating after resume;
- power-key or lid wake regression (both use non-IPCC IRQs);
- display, touch, audio or Wi-Fi not recovering.

The candidate is now also the on-disk B kernel, so a normal reboot does not
remove it. A remains the retained fallback; switching slots requires explicit
authorization. Do not repeat the failed overnight condition or add this patch
to `project-patches/series` while recovery reliability remains unresolved.
