#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2,<3", "scipy>=1.11,<2"]
# ///
"""Synthesises the background track of the PasswordPie promo video.

Everything is generated here from sine waves and noise: no samples, no third-party audio.

The drums are in front: a kick on every beat, a snare on two and four, sixteenth-note hats with accents and a bass
line in eighths; the pad stays behind them. When things happen comes from the video's own timing data
(../composition/timing.js, written by prep.mjs), not from numbers kept here: the tempo is the beat the scenes are cut
to, each scene starts a new chord with the bar counted from it, and the last hit, where the drums stop, is the end
card. What the interface does is heard as an interface, not as part of the tune: a key cap's click at each key press
(Command-backslash, Return) and a soft pop at each moment a form, or the two-step code, fills in.

usage: synth.py OUT.wav [--timing timing.js] [--variant bright|soft]
       synth.py --plan  [--timing timing.js]      prints the moments it would play to, as JSON
"""
from __future__ import annotations

import argparse
import json
import wave
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import numpy.typing as npt
from scipy.signal import butter, fftconvolve, sosfilt

Samples = npt.NDArray[np.float64]

SR = 48000
BEATS_IN_A_BAR = 4
SWING = 0.14  # how late the off sixteenths come, as a part of a sixteenth
DEFAULT_TIMING = Path(__file__).resolve().parent.parent / 'composition' / 'timing.js'


@dataclass(frozen=True)
class Plan:
    """The moments of the video the music is written to, in seconds."""

    duration: float
    beat: float  # the scenes are cut to it; the tempo is 60 / beat
    sections: tuple[float, ...]  # where each scene after the cover starts: the drums come in at the first
    end_card: float  # the last hit; the drums stop here
    fills: tuple[float, ...]  # a pop on each: the moments a form, or the two-step code, fills in
    clicks: tuple[float, ...]  # a key cap's click on each: the key presses


def number(data: object, *path: str) -> float:
    """data[path[0]][path[1]]… as a float; the timing file is JSON, so nothing about its shape is assumed."""
    for key in path:
        if not isinstance(data, dict) or key not in data:
            raise ValueError(f'timing data has no {".".join(path)}')
        data = data[key]
    if isinstance(data, bool) or not isinstance(data, (int, float)):
        raise ValueError(f'timing data: {".".join(path)} is not a number')
    return float(data)


def read_timing(path: Path) -> object:
    """timing.js is `window.PP = {…};` after a comment line."""
    text = path.read_text(encoding='utf-8')
    start = text.index('{', text.index('window.PP'))
    return json.loads(text[start : text.rindex('}') + 1])


def plan_from(timing: object) -> Plan:
    def scene(name: str) -> float:
        return number(timing, 'scenes', name)

    sections = (scene('demo'), scene('race'))
    end_card = scene('end')
    beat = scene('beat')
    if not 0.4 <= beat <= 0.6:
        raise ValueError(f'{60 / beat:.0f} beats a minute: the music is written for 100 to 150')
    for start in (*sections, end_card):
        beats = (start - sections[0]) / beat
        if abs(beats - round(beats)) > 1e-6:
            raise ValueError(f'the scene at {start} s does not start on a beat ({beat} s from {sections[0]} s)')
    return Plan(
        duration=scene('duration'),
        beat=beat,
        sections=sections,
        end_card=end_card,
        fills=(
            scene('demo') + number(timing, 'demo', 'filled'),  # filled, in real time
            scene('demo') + number(timing, 'demo', 'code'),  # the two-step code, in the same stretch
            scene('race') + number(timing, 'race', 'pieFilledAt'),  # side by side
        ),
        clicks=(
            scene('demo') + number(timing, 'demo', 'hotkey'),  # Command-backslash
            scene('demo') + number(timing, 'demo', 'ret'),  # Return: fill
            scene('demo') + number(timing, 'demo', 'submit'),  # Return: Sign in
            scene('race') + number(timing, 'race', 'pieHotkeyAt'),
            scene('race') + number(timing, 'race', 'pieReturnAt'),
        ),
    )


def hz(midi: float) -> float:
    return float(440.0 * 2 ** ((midi - 69) / 12))


def t(seconds: float) -> Samples:
    return np.arange(int(SR * seconds)) / SR


def pluck(midi: float, length: float = 0.5, decay: float = 0.13) -> Samples:
    x = t(length)
    f = hz(midi)
    s = np.sin(2 * np.pi * f * x) + 0.3 * np.sin(2 * np.pi * 2 * f * x) * np.exp(-x / 0.04)
    env = np.exp(-x / decay) * np.minimum(1, x / 0.003)
    out: Samples = s * env
    return out


def bell(midi: float, length: float = 1.6, decay: float = 0.55) -> Samples:
    x = t(length)
    f = hz(midi)
    mod = 2.2 * np.exp(-x / 0.25) * np.sin(2 * np.pi * 3.5 * f * x)
    s = np.sin(2 * np.pi * f * x + mod) + 0.3 * np.sin(2 * np.pi * 2 * f * x) * np.exp(-x / 0.2)
    return s * np.exp(-x / decay) * np.minimum(1, x / 0.002)


def pad(midi: float, length: float, detune: float) -> Samples:
    x = t(length)
    f = hz(midi) * (1 + detune)
    drift = 1 + 0.0015 * np.sin(2 * np.pi * 0.31 * x + midi)
    ph = 2 * np.pi * np.cumsum(f * drift) / SR
    s = np.sin(ph) + 0.18 * np.sin(2 * ph + 1.0)
    att, rel = 0.5, 1.1
    env = np.minimum(1, x / att) * (0.4 + 0.6 * np.exp(-x / 0.9)) * np.minimum(1, np.maximum(0, (length - x) / rel))
    return s * env


def bass(midi: float, length: float) -> Samples:
    x = t(length)
    f = hz(midi)
    s = np.sin(2 * np.pi * f * x) + 0.35 * np.sin(2 * np.pi * 2 * f * x) + 0.1 * np.sin(2 * np.pi * 3 * f * x)
    env = np.minimum(1, x / 0.006) * np.exp(-x / 0.4) * np.minimum(1, np.maximum(0, (length - x) / 0.03))
    out: Samples = np.tanh(1.4 * s * env)
    return out


def kick() -> Samples:
    x = t(0.32)
    f = 46 + 75 * np.exp(-x / 0.035)
    s = np.sin(2 * np.pi * np.cumsum(f) / SR)
    return s * np.exp(-x / 0.11) * np.minimum(1, x / 0.001)


HP_HAT = butter(4, 7000, 'highpass', fs=SR, output='sos')
BP_SNAP = butter(2, [1400, 4200], 'bandpass', fs=SR, output='sos')
BP_SNARE = butter(2, [500, 2000], 'bandpass', fs=SR, output='sos')  # the upper edge is low: noise above it hisses
LP_SNARE = butter(1, 1500, 'lowpass', fs=SR, output='sos')
BP_TICK = butter(2, [1100, 3200], 'bandpass', fs=SR, output='sos')
BP_RISE = butter(2, [700, 3200], 'bandpass', fs=SR, output='sos')
HP_CRASH = butter(2, 4500, 'highpass', fs=SR, output='sos')


def hat(rng: np.random.Generator, decay: float = 0.028) -> Samples:
    x = t(0.12)
    return sosfilt(HP_HAT, rng.standard_normal(len(x))) * np.exp(-x / decay)


def snap(rng: np.random.Generator) -> Samples:
    x = t(0.12)
    n = sosfilt(BP_SNAP, rng.standard_normal(len(x))) * np.exp(-x / 0.018)
    body = np.sin(2 * np.pi * 1750 * x) * np.exp(-x / 0.012) + 0.5 * np.sin(2 * np.pi * 820 * x) * np.exp(-x / 0.02)
    return 0.6 * n + body


def snare(rng: np.random.Generator) -> Samples:
    """A drum more than a burst of noise: two modes of the head falling in pitch, and wires that are darkened (noise
    falling off above 1.5 kHz, none above 2 kHz to speak of) and short. Brighter or longer, the noise hisses."""
    x = t(0.2)
    head = np.sin(2 * np.pi * np.cumsum(182 + 60 * np.exp(-x / 0.012)) / SR) * np.exp(-x / 0.055)
    head += 0.45 * np.sin(2 * np.pi * np.cumsum(331 + 40 * np.exp(-x / 0.01)) / SR) * np.exp(-x / 0.03)
    wires = sosfilt(BP_SNARE, sosfilt(LP_SNARE, rng.standard_normal(len(x)))) * np.exp(-x / 0.045)
    out: Samples = (0.55 * head + 1.3 * wires) * np.minimum(1, x / 0.0008)
    return out


def crash(rng: np.random.Generator) -> Samples:
    x = t(1.6)
    out: Samples = sosfilt(HP_CRASH, rng.standard_normal(len(x))) * np.exp(-x / 0.45) * np.minimum(1, x / 0.002)
    return out


def click() -> Samples:
    """A key cap going down: a tick (a few ms of noise, 1 to 3 kHz) on a short thud. No pitch, and the same every
    time, so check.py can find it: its noise has a seed of its own."""
    x = t(0.06)
    tick = sosfilt(BP_TICK, np.random.default_rng(11).standard_normal(len(x))) * np.exp(-x / 0.0035)
    thud = np.sin(2 * np.pi * np.cumsum(150 + 170 * np.exp(-x / 0.004)) / SR) * np.exp(-x / 0.011)
    out: Samples = (tick + 0.8 * thud) * np.minimum(1, x / 0.0004)
    return out


def pop() -> Samples:
    """A soft pop, as a bubble: a sine that slides up from 330 to 660 Hz in a few hundredths of a second and is gone.
    It never rests on a note, so it is not heard as one of the tune's, and it stays under 1 kHz: not sharp."""
    x = t(0.16)
    f = 660 - 330 * np.exp(-x / 0.022)
    ph = 2 * np.pi * np.cumsum(f) / SR
    out: Samples = (np.sin(ph) + 0.2 * np.sin(2 * ph)) * np.exp(-x / 0.032) * np.minimum(1, x / 0.0025)
    return out


POP_GAIN = 0.2
CLICK_GAIN = 0.2


def riser(rng: np.random.Generator, length: float) -> Samples:
    x = t(length)
    return sosfilt(BP_RISE, rng.standard_normal(len(x))) * (x / length) ** 2.5


Chord = tuple[int, int, int]
D: Chord = (62, 66, 69)
A: Chord = (57, 61, 64)
Bm: Chord = (59, 62, 66)
G: Chord = (55, 59, 62)
ROOT: dict[Chord, int] = {D: 38, A: 33, Bm: 35, G: 31}
CHORDS: list[Chord] = [D, G, A, Bm]  # one a scene, in turn; the end card comes home to D
# The plucked figure, in sixteenths of a bar: off the beat more often than on it, under the drums.
FIGURE = [0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 1]


def render(plan: Plan, variant: str = 'bright') -> Samples:
    """The finished stereo mix, shape (samples, 2), peaking at -1.5 dBFS."""
    rng = np.random.default_rng(7)
    dur = plan.duration
    n_samples = int(SR * dur)
    beat = plan.beat
    s16 = beat / 4
    first = plan.sections[0]
    n_beats = round((plan.end_card - first) / beat)
    starts = [round((s - first) / beat) for s in plan.sections]  # the beat each scene starts on

    def section(k: int) -> int:
        """Which scene beat k is in."""
        return max(i for i, s in enumerate(starts) if s <= k)

    def empty() -> Samples:
        return np.zeros((n_samples, 2))

    def place(buf: Samples, sig: Samples, at: float, gain: float = 1.0, pan: float = 0.0) -> None:
        """Adds a mono signal at `at` seconds; pan -1 (left) .. 1 (right), constant power."""
        i = int(round(at * SR))
        if i >= n_samples or i < 0:
            return
        sig = sig[: n_samples - i]
        a = (pan + 1) * np.pi / 4
        buf[i : i + len(sig), 0] += sig * gain * np.cos(a)
        buf[i : i + len(sig), 1] += sig * gain * np.sin(a)

    drums, drumwet, bassbus, wet, padbus, arpbus, cue = empty(), empty(), empty(), empty(), empty(), empty(), empty()

    # Over the cover, before the first beat: a swell and two taps into the downbeat.
    place(wet, riser(rng, first), 0.0, 0.03)
    place(drumwet, snap(rng), first - 2 * s16, 0.05, -0.15)
    place(drumwet, snap(rng), first - s16 + 0.004, 0.08, 0.15)

    for k in range(n_beats):
        at = first + k * beat
        sec = section(k)
        in_bar = (k - starts[sec]) % BEATS_IN_A_BAR  # the bar is counted from where the scene starts
        chord = CHORDS[sec % len(CHORDS)]
        root = ROOT[chord]
        last_of_scene = k + 1 == n_beats or section(k + 1) != sec

        # Drums, played by a hand and not by a grid: a kick on every beat (the one of a bar a little harder), a snare
        # on two and four that comes a few ms late and is never twice as loud (four harder than two), and a soft kick
        # before the three.
        place(drums, kick(), at + rng.uniform(-0.0015, 0.0015), (0.52 if in_bar == 0 else 0.47) * rng.uniform(0.94, 1.0))
        if in_bar == 1:
            place(drums, kick(), at + 3 * s16 + SWING * s16, 0.2 * rng.uniform(0.8, 1.0))
        if in_bar % 2 == 1:
            hit = snare(rng)
            late = rng.uniform(0.003, 0.009)
            vel = (0.78 if in_bar == 1 else 1.0) * rng.uniform(0.86, 1.0)
            place(drums, hit, at + late, 0.3 * vel, -0.1)
            place(drums, snap(rng), at + late, 0.02 * vel, 0.05)
            place(drumwet, hit, at + late, 0.09 * vel, 0.2)
        # Hats in sixteenths. The ones off the eighth (the 2nd and 4th of a beat) come late, for swing; each is a few
        # ms early or late besides, and no two are equally loud: a rise through the bar, the off-beat eighth on top,
        # and a hand that sometimes barely touches.
        lift = 0.75 + 0.25 * in_bar / (BEATS_IN_A_BAR - 1)
        for i in range(4):
            if i == 2 and last_of_scene:
                place(drums, hat(rng, 0.09), at + i * s16 + rng.uniform(-0.002, 0.003), 0.085, 0.25)  # open, into the next scene
                continue
            late = SWING * s16 if i % 2 else 0.0
            touch = rng.uniform(0.3, 0.55) if i % 2 and rng.uniform() < 0.3 else rng.uniform(0.62, 1.0)
            gain = (0.05, 0.02, 0.085, 0.032)[i] * lift * touch
            place(drums, hat(rng, 0.018 + 0.016 * rng.uniform()), at + i * s16 + late + rng.uniform(-0.004, 0.005), gain, 0.25 if i % 2 == 0 else -0.2)

        # Bass in eighths: the root, up an octave on the last off-beat of the bar.
        place(bassbus, bass(root, beat * 0.42), at, 0.3)
        place(bassbus, bass(root + (12 if in_bar == BEATS_IN_A_BAR - 1 else 0), beat * 0.4), at + beat / 2, 0.24)

        # A plucked figure on the chord, quiet.
        tones = [chord[0] + 12, chord[2] + 12, chord[1] + 24, chord[0] + 24, chord[2] + 12, chord[1] + 12]
        for i in range(4):
            step = in_bar * 4 + i
            if FIGURE[step]:
                place(arpbus, pluck(tones[step % len(tones)]), at + i * s16, 0.04 * rng.uniform(0.8, 1.0), 0.45 if step % 2 else -0.45)

    # Each scene: its chord on the pad, far back, and the chord struck once where the scene starts.
    for i, start in enumerate(plan.sections):
        chord = CHORDS[i % len(CHORDS)]
        until = plan.sections[i + 1] if i + 1 < len(plan.sections) else plan.end_card
        for n in chord:
            for det, pan in ((-0.005, -0.8), (0.005, 0.8)):
                place(padbus, pad(n, until - start + 0.5, det), start, 0.022, pan)
            place(arpbus, pluck(n + 12, 0.6, 0.2), start, 0.07)

    # Into the end card: a swell and a roll of taps over the last beat, then one hit and the drums stop.
    # The tonic chord rings on bells over a long bass note and dies away before the video ends.
    place(wet, riser(rng, 2 * beat), plan.end_card - 2 * beat, 0.035)
    for i in range(4):
        place(drumwet, snap(rng), plan.end_card - (4 - i) * s16, 0.035 + 0.02 * i, -0.15 + 0.1 * i)
    place(drums, kick(), plan.end_card, 0.55)
    place(drumwet, crash(rng), plan.end_card, 0.05)
    for i, n in enumerate((74, 78, 81, 86)):
        place(wet, bell(n, dur - plan.end_card, 0.7), plan.end_card + i * 0.03, 0.11, (-0.5, -0.15, 0.15, 0.5)[i])
    place(bassbus, bass(38, 1.6) * np.exp(-t(1.6) / 0.7), plan.end_card, 0.3)
    for n in D:
        place(padbus, pad(n, dur - plan.end_card, 0.0), plan.end_card, 0.03)

    for at in plan.fills:
        place(cue, pop(), at, POP_GAIN)
    for at in plan.clicks:
        place(cue, click(), at, CLICK_GAIN)

    # --- reverb, master ---
    ir_len = int(SR * 1.1)
    ir_t = np.arange(ir_len) / SR
    ir = rng.standard_normal((ir_len, 2)) * np.exp(-ir_t / 0.26)[:, None]
    ir[: int(SR * 0.012)] = 0
    ir /= np.sqrt((ir**2).sum(axis=0))
    padbus = sosfilt(butter(2, 950, 'lowpass', fs=SR, output='sos'), padbus, axis=0)
    padbus -= 0.45 * sosfilt(butter(1, [250, 500], 'bandpass', fs=SR, output='sos'), padbus, axis=0)
    arpbus = sosfilt(butter(2, 2600, 'lowpass', fs=SR, output='sos'), arpbus, axis=0)
    wet += padbus + arpbus

    def reverb(b: Samples) -> Samples:
        return np.stack([fftconvolve(b[:, c], ir[:, c])[:n_samples] for c in range(2)], axis=1)

    tonal = bassbus + wet + reverb(wet) * (0.4 if variant == 'bright' else 0.6)
    # What has a pitch steps back 3 dB under each cue; the drums play through it.
    duck = np.ones(n_samples)
    for at in plan.fills:
        x = np.arange(n_samples) / SR - at
        dip = np.where(x < 0, np.clip(1 + x / 0.04, 0, 1), np.exp(-np.maximum(x - 0.18, 0) / 0.18))
        duck = np.minimum(duck, 1 - (1 - 10 ** (-3 / 20)) * dip)
    # The interface's sounds are dry and in the middle: they are in the room with the viewer, not with the band.
    mix = drums + drumwet + reverb(drumwet) * 0.4 + tonal * duck[:, None] + cue

    if variant == 'soft':  # the same piece, darker and quieter on top
        mix = sosfilt(butter(2, 5200, 'lowpass', fs=SR, output='sos'), mix, axis=0)

    mix = sosfilt(butter(2, 32, 'highpass', fs=SR, output='sos'), mix, axis=0)
    x = np.arange(n_samples) / SR
    out_from = plan.end_card + (dur - plan.end_card) * 0.4
    fade = np.minimum(1, x / 0.005) * np.where(x > out_from, 0.5 * (1 + np.cos(np.pi * np.clip((x - out_from) / (dur - out_from - 0.05), 0, 1))), 1)
    mix *= fade[:, None]
    mix = np.tanh(mix * 2.2) / 2.2
    mix *= 10 ** (-1.5 / 20) / np.abs(mix).max()
    return mix


def main() -> None:
    parser = argparse.ArgumentParser(description='The background track of the PasswordPie promo video.')
    parser.add_argument('out', nargs='?', type=Path, help='WAV to write (48 kHz, 16-bit stereo)')
    parser.add_argument('--timing', type=Path, default=DEFAULT_TIMING, help='timing.js written by prep.mjs')
    parser.add_argument('--variant', choices=('bright', 'soft'), default='bright')
    parser.add_argument('--plan', action='store_true', help='print the moments the music is written to, and stop')
    args = parser.parse_args()
    timing: Path = args.timing
    out: Path | None = args.out
    variant: str = args.variant
    plan = plan_from(read_timing(timing))
    if args.plan:
        print(json.dumps(asdict(plan), indent=2))
        return
    if out is None:
        parser.error('OUT.wav is needed')
    mix = render(plan, variant)
    with wave.open(str(out), 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((mix * 32767).astype('<i2').tobytes())
    peak = 20 * np.log10(np.abs(mix).max())
    rms = 20 * np.log10(np.sqrt((mix**2).mean()))
    print(f'{out}: {plan.duration}s, peak {peak:.1f} dBFS, rms {rms:.1f} dBFS')


if __name__ == '__main__':
    main()
