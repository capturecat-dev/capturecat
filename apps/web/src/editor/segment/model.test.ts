import { describe, expect, it } from "vitest";

import { MATTE_HIGH, MATTE_LOW, personAlpha } from "./model";

describe("personAlpha (MediaPipe background confidence → person alpha)", () => {
  it("clears a background the segmenter is only mostly sure of — no ghost of the room", () => {
    // Background confidence ~0.9 (person ~0.1): measured on a real take, it left 14 % opacity.
    expect([...personAlpha(new Float32Array([1, 0.95, 0.9, 1 - MATTE_LOW]))]).toEqual([0, 0, 0, 0]);
  });

  it("keeps the person solid and the edge soft and monotonic", () => {
    expect([...personAlpha(new Float32Array([0, 0.05, 1 - MATTE_HIGH]))]).toEqual([255, 255, 255]);
    const ramp = personAlpha(new Float32Array(Array.from({ length: 21 }, (_, i) => 1 - i / 20)));
    for (let i = 1; i < ramp.length; i++) expect(ramp[i]!).toBeGreaterThanOrEqual(ramp[i - 1]!);
    // Halfway stays halfway (127.5, float-rounded either side).
    expect(Math.abs(personAlpha(new Float32Array([0.5]))[0]! - 127.5)).toBeLessThanOrEqual(0.5);
  });
});
