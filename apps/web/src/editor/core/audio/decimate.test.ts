import { describe, expect, it } from "vitest";

import { DECIMATE_HALF, decimate48kTo16k, decimationInputSpan, decimationKernel, downmixStereo } from "./decimate";

const sine = (freq: number, n: number, rate = 48_000, amp = 1) =>
  Float32Array.from({ length: n }, (_, i) => amp * Math.sin((2 * Math.PI * freq * i) / rate));

const rmsOf = (x: Float32Array, from = 0, to = x.length) => {
  let s = 0;
  for (let i = from; i < to; i++) s += x[i] * x[i];
  return Math.sqrt(s / (to - from));
};

describe("48 kHz → 16 kHz decimation", () => {
  it("has unit DC gain and a symmetric kernel", () => {
    const h = decimationKernel();
    expect(h.length).toBe(2 * DECIMATE_HALF + 1);
    expect(h.reduce((a, b) => a + b, 0)).toBeCloseTo(1, 6);
    for (let i = 0; i < h.length; i++) expect(h[i]).toBeCloseTo(h[h.length - 1 - i], 7);
    const dc = decimate48kTo16k(new Float32Array(48_000).fill(0.5), 0, 1000, 100);
    for (const v of dc) expect(v).toBeCloseTo(0.5, 5);
  });

  it("passes speech-band tones and removes what would alias", () => {
    const n = 48_000;
    const pass = decimate48kTo16k(sine(1000, n), 0, 0, n / 3);
    // Away from the edges, a 1 kHz tone keeps its level (RMS of a unit sine = 1/√2).
    expect(rmsOf(pass, 200, 15_800)).toBeCloseTo(Math.SQRT1_2, 3);
    const db = (f: number) => 20 * Math.log10(rmsOf(decimate48kTo16k(sine(f, n), 0, 0, n / 3), 200, 15_800) / Math.SQRT1_2);
    expect(Math.abs(db(6500))).toBeLessThan(0.05); // flat through the speech band
    expect(db(7200)).toBeCloseTo(-6.02, 1); // the cutoff
    // What would fold back below 8 kHz is gone.
    expect(db(7800)).toBeLessThan(-60);
    expect(db(9000)).toBeLessThan(-85);
    expect(db(11_000)).toBeLessThan(-85);
  });

  it("is stateless: any split into windows gives bit-identical samples", () => {
    const src = Float32Array.from({ length: 30_000 }, (_, i) => Math.sin(i * 0.013) * 0.4 + Math.sin(i * 0.9) * 0.1);
    const whole = decimate48kTo16k(src, 0, 0, 10_000);
    const pieces: number[] = [];
    for (const [start, count] of [
      [0, 1234],
      [1234, 5000],
      [6234, 3766],
    ]) {
      const span = decimationInputSpan(start, count);
      const slice = src.slice(Math.max(0, span.start), span.end);
      pieces.push(...decimate48kTo16k(slice, Math.max(0, span.start), start, count));
    }
    expect(Float32Array.from(pieces)).toEqual(whole);
  });

  it("reads silence outside the input and averages stereo to mono", () => {
    const out = decimate48kTo16k(new Float32Array(0), 0, 0, 4);
    expect([...out]).toEqual([0, 0, 0, 0]);
    expect([...downmixStereo(Float32Array.of(1, 0.5, -1), Float32Array.of(0, 0.5, 1))]).toEqual([0.5, 0.5, 0]);
    const mono = Float32Array.of(0.25, -0.75);
    expect([...downmixStereo(mono, mono)]).toEqual([0.25, -0.75]);
  });
});
