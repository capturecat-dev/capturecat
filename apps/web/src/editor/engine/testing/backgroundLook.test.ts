/**
 * The background LOOK chain (pixelate → halftone → blur → colour controls →
 * hue → tint → vignette → 8-bit → grain) against REAL Mac bitmaps: the
 * `backgroundLookStyledPixels` vectors carry, per case, samples of the bitmap
 * `BackgroundLook.cgImage(for:size:scale:)` returned (`input.gpuTargets`).
 * `backgroundLookReference` is the executable spec the WebGPU bake follows
 * pass for pass (the GPU bake itself, run over these same cases in headless
 * Chrome at each case's pixel size: mean 0.143/255, p99 2 — 2026-09-30).
 *
 * Tolerances: the base fill is a CoreGraphics raster whose gradients are
 * DITHERED by sample-position jitter (style.test.ts: up to 11–16/255 at a
 * centre sample in steep ramps); filters that amplify contrast (contrast,
 * halftone thresholds, saturation) amplify that dither. So the gate is on the
 * MEAN error per case plus a loose per-sample max, and the aggregate p99.
 */
import { describe, expect, it } from "vitest";
import { loadVectors } from "../../core/vectors/harness";
import * as BL from "../../core/math/backgroundLook";
import { backgroundLookReference } from "./backgroundLookReference";

interface Sample {
  x: number;
  y: number;
  rgba: number[];
}

describe("background look vs real Mac bitmaps", () => {
  it("backgroundLookStyledPixels gpuTargets", () => {
    const file = loadVectors("backgroundLookStyledPixels");
    const all: number[] = [];
    const rows: string[] = [];
    let worstMean = 0;
    file.cases.forEach((c, n) => {
      const spec = BL.specFromSettings(c.input.settings);
      const ref = backgroundLookReference(spec, c.input.size, c.input.scale);
      const t = c.input.gpuTargets as { width: number; height: number; samples: Sample[] } | null;
      if (!t || !ref) {
        expect(!!ref, `case ${n}: nil`).toBe(!!t);
        return;
      }
      expect([ref.width, ref.height], `case ${n}: size`).toEqual([t.width, t.height]);
      let sum = 0;
      let cnt = 0;
      let max = 0;
      for (const s of t.samples) {
        const o = (s.y * ref.width + s.x) * 4;
        for (let k = 0; k < 4; k++) {
          const d = Math.abs(ref.rgba[o + k] - s.rgba[k]);
          all.push(d);
          sum += d;
          cnt++;
          max = Math.max(max, d);
        }
      }
      const mean = sum / cnt;
      worstMean = Math.max(worstMean, mean);
      rows.push(`#${n} ${spec.type} ${t.width}x${t.height}@${c.input.scale} mean ${mean.toFixed(2)} max ${max}`);
    });
    all.sort((a, b) => a - b);
    const p99 = all[Math.floor(all.length * 0.99)];
    const mean = all.reduce((s, v) => s + v, 0) / all.length;
    // eslint-disable-next-line no-console
    console.log(`styled look: ${all.length} channel samples, mean ${mean.toFixed(3)}, p99 ${p99}, max ${all.at(-1)}, worst case mean ${worstMean.toFixed(2)}\n${rows.join("\n")}`);
    // Measured: mean 0.14, p99 2, worst case mean 0.86 (80 cases, 20 160 channel samples).
    expect(mean).toBeLessThan(0.3);
    expect(p99).toBeLessThanOrEqual(3);
    expect(worstMean).toBeLessThan(1.5);
  });
});
