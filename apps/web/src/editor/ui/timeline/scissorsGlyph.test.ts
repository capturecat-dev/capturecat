import { describe, expect, it } from "vitest";

import { SNIP_DURATION, scissorsWidth, snipState, stripGap } from "./scissorsGlyph";

describe("ScissorsGlyph snip timing (the Mac's snipState / stripGap)", () => {
  it("closes over the first third, re-parts elastically, then fades", () => {
    expect(snipState(0)).toEqual({ open: 1, travel: 0, alpha: 1 });
    // Mid-close: p = 0.165 → closeP 0.5 → eased 0.5.
    const mid = snipState(0.165 * SNIP_DURATION);
    expect(mid.open).toBeCloseTo(0.5, 12);
    expect(mid.alpha).toBe(1);
    // Closed at p = 0.33.
    expect(snipState(0.33 * SNIP_DURATION).open).toBeCloseTo(0, 12);
    // The re-part: w = 0.25 → 0.12·sin(π/2)·e^(−0.75).
    const w = 0.25;
    expect(snipState((0.33 + w * 0.67) * SNIP_DURATION).open).toBeCloseTo(0.12 * Math.exp(-3 * w), 12);
    // Negative wiggle clamps to 0.
    expect(snipState((0.33 + 0.75 * 0.67) * SNIP_DURATION).open).toBe(0);
    // Fade from p = 0.6.
    expect(snipState(0.8 * SNIP_DURATION).alpha).toBeCloseTo(0.5, 12);
    expect(snipState(SNIP_DURATION)).toEqual({ open: 0, travel: 1, alpha: 0 });
    expect(snipState(0.5 * SNIP_DURATION).travel).toBeCloseTo(0.5, 12);
  });

  it("the strips part with the cut and breathe shut", () => {
    expect(stripGap(0, 5)).toBe(0);
    expect(stripGap(SNIP_DURATION / 2, 5)).toBeCloseTo(5, 12);
    expect(stripGap(SNIP_DURATION, 5)).toBeCloseTo(0, 12);
    expect(stripGap(10, 5)).toBeCloseTo(0, 12);
  });

  it("the glyph is 0.95 × its height wide", () => {
    expect(scissorsWidth(24)).toBeCloseTo(22.8, 12);
  });
});
