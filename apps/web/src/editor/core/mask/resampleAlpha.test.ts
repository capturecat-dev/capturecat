import { describe, expect, it } from "vitest";
import { resampleAlpha } from "./resampleAlpha";

describe("resampleAlpha (area average)", () => {
  it("identity at the same size", () => {
    const src = Uint8Array.from({ length: 12 }, (_, i) => i * 20);
    expect([...resampleAlpha(src, 4, 3, 4, 3)]).toEqual([...src]);
  });

  it("2× box downscale averages each 2×2 cell", () => {
    const src = Uint8Array.from([0, 255, 100, 100, 255, 0, 100, 100, 10, 10, 0, 0, 30, 30, 0, 255]);
    expect([...resampleAlpha(src, 4, 4, 2, 2)]).toEqual([128, 100, 20, 64]);
  });

  it("non-integer ratios keep a flat field flat and preserve the mean", () => {
    const flat = new Uint8Array(910 * 512).fill(200);
    const out = resampleAlpha(flat, 910, 512, 512, 288);
    expect(out.every((v) => v === 200)).toBe(true);
    const half = new Uint8Array(900 * 10);
    for (let y = 0; y < 10; y++) for (let x = 450; x < 900; x++) half[y * 900 + x] = 255;
    const h = resampleAlpha(half, 900, 10, 512, 5);
    const mean = h.reduce((a, b) => a + b, 0) / h.length;
    expect(mean).toBeCloseTo(127.5, 0);
  });
});
