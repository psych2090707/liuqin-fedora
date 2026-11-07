#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Offline summary, ordered by segment/boot/sequence, never wall-clock filenames."""
import argparse
import json
from pathlib import Path
import re
import uuid

from sample import LINE, segments


def summarize(directory, journal=None):
    boots, previous = {}, None
    malformed = 0
    for path in segments(Path(directory)):
        with path.open('rb') as stream:
            while raw := stream.readline(LINE + 1):
                try:
                    if len(raw) > LINE:
                        raise ValueError('oversized record')
                    row = json.loads(raw)
                    if row.get('schema') != 1:
                        raise ValueError('unknown schema')
                    boot, seq = row['boot_id'], row['seq']
                    if not isinstance(seq, int) or seq < 1:
                        raise ValueError('invalid sequence')
                    bt, mt = row['boottime_ns'], row['monotonic_ns']
                    if not isinstance(bt, int) or not isinstance(mt, int):
                        raise ValueError('invalid clocks')
                except (ValueError, KeyError, TypeError, AttributeError):
                    malformed += 1
                    continue
                group = boots.setdefault(boot, {'samples': 0, 'clock_suspend_ns': 0,
                                                'unknown_windows': 0, 'sequence_gaps': 0,
                                                'wall_clock_rollbacks': 0})
                group['samples'] += 1
                group.setdefault('first', row)
                group['last'] = row
                if previous and previous['boot_id'] == boot:
                    delta_bt = bt - previous['boottime_ns']
                    delta_mt = mt - previous['monotonic_ns']
                    if seq != previous['seq'] + 1:
                        group['sequence_gaps'] += 1
                    # Clock gaps estimate suspend time only, never AOSD or battery draw.
                    if delta_bt >= 0 and delta_mt >= 0 and delta_bt - delta_mt >= -1000000:
                        group['clock_suspend_ns'] += max(0, delta_bt - delta_mt)
                    else:
                        group['unknown_windows'] += 1
                    # Endpoints cannot prove an uninterrupted screen/charge state.
                    group['unknown_windows'] += 1
                    if row.get('realtime_ns', 0) < previous.get('realtime_ns', 0):
                        group['wall_clock_rollbacks'] += 1
                previous = row
    events, journal_bad, truncated = [], 0, False
    if journal:
        # Keep only fixed event labels/boot/time/unit, never original message contents.
        with Path(journal).open('rb') as stream:
            while raw := stream.readline(256 * 1024 + 1):
                try:
                    if len(raw) > 256 * 1024:
                        raise ValueError('oversized journal line')
                    event = json.loads(raw)
                    msg = event.get('MESSAGE', '')
                    if not isinstance(msg, str):
                        continue
                    kind = None
                    if 'PM: suspend entry' in msg:
                        kind = 'suspend_entry'
                    elif 'PM: suspend exit' in msg:
                        kind = 'suspend_exit'
                    elif re.search(r'remoteproc.*(fatal|crash|timeout)|watchdog|Kernel panic', msg, re.I):
                        kind = 'fault_hint'
                    elif event.get('MESSAGE_ID') == 'be02cf6855d2428ba40df7e9d022f03d':
                        kind = 'unit_failed'
                    if kind:
                        if len(events) >= 20000:
                            truncated = True
                            break
                        events.append({'boot_id': str(uuid.UUID(event['_BOOT_ID'])), 'kind': kind,
                                       'monotonic_us': event.get('_SOURCE_MONOTONIC_TIMESTAMP',
                                                                 event.get('__MONOTONIC_TIMESTAMP'))})
                except (ValueError, AttributeError, KeyError, TypeError):
                    journal_bad += 1
    # Per-boot input order matters; do not pair different boots or duplicate entries.
    paired, pending, unpaired = {}, {}, {}
    for event in events:
        boot = event['boot_id']
        if event['kind'] == 'suspend_entry':
            if pending.get(boot):
                unpaired[boot] = unpaired.get(boot, 0) + 1
            pending[boot] = True
        elif event['kind'] == 'suspend_exit':
            if pending.pop(boot, False):
                paired[boot] = paired.get(boot, 0) + 1
            else:
                unpaired[boot] = unpaired.get(boot, 0) + 1
    for boot in pending:
        unpaired[boot] = unpaired.get(boot, 0) + 1
    return {'schema': 1, 'boots': boots, 'malformed_sample_lines': malformed,
            'events': events, 'journal_malformed_lines': journal_bad,
            'events_truncated': truncated, 'journal_pm_pairs': paired,
            'journal_pm_unpaired': unpaired,
            'limits': 'Endpoints and clock gaps do not identify deep state, crash cause, '
                      'screen-state continuity or calibrated battery life. Compare raw power units; '
                      'do not compare small changes before observing gauge resolution.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--journal-json', type=Path)
    parser.add_argument('--output', type=Path, help='exclusive create, at most 16 MiB')
    args = parser.parse_args()
    raw = json.dumps(summarize(args.directory, args.journal_json), indent=2) + '\n'
    if len(raw.encode()) > 16 * 1024 * 1024:
        raise SystemExit('summary exceeds 16 MiB; select fewer boots')
    if args.output:
        import os
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write(raw)
    else:
        print(raw, end='')


if __name__ == '__main__':
    main()
