import { describe, expect, it } from "vitest";
import { multiplyRaster, rasterCoverageAt, sdRoundRect, type ShapeRaster } from "./shapes";
import { coverage, sdRoundRect as referenceSdRoundRect } from "./testing/cpuReference";

// The stitched-device-segment screen mask is the segment squircle × the outer
// frame clip, combined on the CPU into one raster (StaticLayers.bakeSegment).
// These pin the combiner to the shader twins it replaces.

describe("segment mask combiner", () => {
  it("sdRoundRect matches the CPU reference of WGSL sdRoundRect", () => {
    const rect = { x: 101.3, y: 57.8, width: 640.25, height: 360.5 };
    let seed = 7;
    const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
    for (let k = 0; k < 2000; k++) {
      const x = rect.x - 20 + rnd() * (rect.width + 40);
      const y = rect.y - 20 + rnd() * (rect.height + 40);
      const r = rnd() * 60;
      expect(sdRoundRect(x, y, rect, r)).toBe(referenceSdRoundRect(x, y, rect, r));
    }
  });

  it("rasterCoverageAt reads the texel under a pixel centre, 0 outside", () => {
    const raster: ShapeRaster = { originX: 10, originY: 20, width: 3, height: 2, coverage: new Uint8Array([0, 51, 102, 153, 204, 255]) };
    expect(rasterCoverageAt(raster, 10.5, 20.5)).toBe(0);
    expect(rasterCoverageAt(raster, 11.5, 20.5)).toBeCloseTo(0.2, 12);
    expect(rasterCoverageAt(raster, 12.5, 21.5)).toBe(1);
    expect(rasterCoverageAt(raster, 9.5, 20.5)).toBe(0);
    expect(rasterCoverageAt(raster, 13.5, 20.5)).toBe(0);
    expect(rasterCoverageAt(raster, 10.5, 22.5)).toBe(0);
  });

  it("multiplyRaster multiplies at texel centres and leaves the input untouched", () => {
    const raster: ShapeRaster = { originX: 4, originY: 8, width: 4, height: 1, coverage: new Uint8Array([255, 255, 128, 0]) };
    const seen: [number, number][] = [];
    const out = multiplyRaster(raster, (x, y) => {
      seen.push([x, y]);
      return x < 6 ? 1 : 0.5;
    });
    expect(Array.from(out.coverage)).toEqual([255, 255, 64, 0]);
    expect(Array.from(raster.coverage)).toEqual([255, 255, 128, 0]);
    // Zero texels are skipped; centres are pixel centres in target space.
    expect(seen).toEqual([[4.5, 8.5], [5.5, 8.5], [6.5, 8.5]]);
    expect(out.originX).toBe(4);
    expect(out.originY).toBe(8);
  });

  it("an outer rounded-rect clip reproduces the shader's coverageFromSd at a straight edge", () => {
    const rect = { x: 10.25, y: 0, width: 20, height: 40 };
    const raster: ShapeRaster = { originX: 8, originY: 10, width: 6, height: 1, coverage: new Uint8Array(6).fill(255) };
    const out = multiplyRaster(raster, (x, y) => coverage(sdRoundRect(x, y, rect, 4)));
    // Left edge at x = 10.25: pixel 10 is 0.75 covered, 9 and 8 are outside.
    expect(Array.from(out.coverage)).toEqual([0, 0, Math.round(255 * 0.75), 255, 255, 255]);
  });
});
