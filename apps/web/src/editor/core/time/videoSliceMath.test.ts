import { describe, expect, it } from "vitest";

import { isSliceable, resolvedSliceTarget } from "./videoSliceMath";

describe("VideoSliceMath", () => {
  it("snaps onto the playhead within 12 pt, else maps x → output time", () => {
    expect(resolvedSliceTarget(505, 1000, 20, 10)).toEqual({ outputTime: 10, x: 500, snappedToPlayhead: true });
    expect(resolvedSliceTarget(250, 1000, 20, 10)).toEqual({ outputTime: 5, x: 250, snappedToPlayhead: false });
    expect(resolvedSliceTarget(-40, 1000, 20, 10).x).toBe(0);
    expect(resolvedSliceTarget(10, 0, 20, 10)).toEqual({ outputTime: 0, x: 0, snappedToPlayhead: false });
  });

  it("needs 0.2 s on both sides of the cut, inside the trim window and a clip", () => {
    const clips = [
      { id: "a", outputStart: 0, outputEnd: 5 },
      { id: "b", outputStart: 6, outputEnd: 10 },
    ];
    expect(isSliceable(2, 0, 10, clips)).toBe(true);
    expect(isSliceable(0.2, 0, 10, clips)).toBe(false); // not strictly past trim start + 0.2
    expect(isSliceable(4.8, 0, 10, clips)).toBe(true); // exactly 0.2 from the clip end (>=)
    expect(isSliceable(5.5, 0, 10, clips)).toBe(false); // in the gap
    expect(isSliceable(9.9, 0, 10, clips)).toBe(false);
  });
});
