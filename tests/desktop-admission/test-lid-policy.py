#!/usr/bin/env python3
"""Exercise the lid/re-suspend state machine without D-Bus or devices."""
import runpy
from pathlib import Path
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
POLICY = PROJECT / 'overlays/gnome-local/power/usr/local/libexec/liuqin-lid-policy'

module = runpy.run_path(str(POLICY))
Policy = module['Policy']

T = 1_000_000


def check(label, condition):
    assert condition, label
    print('PASS:', label)


def closed_resume(resuspend=False):
    policy = Policy(T, 'blank', resuspend)
    policy.initial(False, True, T)
    policy.lid_changed(True, T)
    policy.prepare_sleep(True, T + 1000)
    return policy, policy.prepare_sleep(False, T + 2000)


policy, actions = closed_resume()
check('lid close blanks through an explicit action', actions == ['ensure-off'])
check('closed-lid display change schedules one fix',
      policy.display_changed(0, T + 5000) == [] and policy.next_deadline() == T + 5000)
check('scheduled fix re-blanks once', policy.tick(T + 5000) == ['ensure-off'])
check('lid open wakes and stops display fixes',
      policy.lid_changed(False, T + 6000) == ['ensure-on']
      and not policy.protected
      and policy.display_changed(0, T + 7000) == []
      and policy.next_deadline() is None)

policy, actions = closed_resume()
check('resume with the lid closed blanks immediately', actions == ['ensure-off']
      and policy.protected)
check('resume schedules a confirmation fix', policy.next_deadline() == T + 5000)
check('display change does not pull the confirmation fix earlier',
      policy.display_changed(0, T + 2500) == [] and policy.next_deadline() == T + 5000)
check('opening the lid cancels the confirmation fix before it runs',
      policy.lid_changed(False, T + 3000) == ['ensure-on']
      and policy.tick(T + 5000) == [])
check('automatic re-suspend is off by default', policy.resuspend_at is None)

policy, actions = closed_resume(resuspend=True)
check('resume starts the 20 s re-suspend window', policy.resuspend_at == T + 22000)
check('confirmation fix keeps its own deadline', policy.tick(T + 5000) == ['ensure-off'])
check('window does not fire early', policy.tick(T + 21999) == [])
check('window fires once', policy.tick(T + 22000) == ['resuspend-check'])
policy.note_resuspend_issued(T + 22000)
check('one automatic suspend per resume cycle', policy.next_deadline() is None)

policy, _ = closed_resume(resuspend=True)
policy.user_input(T + 5000)
check('user input cancels re-suspend', policy.resuspend_at is None)
check('no display fix is resurrected by a cancelled window',
      policy.tick(T + 22000) == ['ensure-off'] and policy.next_deadline() is None)

policy, _ = closed_resume(resuspend=True)
policy.lid_changed(False, T + 5000)
check('lid open cancels re-suspend and wakes', policy.resuspend_at is None
      and policy.next_deadline() is None)

policy, _ = closed_resume(resuspend=True)
policy.power_source(False, T + 5000)
check('AC power cancels re-suspend',
      policy.resuspend_at is None and policy.tick(T + 22000) == ['ensure-off'])

policy, _ = closed_resume(resuspend=True)
policy.user_key(T + 4000)
check('power key cancels protection and re-suspend',
      not policy.protected and policy.resuspend_at is None)
check('power key owns the display until the next lid cycle',
      policy.display_changed(0, T + 5000) == [] and policy.next_deadline() is None)

policy, _ = closed_resume(resuspend=True)
for attempt in range(3):
    start = T + 10000 + attempt * 40000
    policy.note_resuspend_issued(start)
    policy.prepare_sleep(True, start + 1000)
    policy.prepare_sleep(False, start + 2000)
check('three quick resumes stop automatic re-suspend',
      policy.stopped and policy.resuspend_at is None)
policy.lid_changed(False, T + 200000)
policy.lid_changed(True, T + 201000)
check('the next lid cycle clears the stop', not policy.stopped
      and policy.resuspend_at is None)

policy, _ = closed_resume()
for failure in range(3):
    at = T + 5000 + failure * 1000
    check(f'helper failure {failure + 1} still requests the display fix',
          policy.tick(at) == ['ensure-off'])
    policy.note_fix_result(False, at)
check('three helper failures pause display protection',
      policy.fix_disabled and policy.next_deadline() is None)

policy = Policy(T, 'blank', False)
policy.initial(False, True, T)
policy.prepare_sleep(True, T + 1000)
actions = policy.prepare_sleep(False, T + 2000)
check('resume with the lid open does not blank',
      actions == [] and not policy.protected)

policy = Policy(T, 'blank', False)
policy.initial(True, True, T)
check('startup with a closed lid applies the protection', policy.protected)
policy = Policy(T, 'blank', False)
policy.user_override = True
check('startup after a power-key peek does not re-blank',
      policy.initial(True, True, T) == [] and not policy.protected)

policy = Policy(T, 'nothing', False)
check('LID_ACTION=nothing does not touch the display',
      policy.lid_changed(True, T) == [] and policy.lid_changed(False, T + 1) == [])

policy = Policy(T, 'suspend', False)
check('LID_ACTION=suspend keeps its suspend/wake behaviour',
      policy.lid_changed(True, T) == ['suspend']
      and policy.lid_changed(False, T + 1) == ['ensure-on'])

# Phase 2: LID_RESUSPEND must also work for LID_ACTION=suspend, and a resume
# with the lid closed must protect the display even when the action is suspend.
policy = Policy(T, 'suspend', True)
policy.initial(False, True, T)
policy.lid_changed(True, T)
policy.prepare_sleep(True, T + 1000)
actions = policy.prepare_sleep(False, T + 2000)
check('suspend action protects the closed-lid display on resume',
      actions == ['ensure-off'] and policy.protected)
check('suspend action starts the closed-lid re-suspend window',
      policy.resuspend_at == T + 22000)
check('suspend action retry is counted', policy.retry_count == 0)
policy.note_resuspend_issued(T + 22000)
check('issuing the retry increments the counter', policy.retry_count == 1)

policy = Policy(T, 'suspend', False)
policy.initial(False, True, T)
policy.lid_changed(True, T)
policy.prepare_sleep(True, T + 1000)
actions = policy.prepare_sleep(False, T + 2000)
check('suspend action without LID_RESUSPEND still protects the display',
      actions == ['ensure-off'] and policy.protected
      and policy.resuspend_at is None)

policy = Policy(T, 'nothing', True)
policy.initial(False, True, T)
policy.lid_changed(True, T)
policy.prepare_sleep(True, T + 1000)
actions = policy.prepare_sleep(False, T + 2000)
check('LID_ACTION=nothing never auto-resuspends',
      actions == [] and not policy.protected and policy.resuspend_at is None)

# Duplicate lid events must not reset an active cycle or re-queue an action.
policy = Policy(T, 'blank', False)
policy.initial(False, True, T)
check('first lid close blanks', policy.lid_changed(True, T) == ['ensure-off'])
check('duplicate lid close is ignored', policy.lid_changed(True, T + 1) == [])

# A spurious short wake with the lid open gets exactly one bounded retry.
policy = Policy(T, 'suspend', True)
policy.initial(False, True, T)
policy.prepare_sleep(True, T + 1000)
policy.prepare_sleep(False, T + 2000)
check('abnormal short open-lid wake starts a 10 s retry',
      policy.note_abnormal_short_wake(T + 2000)
      and policy.resuspend_at == T + 12000
      and policy.allow_open_lid_resuspend)
policy.user_input(T + 3000)
check('user input cancels the open-lid retry',
      policy.resuspend_at is None and not policy.allow_open_lid_resuspend)

policy = Policy(T, 'suspend', True)
policy.initial(False, True, T)
policy.prepare_sleep(True, T + 1000)
policy.prepare_sleep(False, T + 20000)
check('a long sleep with the lid open returns to normal idle policy',
      not policy.note_abnormal_short_wake(T + 20000)
      and policy.resuspend_at is None)

policy = Policy(T, 'nothing', True)
policy.initial(False, True, T)
policy.prepare_sleep(True, T + 1000)
policy.prepare_sleep(False, T + 2000)
check('LID_ACTION=nothing does not retry an open-lid short wake',
      not policy.note_abnormal_short_wake(T + 2000)
      and policy.resuspend_at is None)

policy = Policy(T, 'blank', False)
check('initial state with an open lid does nothing', policy.initial(False, True, T) == [])


class Clock:
    """Linux suspend advances boottime while CLOCK_MONOTONIC stands still."""

    def __init__(self):
        self.boot_ms = T
        self.awake_ms = T

    def advance(self, milliseconds, sleeping=False):
        self.boot_ms += milliseconds
        if not sleeping:
            self.awake_ms += milliseconds

    def read(self, clock_id):
        assert clock_id == module['time'].CLOCK_BOOTTIME
        return self.boot_ms * 1_000_000


clock = Clock()
with patch.object(module['time'], 'clock_gettime_ns', side_effect=clock.read), \
     patch.object(module['time'], 'monotonic_ns', side_effect=lambda: clock.awake_ms * 1_000_000):
    now = module['now_ms']
    policy = Policy(now(), 'blank', True)
    policy.initial(True, True, now())
    # Three real 7.5 minute sleeps, with only ~5 s awake during each
    # suspend transition. Old now_ms() counts those as three quick returns.
    for sleep_ms in (455285, 454650, 454669):
        policy.note_resuspend_issued(now())
        clock.advance(1000)
        policy.prepare_sleep(True, now())
        clock.advance(sleep_ms, sleeping=True)
        clock.advance(4000)
        policy.prepare_sleep(False, now())
        check('multi-minute sleep keeps the next re-suspend window',
              not policy.stopped and policy.resuspend_at == now() + 20000)
        clock.advance(20000)
        check('re-suspend remains possible after the overnight wake pattern',
              'resuspend-check' in policy.tick(now()))

    # Retain the safety stop for a genuine rapid suspend/resume loop, through
    # the same clock path used by the service.
    policy = Policy(now(), 'blank', True)
    policy.initial(True, True, now())
    for _ in range(3):
        policy.note_resuspend_issued(now())
        policy.prepare_sleep(True, now())
        clock.advance(1000, sleeping=True)
        policy.prepare_sleep(False, now())
        clock.advance(20000)
    check('three genuinely quick returns still stop re-suspend with boottime',
          policy.stopped and policy.resuspend_at is None)
