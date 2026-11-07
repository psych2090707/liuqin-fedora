#!/usr/bin/env python3
"""Run the actual C lift-wait function against the observed TA command trace."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
UPSTREAM = PROJECT / 'upstream/xiaomipad-6pro-mainline/device/fingerprint/oem/src/fingerprint/oem/fpc_build_info.c'
PATCH = PROJECT / 'packaging/mobile/patches/fingerprint/0004-fpc-check-lift-after-state-command.patch'

HARNESS = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
enum query_kind { SENSOR_CHECK_FINGER_LOST, SENSOR_WAIT_FINGER_LOST, SENSOR_CHECK_FINGER_STATE };
static int index_, scenario;
static enum query_kind expected[] = {SENSOR_CHECK_FINGER_LOST, SENSOR_WAIT_FINGER_LOST,
                                     SENSOR_CHECK_FINGER_STATE, SENSOR_CHECK_FINGER_LOST};
static int query(int fd, uint32_t session, enum query_kind kind) {
    if (index_ >= 4 || kind != expected[index_++]) exit(97);
    if (scenario == 1 && index_ == 1) return 1; /* Already lifted. */
    if (scenario == 2 && index_ == 3) return -1; /* TA failure stays fatal. */
    return index_ == 4 ? 1 : 0;
}
static int clear_pending_irq(int fd, const char *phase) { return 0; }
static int wait_sensor_irq(int fd, const char *phase, int timeout) { return scenario == 3 ? -1 : 0; }
static int usleep(unsigned int time) { return 0; }
%s
int main(int argc, char **argv) {
    scenario = argc > 1 ? atoi(argv[1]) : 0;
    int result = wait_finger_lost(0, 0, 0);
    int count = scenario == 1 ? 1 : scenario == 2 ? 3 : scenario == 3 ? 2 : 4;
    int wanted = scenario >= 2 ? -1 : 0;
    return result == wanted && index_ == count ? 0 : 96;
}
'''


def function(source):
    start = source.index('static int wait_finger_lost(')
    end = source.index('\n}\n', start) + 3
    return source[start:end]


class FingerLift(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        source = cls.root / 'src/oem/fpc_build_info.c'
        source.parent.mkdir(parents=True)
        shutil.copy2(UPSTREAM, source)
        subprocess.run(['patch', '-p1', '-i', str(PATCH)], cwd=cls.root,
                       check=True, capture_output=True)
        cls.fixed = source.read_text()
        for name, content in [('original', UPSTREAM.read_text()), ('fixed', cls.fixed)]:
            harness = cls.root / (name + '.c')
            harness.write_text(HARNESS % function(content))
            subprocess.run(['cc', '-std=c11', str(harness), '-o', str(cls.root / name)],
                           check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_original_reproduces_missing_lift_query(self):
        self.assertEqual(subprocess.run([str(self.root / 'original')]).returncode, 97)

    def test_zero_state_status_still_checks_actual_lift(self):
        self.assertEqual(subprocess.run([str(self.root / 'fixed')]).returncode, 0)

    def test_already_lifted_finishes_without_extra_irq(self):
        self.assertEqual(subprocess.run([str(self.root / 'fixed'), '1']).returncode, 0)

    def test_ta_failure_never_becomes_lift_success(self):
        self.assertEqual(subprocess.run([str(self.root / 'fixed'), '2']).returncode, 0)

    def test_irq_failure_never_becomes_lift_success(self):
        self.assertEqual(subprocess.run([str(self.root / 'fixed'), '3']).returncode, 0)


if __name__ == '__main__':
    unittest.main()
