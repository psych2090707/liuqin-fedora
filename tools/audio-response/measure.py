#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Fixed multitone capture/analysis; no mixer, firmware or service changes."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import time
import wave

RATE = 48000
FREQUENCIES = [250, 400, 630, 1000, 1600, 2500, 4000, 6300, 8000, 10000, 12500]
STARTS = [1.5, 4.5, 7.5]
DURATION = 11
CAPTURE_SECONDS = 14
PEAK = 0.08
SINK = 'alsa_output.platform-sound.HiFi__Speaker__sink'
MONITOR = 'alsa_output.hw_XiaomiPad6Pro_0'
MIC = 'alsa_input.platform-sound.HiFi__Mic__source'


def command(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=kwargs.pop('timeout', 8), **kwargs).stdout


def build_id():
    data = Path('/sys/kernel/notes').read_bytes()
    offset = 0
    while offset + 12 <= len(data):
        ns, ds, kind = struct.unpack_from('<III', data, offset)
        offset += 12
        name = data[offset:offset + ns]
        offset += (ns + 3) & ~3
        value = data[offset:offset + ds]
        offset += (ds + 3) & ~3
        if name == b'GNU\0' and kind == 3:
            return value.hex()
    raise RuntimeError('GNU Build ID missing')


def generate(directory):
    import numpy as np
    directory.mkdir(parents=True, exist_ok=True)
    assert not (directory / 'stimulus.wav').exists(), 'Refuse to replace stimulus'
    t = np.arange(2 * RATE) / RATE
    tone = sum(np.sin(2 * np.pi * f * t + np.pi * i * (i - 1) / len(FREQUENCIES))
               for i, f in enumerate(FREQUENCIES))
    tone *= PEAK / np.max(np.abs(tone))
    ramp = int(.02 * RATE)
    tone[:ramp] *= np.linspace(0, 1, ramp)
    tone[-ramp:] *= np.linspace(1, 0, ramp)
    data = np.zeros(DURATION * RATE)
    for start in STARTS:
        at = int(start * RATE)
        data[at:at + len(tone)] = tone
    with wave.open(str(directory / 'stimulus.wav'), 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(np.repeat((data * 32767).astype('<i2')[:, None], 2, axis=1).tobytes())


def capture(directory, expected):
    directory = directory.resolve()
    allowed = Path(f'/run/user/{os.getuid()}').resolve()
    assert directory.is_relative_to(allowed), 'Capture only on the user runtime tmpfs'
    assert build_id() == expected, 'Unexpected running kernel'
    assert (directory / 'stimulus.wav').is_file()
    assert not (directory / 'capture.json').exists(), 'Use a fresh capture directory'
    graph = json.loads(command(['pw-dump']))
    active = [o for o in graph if o.get('info', {}).get('props', {}).get('media.class')
              in ('Stream/Output/Audio', 'Stream/Input/Audio')]
    assert not active, 'Other audio streams exist; do not measure over them'
    volume = command(['wpctl', 'get-volume', '@DEFAULT_AUDIO_SINK@']).strip()
    assert volume == 'Volume: 0.20', f'Expected unchanged 20% baseline, got {volume}'
    source_volume = command(['wpctl', 'get-volume', '@DEFAULT_AUDIO_SOURCE@']).strip()
    assert source_volume == 'Volume: 1.00', source_volume
    report = {'build_id': expected, 'kernel_release': os.uname().release,
              'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
              'rate': RATE, 'sink_volume_before': volume,
              'source_volume_before': source_volume, 'source': MIC, 'monitor': MONITOR,
              'stimulus_sha256': hashlib.sha256((directory / 'stimulus.wav').read_bytes()).hexdigest(),
              'stimulus_peak': PEAK, 'no_mixer_or_firmware_changes': True,
              'capture_seconds': CAPTURE_SECONDS, 'recorders': {}}
    processes = []
    try:
        for name, channels, target, channelmap, props in [
            ('mic', 2, MIC, 'FL,FR', '{}'),
            ('monitor', 4, MONITOR, 'AUX0,AUX1,AUX2,AUX3', '{"stream.capture.sink":true}')]:
            log = (directory / f'{name}.log').open('w')
            args = ['pw-record', '--raw', '--rate=48000', '--format=s32',
                    f'--channels={channels}', f'--channel-map={channelmap}',
                    f'--target={target}', '--latency=256', '--properties=' + props,
                    '--sample-count=' + str(CAPTURE_SECONDS * RATE),
                    str(directory / f'{name}.s32')]
            proc = subprocess.Popen(args, stdout=log, stderr=log)
            processes.append((name, channels, proc, log))
        time.sleep(1)
        assert all(p.poll() is None for _, _, p, _ in processes), 'Recorder exited before playback'
        with (directory / 'play.log').open('w') as log:
            player = subprocess.Popen(['pw-play', '--target=' + SINK, '--latency=256',
                                       str(directory / 'stimulus.wav')], stdout=log, stderr=log)
            try:
                time.sleep(2.5)
                report['playing_controls'] = {}
                for channel in ['TL', 'TR', 'BL', 'BR']:
                    for suffix in ['PCM Source', 'Speaker Calibration Loaded',
                                   'DSP1 Protection 400a4 HALO_STATE']:
                        key = f'{channel} {suffix}'
                        result = subprocess.run(['sudo', '-n', 'amixer', '-c0', 'cget', 'name=' + key],
                                                capture_output=True, text=True, timeout=4)
                        report['playing_controls'][key] = {'returncode': result.returncode,
                                                          'text': result.stdout + result.stderr}
                assert player.wait(timeout=18) == 0, 'Playback failed'
            finally:
                if player.poll() is None:
                    player.terminate()
                    player.wait(timeout=4)
        for name, channels, proc, log in processes:
            rc = proc.wait(timeout=10)
            log.close()
            size = (directory / f'{name}.s32').stat().st_size
            expected_size = RATE * CAPTURE_SECONDS * channels * 4
            report['recorders'][name] = {'returncode': rc, 'bytes': size,
                                         'expected_bytes': expected_size, 'channels': channels}
            # pw-record can return 1 on its sample-count EOS; bytes and signal
            # validity are checked independently, and the raw status is retained.
            assert size == expected_size, f'{name}: incomplete recording {size}/{expected_size}'
    finally:
        for _, _, proc, log in processes:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=4)
            log.close()
        report['sink_volume_after'] = command(['wpctl', 'get-volume', '@DEFAULT_AUDIO_SINK@']).strip()
        report['source_volume_after'] = command(['wpctl', 'get-volume', '@DEFAULT_AUDIO_SOURCE@']).strip()
        (directory / 'capture.json').write_text(json.dumps(report, indent=2) + '\n')
    assert report['sink_volume_after'] == volume
    assert report['source_volume_after'] == source_volume


def bands(data, rate=RATE):
    """RMS in +/-3 Hz of fixed tones, per channel, with Hann amplitude correction."""
    import numpy as np
    n = len(data)
    window = np.hanning(n)
    spectrum = np.fft.rfft((data - data.mean(axis=0)) * window[:, None], axis=0)
    power = np.abs(spectrum) ** 2 * 2 / (n * (window ** 2).sum())
    frequencies = np.fft.rfftfreq(n, 1 / rate)
    return np.array([power[np.abs(frequencies - f) <= 3].sum(axis=0)
                     for f in FREQUENCIES])


def analyse_signal(data):
    import numpy as np
    assert data.ndim == 2 and len(data) >= CAPTURE_SECONDS * RATE
    assert np.isfinite(data).all()
    # Locate the three bursts independently in each recording, so different
    # capture start latencies cannot be mistaken for an acoustic response.
    step = RATE // 10
    blocks = data[:len(data) // step * step].reshape(-1, step, data.shape[1])
    win = np.hanning(step)
    spec = np.abs(np.fft.rfft(blocks * win[None, :, None], axis=1)) ** 2
    bins = np.array(FREQUENCIES) // 10
    envelope = spec[:, bins, :].sum(axis=(1, 2))
    scores = []
    for lag in range(31):
        mask = np.zeros(len(envelope), dtype=bool)
        for start in STARTS:
            a = round(start * 10) + lag
            mask[a:a + 20] = True
        scores.append(envelope[mask].mean() - envelope[~mask].mean())
    lag = int(np.argmax(scores)) / 10
    packets = np.array([bands(data[round((start + lag + .5) * RATE):
                                       round((start + lag + 1.5) * RATE)]) for start in STARTS])
    noise = bands(data[round((lag + .1) * RATE):round((lag + 1.1) * RATE)])
    corrected = np.maximum(packets - noise[None, :, :], 1e-30)
    levels = 10 * np.log10(corrected)
    snr = 10 * np.log10(np.maximum(packets.mean(axis=0), 1e-30) / np.maximum(noise, 1e-30))
    # A coarse burst locator, not a measurement of device/audio latency.
    return {'lag_s': lag, 'median_dbfs': np.median(levels, axis=0).tolist(),
            'range_db': np.ptp(levels, axis=0).tolist(), 'tone_to_background_db': snr.tolist(),
            'clip_fraction': float(np.mean(np.abs(data) >= .999)),
            'peak': float(np.abs(data).max())}


def analyse(directory):
    import numpy as np
    capture_info = json.loads((directory / 'capture.json').read_text())
    results = {'frequencies_hz': FREQUENCIES, 'capture': capture_info, 'signals': {}}
    for name, channels in [('mic', 2), ('monitor', 4)]:
        data = np.fromfile(directory / f'{name}.s32', dtype='<i4').astype(float).reshape(-1, channels) / 2**31
        results['signals'][name] = analyse_signal(data)
    m = np.array(results['signals']['mic']['median_dbfs'])[:, 0]
    d = np.array(results['signals']['monitor']['median_dbfs'])[:, 0]
    transfer = m - d
    reference = FREQUENCIES.index(1000)
    results['mic0_to_monitor0_db'] = transfer.tolist()
    results['relative_to_1khz_db'] = (transfer - transfer[reference]).tolist()
    results['interpretation'] = ('Uncalibrated acoustic transfer, not SPL. Compare unchanged geometry, '
                                 'gain and stimulus across kernels. Reject weak-SNR or unstable bands.')
    (directory / 'analysis.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Hz   mic dBFS   background margin dB   repeat range dB   relative/1k dB')
    for i, f in enumerate(FREQUENCIES):
        s = results['signals']['mic']
        print(f'{f:5d} {m[i]:9.2f} {s["tone_to_background_db"][i][0]:22.2f}'
              f' {s["range_db"][i][0]:17.2f} {results["relative_to_1khz_db"][i]:16.2f}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['generate', 'capture', 'analyse'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--expect-build-id')
    args = parser.parse_args()
    if args.action == 'generate':
        generate(args.directory)
    elif args.action == 'capture':
        assert args.expect_build_id, 'Exact Build ID required'
        capture(args.directory, args.expect_build_id)
    else:
        analyse(args.directory)
