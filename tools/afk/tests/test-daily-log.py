#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Regression coverage for evidence retention and chronology, using synthetic data."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'daily-log'
sys.path.insert(0, str(SOURCE))
import sample
from summarize import summarize

A = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
B = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'


def row(boot=A, clock=100, wall=100):
    return {'schema': 1, 'boot_id': boot, 'boottime_ns': clock,
            'monotonic_ns': clock, 'realtime_ns': wall,
            'power_supply_raw': {'battery': {'capacity': '42'}}}


class Storage(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.identity = patch.object(sample, 'identity', return_value={'test': True})
        self.identity.start()

    def tearDown(self):
        self.identity.stop()
        self.temp.cleanup()

    def add(self, data, **kw):
        return sample.append(self.path, data, reserve=0, **kw)

    def test_clock_rollback_and_boot_change(self):
        self.assertEqual(self.add(row())['seq'], 1)
        self.assertEqual(self.add(row(clock=200, wall=1))['seq'], 2)
        new = self.add(row(B, 1, 0))
        self.assertEqual(new['seq'], 1)
        self.assertEqual(new['previous_boot_id'], A)
        report = summarize(self.path)
        self.assertEqual(report['boots'][A]['wall_clock_rollbacks'], 1)
        self.assertEqual(report['boots'][A]['samples'], 2)
        self.assertEqual(report['boots'][B]['samples'], 1)

    def test_torn_tail_retained_and_delimited(self):
        self.add(row())
        path = sample.segments(self.path)[-1]
        with path.open('ab') as stream:
            stream.write(b'{"boot_id":')
        self.assertEqual(self.add(row(clock=200))['seq'], 2)
        self.assertIn(b'{"boot_id":\n', path.read_bytes())
        self.assertEqual(summarize(self.path)['malformed_sample_lines'], 1)

    def test_rotation_ignores_mtime_and_unrelated_files(self):
        unrelated = self.path / 'keep.txt'
        unrelated.write_text('keep')
        for i in range(20):
            self.add(row(clock=i), segment=600, total=1400)
            for path in sample.segments(self.path):
                path.touch()
        paths = sample.segments(self.path)
        self.assertLessEqual(sum(p.stat().st_size for p in paths), 1400)
        self.assertTrue(all(p.stat().st_size <= 600 for p in paths))
        self.assertEqual(sample.last_record(paths)['seq'], 20)
        self.assertEqual(unrelated.read_text(), 'keep')
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in paths))

    def test_low_space_does_not_prune(self):
        self.add(row())
        before = {p.name: p.read_bytes() for p in sample.segments(self.path)}
        with self.assertRaisesRegex(RuntimeError, 'low space'):
            sample.append(self.path, row(), reserve=2**63)
        self.assertEqual(before, {p.name: p.read_bytes() for p in sample.segments(self.path)})

    def test_oversize_does_not_prune(self):
        self.add(row())
        data = dict(row(), large='x' * sample.LINE)
        with self.assertRaises(ValueError):
            self.add(data)
        self.assertEqual(sample.last_record(sample.segments(self.path))['seq'], 1)

    def test_missing_fields_and_sleep_gap(self):
        self.add(row(clock=100))
        data = row(clock=600)
        data['monotonic_ns'] = 200
        data['power_supply_raw'] = {'unavailable': 'absent'}
        self.add(data)
        self.assertEqual(summarize(self.path)['boots'][A]['clock_suspend_ns'], 400)

    def test_journal_pairs_do_not_cross_boots_or_expose_content(self):
        self.add(row())
        journal = self.path / 'journal.jsonl'
        entries = [(A, 'PM: suspend entry (deep)'), (B, 'PM: suspend exit'),
                   (A, 'PM: suspend exit'), (A, 'private application contents')]
        journal.write_text(''.join(json.dumps({'_BOOT_ID': b.replace('-', ''), 'MESSAGE': msg,
                                              '__MONOTONIC_TIMESTAMP': '123'}) + '\n'
                                   for b, msg in entries))
        report = summarize(self.path, journal)
        self.assertEqual(report['journal_pm_pairs'], {A: 1})
        self.assertEqual(report['journal_pm_unpaired'], {B: 1})
        self.assertNotIn('private application', json.dumps(report))

    def test_write_error_preserves_existing_record(self):
        self.add(row())
        with patch.object(sample.os, 'open', side_effect=OSError('write blocked')):
            with self.assertRaises(OSError):
                self.add(row(clock=200))
        self.assertEqual(sample.last_record(sample.segments(self.path))['seq'], 1)


class Reader(unittest.TestCase):
    def test_missing_file(self):
        self.assertIn('unavailable', sample.read('/nonexistent/liuqin-test'))

    def test_build_id_note(self):
        data = struct.pack('<III', 4, 20, 3) + b'GNU\0' + bytes(range(20))
        self.assertEqual(sample.notes_build_id(data), bytes(range(20)).hex())
        with self.assertRaises(ValueError):
            sample.notes_build_id(data[:-1])

    def test_subprocess_timeout(self):
        import subprocess
        with patch.object(sample.subprocess, 'run', side_effect=subprocess.TimeoutExpired('test', .4)):
            self.assertEqual(sample.command(['test']), {'unavailable': 'TimeoutExpired'})


if __name__ == '__main__':
    unittest.main()
