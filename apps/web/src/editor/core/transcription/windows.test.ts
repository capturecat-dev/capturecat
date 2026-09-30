import { describe, expect, it } from "vitest";

import { isSilent, MIN_WINDOW_SECONDS, nextWindow, peakFrameRms, quietestCut, SILENCE_RMS, WINDOW_SECONDS } from "./windows";

const RATE = 16_000;
/** Deterministic "speech": noise-modulated tone at ~−20 dBFS. */
function voiced(n: number, seed = 1): Float32Array {
  let s = seed;
  return Float32Array.from({ length: n }, (_, i) => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return 0.1 * Math.sin(i * 0.07) + 0.05 * (s / 2 ** 32 - 0.5);
  });
}

describe("transcription windows", () => {
  it("gates silence at −55 dBFS", () => {
    expect(isSilent(new Float32Array(RATE))).toBe(true);
    expect(isSilent(new Float32Array(0))).toBe(true);
    const hiss = Float32Array.from({ length: RATE }, (_, i) => (i % 2 ? 1 : -1) * SILENCE_RMS * 0.5);
    expect(isSilent(hiss)).toBe(true);
    const x = new Float32Array(RATE * 2);
    x.set(voiced(RATE / 5), RATE); // 200 ms of voice in 2 s of silence
    expect(isSilent(x)).toBe(false);
    expect(peakFrameRms(x)).toBeGreaterThan(0.05);
  });

  it("cuts at the quietest moment of the window's last ten seconds", () => {
    const x = voiced(WINDOW_SECONDS * RATE);
    // A 300 ms pause at 24.0–24.3 s.
    x.fill(0, 24 * RATE, 24.3 * RATE);
    const cut = quietestCut(x, MIN_WINDOW_SECONDS * RATE, WINDOW_SECONDS * RATE);
    expect(cut / RATE).toBeGreaterThanOrEqual(24);
    expect(cut / RATE).toBeLessThanOrEqual(24.3);
    const w = nextWindow(0, 100 * RATE, x);
    expect(w).toEqual({ start: 0, end: cut });
    // A pause before 20 s is not a candidate.
    const early = voiced(WINDOW_SECONDS * RATE, 7);
    early.fill(0, 10 * RATE, 12 * RATE);
    const c2 = nextWindow(0, 100 * RATE, early).end / RATE;
    expect(c2).toBeGreaterThanOrEqual(MIN_WINDOW_SECONDS);
    expect(c2).toBeLessThanOrEqual(WINDOW_SECONDS);
  });

  it("the final window runs to the end; silence keeps windows long", () => {
    expect(nextWindow(40 * RATE, 65 * RATE, new Float32Array(25 * RATE))).toEqual({ start: 40 * RATE, end: 65 * RATE });
    expect(nextWindow(0, 30 * RATE, new Float32Array(30 * RATE))).toEqual({ start: 0, end: 30 * RATE });
    // All-silent window: the LATEST equally quiet frame wins (≈ 30 s, not 20 s).
    const end = nextWindow(0, 90 * RATE, new Float32Array(30 * RATE)).end / RATE;
    expect(end).toBeGreaterThan(29.8);
    expect(end).toBeLessThanOrEqual(30);
  });

  it("walks a long track into ≤ 30 s windows that tile it exactly", () => {
    const total = 95 * RATE + 123;
    const track = voiced(total, 3);
    for (const t of [18.5, 47.2, 76.9]) track.fill(0, Math.round(t * RATE), Math.round((t + 0.25) * RATE));
    let pos = 0;
    const windows: [number, number][] = [];
    while (pos < total) {
      const ahead = track.subarray(pos, Math.min(total, pos + WINDOW_SECONDS * RATE));
      const w = nextWindow(pos, total, ahead);
      expect(w.end - w.start).toBeLessThanOrEqual(WINDOW_SECONDS * RATE);
      expect(w.end).toBeGreaterThan(w.start);
      windows.push([w.start, w.end]);
      pos = w.end;
    }
    expect(windows[0][0]).toBe(0);
    expect(windows[windows.length - 1][1]).toBe(total);
    for (let i = 1; i < windows.length; i++) expect(windows[i][0]).toBe(windows[i - 1][1]);
    // The pauses at 47.2 s and 76.9 s (250 ms each) are where the cuts land
    // (18.5 s is too early for the first window's search).
    expect(windows).toHaveLength(4);
    const cut = (i: number) => windows[i][1] / RATE;
    expect(cut(0)).toBeGreaterThanOrEqual(MIN_WINDOW_SECONDS);
    expect(cut(1)).toBeGreaterThanOrEqual(47.2);
    expect(cut(1)).toBeLessThanOrEqual(47.45);
    expect(cut(2)).toBeGreaterThanOrEqual(76.9);
    expect(cut(2)).toBeLessThanOrEqual(77.15);
  });
});
