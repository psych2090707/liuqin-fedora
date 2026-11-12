"""Known-gain/known-loss tests for the actual capture analyser, no devices."""
import importlib.util
from pathlib import Path
import unittest
import numpy as np

source = Path(__file__).resolve().parents[2] / 'tools/audio-response/measure.py'
spec = importlib.util.spec_from_file_location('audio_measure', source)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class AnalysisTest(unittest.TestCase):
    def signal(self, losses=None):
        t = np.arange(2 * m.RATE) / m.RATE
        x = np.zeros(m.CAPTURE_SECONDS * m.RATE)
        for i, f in enumerate(m.FREQUENCIES):
            gain = 10 ** ((losses or {}).get(f, 0) / 20)
            tone = .004 * gain * np.sin(2 * np.pi * f * t + i)
            for start in m.STARTS:
                at = round((start + .8) * m.RATE)
                x[at:at + len(tone)] += tone
        x += np.random.default_rng(42).normal(0, 1e-7, len(x))
        return x[:, None]

    def test_gain_and_independent_start_alignment(self):
        r = m.analyse_signal(self.signal())
        self.assertAlmostEqual(r['lag_s'], .8, delta=.2)
        target = 20 * np.log10(.004 / np.sqrt(2))
        np.testing.assert_allclose(np.array(r['median_dbfs'])[:, 0], target, atol=.05)
        self.assertLess(np.max(r['range_db']), .05)

    def test_detect_38db_high_frequency_loss(self):
        a = m.analyse_signal(self.signal())
        b = m.analyse_signal(self.signal({8000: -38}))
        i = m.FREQUENCIES.index(8000)
        delta = b['median_dbfs'][i][0] - a['median_dbfs'][i][0]
        self.assertAlmostEqual(delta, -38, delta=.15)

    def test_noise_cannot_establish_a_tone(self):
        noise = np.random.default_rng(1).normal(0, 1e-4, (m.CAPTURE_SECONDS * m.RATE, 1))
        r = m.analyse_signal(noise)
        self.assertLess(np.max(r['tone_to_background_db']), 6)

    def test_reject_short_capture(self):
        with self.assertRaises(AssertionError):
            m.analyse_signal(np.zeros((m.RATE, 1)))


if __name__ == '__main__':
    unittest.main()
