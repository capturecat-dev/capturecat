#!/usr/bin/env python3
"""CaptureCat app-preview soundtrack: copied unchanged in substance from Strobia
scripts/promo/soundtrack.py (the promo's and app preview's soundtrack), synthesised here so
there is nothing to license.

A warm pad in D, a soft 100 BPM pulse that falls away when the session
starts, and small interface sounds placed on the page's own cues
(events.json, written by render.mjs). Two loops are rendered and the
second kept, so reverb tails wrap round and the sound loops as cleanly
as the picture. With "loop": false in the events file it plays once
instead: an intro without the pulse, a resolved ending and a fade out.

    python3 soundtrack.py out/events.json out/soundtrack.wav
"""
import json
import math
import sys
import wave

import numpy as np

SR = 48000
rng = np.random.default_rng(20260925)


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def seconds(duration):
    return np.arange(int(duration * SR)) / SR


class Mix:
    def __init__(self, length):
        self.dry = np.zeros((2, length))
        self.wet = np.zeros((2, length))

    def add(self, start, signal, gain=1.0, pan=0.0, send=0.0):
        """Places a mono signal at `start` seconds, panned (-1..1), with
        some of it sent to the reverb."""
        i = int(round(start * SR))
        if i < 0:
            signal, i = signal[-i:], 0
        if i >= self.dry.shape[1] or len(signal) == 0:
            return
        j = min(self.dry.shape[1], i + len(signal))
        part = signal[: j - i] * gain
        left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        for channel, level in ((0, left), (1, right)):
            self.dry[channel, i:j] += part * level * (1 - send * 0.4)
            self.wet[channel, i:j] += part * level * send


def envelope(n, attack, release):
    """Smooth rise and fall over n samples (attack and release in seconds)."""
    x = np.ones(n)
    a, r = min(n, max(1, int(attack * SR))), min(n, max(1, int(release * SR)))
    x[:a] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    x[n - r :] *= (0.5 - 0.5 * np.cos(np.linspace(0, np.pi, r)))[::-1]
    return x


def band(noise, low, high):
    """Band-limits noise with an FFT mask (soft edges)."""
    spectrum = np.fft.rfft(noise)
    f = np.fft.rfftfreq(len(noise), 1 / SR)
    mask = 1 / (1 + (low / np.maximum(f, 1)) ** 4) / (1 + (f / high) ** 4)
    return np.fft.irfft(spectrum * mask, len(noise))


# ---------------------------------------------------------------- instruments

def pad_note(freq, duration):
    t = seconds(duration)
    tone = np.zeros_like(t)
    for h, level in ((1, 1.0), (2, 0.42), (3, 0.2), (4, 0.1), (5, 0.05)):
        detune = 1 + 0.0016 * (h % 2 * 2 - 1)
        tone += level * np.sin(2 * np.pi * freq * h * detune * t + rng.uniform(0, 2 * np.pi))
    shimmer = 1 + 0.06 * np.sin(2 * np.pi * 0.23 * t + rng.uniform(0, 2 * np.pi))
    return tone * shimmer * envelope(len(t), 0.9, 1.3)


def bass_note(freq, duration):
    t = seconds(duration)
    return (np.sin(2 * np.pi * freq * t) + 0.18 * np.sin(4 * np.pi * freq * t)) * envelope(len(t), 0.25, 0.8)


def pluck(freq):
    t = seconds(0.9)
    tone = np.sin(2 * np.pi * freq * t) + 0.28 * np.sin(4 * np.pi * freq * t) + 0.08 * np.sin(6 * np.pi * freq * t)
    return tone * np.exp(-t / 0.22) * (1 - np.exp(-t / 0.004))


def kick():
    t = seconds(0.5)
    sweep = 46 + 64 * np.exp(-t / 0.035)
    body = np.sin(2 * np.pi * np.cumsum(sweep) / SR) * np.exp(-t / 0.2)
    click = band(rng.standard_normal(len(t)), 800, 4000) * np.exp(-t / 0.004) * 0.15
    return (body + click) * (1 - np.exp(-t / 0.002))


def snap():
    t = seconds(0.25)
    return band(rng.standard_normal(len(t)), 1200, 5200) * np.exp(-t / 0.045)


def hat():
    t = seconds(0.12)
    return band(rng.standard_normal(len(t)), 6500, 15000) * np.exp(-t / 0.018)


def bell(freq, length=2.0):
    t = seconds(length)
    tone = np.zeros_like(t)
    for ratio, level, decay in ((1, 1.0, 1.4), (2.0, 0.35, 0.9), (3.01, 0.16, 0.55), (4.2, 0.08, 0.35)):
        tone += level * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t / decay)
    return tone * (1 - np.exp(-t / 0.003))


def tock(high=1150, low=780, decay=0.045):
    t = seconds(0.25)
    sweep = low + (high - low) * np.exp(-t / 0.012)
    body = np.sin(2 * np.pi * np.cumsum(sweep) / SR) * np.exp(-t / decay)
    click = band(rng.standard_normal(len(t)), 2000, 9000) * np.exp(-t / 0.0015) * 0.25
    return body + click


def key():
    t = seconds(0.05)
    return band(rng.standard_normal(len(t)), 2500, 7000) * np.exp(-t / 0.006) * rng.uniform(0.7, 1.0)


def pop():
    t = seconds(0.2)
    sweep = 520 + 480 * (1 - np.exp(-t / 0.02))
    return np.sin(2 * np.pi * np.cumsum(sweep) / SR) * np.exp(-t / 0.055) * (1 - np.exp(-t / 0.002))


def whoosh(length=0.42):
    t = seconds(length)
    noise = rng.standard_normal(len(t))
    low, high = band(noise, 250, 900), band(noise, 900, 3200)
    p = t / length
    shape = np.sin(np.pi * p) ** 2
    return (low * (1 - p) + high * p) * shape


def glide(duration, start_freq, end_freq):
    t = seconds(duration)
    freq = start_freq * (end_freq / start_freq) ** (t / duration)
    wobble = 1 + 0.004 * np.sin(2 * np.pi * 5 * t)
    return np.sin(2 * np.pi * np.cumsum(freq * wobble) / SR) * envelope(len(t), 0.15, 0.3)


def reverb(wet, seconds_=2.4):
    n = int(seconds_ * SR)
    t = np.arange(n) / SR
    tails = []
    for _ in range(2):
        ir = rng.standard_normal(n) * np.exp(-t * 6.9 / seconds_)
        ir = band(ir, 120, 7000)
        ir[: int(0.022 * SR)] = 0
        tails.append(ir / np.sqrt(np.sum(ir ** 2)))
    size = wet.shape[1] + n
    fft = 1 << (size - 1).bit_length()
    out = np.zeros((2, wet.shape[1]))
    for channel in range(2):
        spectrum = np.fft.rfft(wet[channel], fft) * np.fft.rfft(tails[channel], fft)
        out[channel] = np.fft.irfft(spectrum, fft)[: wet.shape[1]]
    return out


# ---------------------------------------------------------------- the score

def score(mix, offset, spec):
    """One loop of the music and the interface sounds, starting at `offset`.
    The random stream restarts for every loop, so each pass is identical
    and the passes join without a seam."""
    global rng
    rng = np.random.default_rng(20260925)
    loop, beat = spec["duration"], 60 / spec["bpm"]
    bar = 4 * beat
    looping = spec.get("loop", True)
    intro = spec.get("intro_bars", 0)
    music, sfx = spec.get("music", 1.0), spec.get("sfx", 1.0)
    session = next(e["t"] for e in spec["events"] if e["kind"] == "session")

    # D major, eight bars: Dmaj9, Bm11, Gmaj9, A6/9, Dmaj9, F#m7, Gmaj9, Asus.
    chords = [
        [50, 57, 61, 64, 66], [47, 54, 57, 62, 64], [43, 50, 54, 57, 59], [45, 52, 59, 61, 66],
        [50, 57, 61, 64, 66], [42, 49, 52, 57, 61], [43, 50, 54, 57, 59], [45, 52, 54, 59, 62],
    ]
    for k in range(int(round(loop / bar)) if looping else int(math.ceil(loop / bar))):
        chord = chords[k % len(chords)]
        start = offset + k * bar
        if not looping and k * bar >= session - 0.01:
            chord = chords[0]  # a one-off cut ends at home, on D
        for m in chord[1:]:
            mix.add(start - 0.3, pad_note(hz(m), bar + 1.6), gain=music * 0.038, pan=rng.uniform(-0.5, 0.5), send=0.55)
        root = chord[0] - 12 if chord[0] > 45 else chord[0]
        mix.add(start, bass_note(hz(root), bar + 0.4), gain=music * 0.075)
        # The pulse rests once the session begins, and comes back with the loop.
        for b in range(4):
            at = start + b * beat
            if at >= offset + session - 0.01 or k < intro:
                continue
            if b in (0, 2):
                mix.add(at, kick(), gain=music * 0.2)
            else:
                mix.add(at, snap(), gain=music * 0.05, send=0.35)
            mix.add(at + beat / 2, hat(), gain=music * 0.032, pan=0.3 if b % 2 else -0.3)
            # A soft pluck on the off-beats, on the chord's upper notes.
            notes = sorted(chord[1:])
            mix.add(at + beat / 2, pluck(hz(notes[(k + b) % len(notes)] + 12)), gain=music * 0.058,
                    pan=-0.35 if b % 2 else 0.35, send=0.5)
    # The session: the light arriving.
    mix.add(offset + session, glide(2.2, hz(62), hz(62)), gain=music * 0.022, send=0.8)
    for i, m in enumerate((74, 81, 86)):
        mix.add(offset + session + 0.06 + i * 0.09, bell(hz(m), 3.0), gain=music * 0.055, pan=(i - 1) * 0.3, send=0.7)

    # Interface sounds, on the page's cues.
    for event in spec["events"]:
        at, kind = offset + event["t"], event["kind"]
        if kind == "tap":
            mix.add(at - 0.012, tock(), gain=sfx * 0.22, send=0.15)
        elif kind == "hold":
            mix.add(at, tock(1000, 700, 0.035), gain=sfx * 0.15, send=0.1)
        elif kind == "let-go":
            mix.add(at, tock(900, 650, 0.03), gain=sfx * 0.11, send=0.1)
        elif kind == "key":
            mix.add(at, key(), gain=sfx * 0.07, pan=rng.uniform(-0.15, 0.15))
        elif kind == "morph":
            mix.add(at - 0.1, whoosh(), gain=sfx * 0.04, send=0.3)
        elif kind == "whoosh":
            mix.add(at - 0.15, whoosh(0.5), gain=sfx * 0.03, send=0.4)
        elif kind == "swish":
            mix.add(at - 0.05, whoosh(0.32), gain=sfx * 0.045, send=0.25)
        elif kind == "bell":
            for i, m in enumerate((74, 81)):
                mix.add(at + i * 0.08, bell(hz(m), 2.6), gain=sfx * 0.04, pan=(i - 0.5) * 0.4, send=0.7)
        elif kind == "pop":
            mix.add(at, pop(), gain=sfx * 0.1, pan=rng.uniform(-0.2, 0.2), send=0.25)
        elif kind == "step":
            mix.add(at, bell(hz(78), 1.6), gain=sfx * 0.05, send=0.6)
        elif kind == "ready":
            for i, m in enumerate((81, 86, 90)):
                mix.add(at + i * 0.05, bell(hz(m), 2.2), gain=sfx * 0.045, pan=(i - 1) * 0.3, send=0.6)
        elif kind == "draw":
            mix.add(at, glide(event["until"] - event["t"] + 0.3, hz(76), hz(69)), gain=sfx * 0.034, send=0.6)
        elif kind == "band":
            mix.add(at, bell(hz(83), 1.2), gain=sfx * 0.04, send=0.5)
        elif kind == "switch":
            mix.add(at - 0.01, tock(1500, 1100, 0.02), gain=sfx * 0.13)
            mix.add(at + 0.045, tock(1800, 1300, 0.02), gain=sfx * 0.1)
        elif kind == "tick":
            mix.add(at, tock(1500, 1400, 0.015), gain=sfx * 0.07, send=0.3)


def main(events_path, out_path):
    spec = json.load(open(events_path))
    loop = spec["duration"]
    n = int(round(loop * SR))
    if spec.get("loop", True):
        # Three passes; the middle one has the tails before it and the
        # fade-ins after it, exactly as it will when it loops.
        mix = Mix(3 * n)
        for rep in range(3):
            score(mix, rep * loop, spec)
        out = mix.dry + 0.32 * reverb(mix.wet)
        out = out[:, n : 2 * n]
    else:
        mix = Mix(n)
        score(mix, 0, spec)
        out = mix.dry + 0.32 * reverb(mix.wet)
        fade = int(1.6 * SR)
        out[:, -fade:] *= (0.5 + 0.5 * np.cos(np.linspace(0, np.pi, fade)))
    out = np.tanh(out * 1.2) / 1.2
    peak = np.max(np.abs(out))
    out *= 10 ** (-1.5 / 20) / peak
    rms = 20 * np.log10(np.sqrt(np.mean(out ** 2)))
    frames = (np.clip(out.T, -1, 1) * 32767).astype("<i2")
    with wave.open(out_path, "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(frames.tobytes())
    print(f"soundtrack: {loop:.2f} s, peak -1.5 dBFS, RMS {rms:.1f} dBFS")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
