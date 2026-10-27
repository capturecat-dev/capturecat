import { describe, expect, it } from "vitest";
import {
  conditionAlpha,
  NO_ALPHA_CONDITIONING,
  PRODUCER_ALPHA_CONDITIONING,
  PRODUCER_KEYFRAME_INTERVAL,
  producerMaskSize,
  quantizeAlpha,
} from "./conditionAlpha";

/**
 * The SAME three frames and expected outputs as the Mac's `--cameralayout-test`
 * (CameraLayoutHarness+Looks.swift `conditioningFixture`), derived from the
 * contract's integer formulas (docs/camera-cutout.md §6) — the two producers
 * must write identical bytes for identical mattes.
 */
const FIXTURE: Array<{ raw: number[]; expected: number[] }> = [
  {
    raw: [0, 5, 15, 16, 17, 30, 60, 100, 128, 150, 200, 238, 239, 240, 250, 255],
    expected: [0, 0, 0, 0, 0, 36, 73, 109, 146, 146, 182, 255, 255, 255, 255, 255],
  },
  {
    raw: [3, 20, 40, 10, 50, 70, 64, 140, 120, 185, 230, 255, 220, 200, 255, 245],
    expected: [0, 0, 36, 0, 36, 73, 73, 109, 146, 182, 219, 255, 219, 182, 255, 255],
  },
  {
    raw: [60, 0, 0, 90, 18, 33, 100, 160, 200, 120, 170, 250, 200, 239, 100, 254],
    expected: [73, 0, 0, 73, 36, 36, 73, 146, 182, 109, 182, 255, 219, 255, 109, 255],
  },
];

describe("producer alpha conditioning (twin of CameraMaskConditioning.swift)", () => {
  it("uses the contract's constants", () => {
    expect({ ...PRODUCER_ALPHA_CONDITIONING }).toEqual({ deadZone: 16, levels: 8, hold: 32 });
    expect(PRODUCER_KEYFRAME_INTERVAL).toBe(30);
  });

  it("8 levels: 0, 36, 73, 109, 146, 182, 219, 255", () => {
    const levels = [...new Set(Array.from({ length: 256 }, (_, v) => quantizeAlpha(v, 8)))].sort((a, b) => a - b);
    expect(levels).toEqual([0, 36, 73, 109, 146, 182, 219, 255]);
    // 16 levels are exact multiples of 17.
    for (let v = 0; v < 256; v++) expect(quantizeAlpha(v, 16) % 17).toBe(0);
    expect(quantizeAlpha(123, 256)).toBe(123);
  });

  it("matches the Swift fixture frame for frame (dead zone, hold vs previous OUTPUT, quantise)", () => {
    let previous: Uint8Array | null = null;
    for (const frame of FIXTURE) {
      const out = conditionAlpha(Uint8Array.from(frame.raw), previous);
      expect([...out]).toEqual(frame.expected);
      previous = out;
    }
  });

  it("the no-op rule is the identity", () => {
    const raw = Uint8Array.from(FIXTURE[0]!.raw);
    expect([...conditionAlpha(raw.slice(), null, NO_ALPHA_CONDITIONING)]).toEqual([...raw]);
  });

  it("±3-level flicker on a still frame repeats the previous output exactly (so XOR deltas win)", () => {
    const a = conditionAlpha(Uint8Array.from(FIXTURE[1]!.raw), null);
    const b = conditionAlpha(Uint8Array.from(FIXTURE[1]!.raw.map((v) => Math.min(255, v + 3))), a);
    expect([...b]).toEqual([...a]);
  });

  it("producer mask size: 192 rows, width round(192 × aspect) capped at 341", () => {
    expect(producerMaskSize(16 / 9)).toEqual({ width: 341, height: 192 });
    expect(producerMaskSize(4 / 3)).toEqual({ width: 256, height: 192 });
    expect(producerMaskSize(9 / 16)).toEqual({ width: 108, height: 192 });
    expect(producerMaskSize(3).width).toBe(341);
  });
});
