#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2,<3", "scipy>=1.11,<2"]
# ///
"""Listens to the finished video: is each sound of the interface where the timing data says it happens, and is it loud enough?

Finds every pop (a form fills) and every key click of synth.py in the video's decoded sound track (as a player would
hear it) by matching the sound's own waveform, and measures loudness and true peak with ffmpeg's EBU R128 meter.
Prints JSON; exits 1 when a pop or a click is more than a frame from its moment, or the loudness or the peak is
outside what the video is made to.

usage: check.py VIDEO [--timing timing.js]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy.signal import butter, fftconvolve, hilbert, sosfiltfilt

import synth
from synth import SR, Samples

FRAME = 1 / 60
TARGET_LUFS = -16.0
LUFS_TOLERANCE = 0.5
MAX_TRUE_PEAK = -1.5
# Where each sound is and the rest of the music mostly is not.
POP_BAND = butter(4, [280, 1000], 'bandpass', fs=SR, output='sos')
CLICK_BAND = butter(4, [1100, 3400], 'bandpass', fs=SR, output='sos')


def decode(video: Path) -> Samples:
    """The sound track as mono float samples at 48 kHz (the two channels averaged here, not by ffmpeg)."""
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(video), '-map', '0:a:0', '-f', 'f32le', '-ar', str(SR), '-ac', '2', '-'],
                         check=True, capture_output=True).stdout
    stereo: Samples = np.frombuffer(raw, dtype='<f4').astype(np.float64).reshape(-1, 2)
    return stereo.mean(axis=1)


def heard_at(track: Samples, at: float, sound: Samples, band: Samples) -> float:
    """Seconds into the track where the `sound` that belongs at `at` starts, looked for within 0.15 s of it."""
    before = 0.15
    template = sosfiltfilt(band, np.concatenate([sound, np.zeros(int(SR * 0.05))]))
    start = int(round((at - before) * SR))
    window = track[max(start, 0) : start + len(template) + int(2 * before * SR)]
    match = fftconvolve(sosfiltfilt(band, window), template[::-1], mode='valid')
    lag = int(np.argmax(np.abs(hilbert(match))))
    return (max(start, 0) + lag) / SR


def loudness(video: Path) -> tuple[float, float]:
    """(integrated loudness in LUFS, true peak in dBFS)."""
    log = subprocess.run(['ffmpeg', '-nostats', '-i', str(video), '-map', '0:a:0', '-af', 'ebur128=peak=true', '-f', 'null', '-'],
                         check=True, capture_output=True, text=True).stderr
    summary = log[log.rindex('Summary:') :]
    integrated = re.search(r'I:\s+(-?[\d.]+) LUFS', summary)
    peak = re.search(r'Peak:\s+(-?[\d.]+) dBFS', summary)
    if integrated is None or peak is None:
        raise RuntimeError('no loudness summary from ffmpeg')
    return float(integrated.group(1)), float(peak.group(1))


def main() -> None:
    parser = argparse.ArgumentParser(description='Checks the sound of the finished promo video.')
    parser.add_argument('video', type=Path)
    parser.add_argument('--timing', type=Path, default=synth.DEFAULT_TIMING)
    args = parser.parse_args()
    video: Path = args.video
    timing: Path = args.timing
    plan = synth.plan_from(synth.read_timing(timing))
    track = decode(video)
    cues = [{'at': at, 'heard': heard_at(track, at, synth.pop(), POP_BAND)} for at in plan.fills]
    clicks = [{'at': at, 'heard': heard_at(track, at, synth.click(), CLICK_BAND)} for at in plan.clicks]
    lufs, true_peak = loudness(video)
    problems = [f'{what} at {c["at"]:.3f} s is heard at {c["heard"]:.3f} s' for what, found in (('pop', cues), ('click', clicks))
                for c in found if abs(c['heard'] - c['at']) > FRAME]
    if abs(lufs - TARGET_LUFS) > LUFS_TOLERANCE:
        problems.append(f'loudness {lufs} LUFS, wanted {TARGET_LUFS} ± {LUFS_TOLERANCE}')
    if true_peak > MAX_TRUE_PEAK:
        problems.append(f'true peak {true_peak} dBFS, over {MAX_TRUE_PEAK}')
    print(json.dumps({'seconds': len(track) / SR, 'cues': cues, 'clicks': clicks, 'lufs': lufs, 'truePeak': true_peak, 'problems': problems}, indent=2))
    if problems:
        sys.exit(1)


if __name__ == '__main__':
    main()
