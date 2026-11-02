/**
 * CameraMaskEdge (docs/camera-cutout.md §12.4) against hand-computed frames,
 * before the Mac's `cameraMaskEdge` golden vectors lock it to Swift
 * (core/vectors/cameraLooks.test.ts).
 *
 * Radii scale with the mask height (k = rows / 192): a 32-row mask has
 * k = 1/6, so a slider at 1.0 is a radius of exactly 1 — small enough to
 * work every pixel out by hand.
 */
import { describe, expect, it } from "vitest";
import { maskEdgeRadii, processMaskEdge } from "./maskEdge";

/** A width × height frame whose every row is `row`. */
function rows(row: number[], height: number): Uint8Array {
  const out = new Uint8Array(row.length * height);
  for (let y = 0; y < height; y++) out.set(row, y * row.length);
  return out;
}

function rowAt(a: Uint8Array, width: number, y: number): number[] {
  return [...a.subarray(y * width, (y + 1) * width)];
}

describe("maskEdgeRadii", () => {
  it("k = height / 192; round half up; clamped to 0…1", () => {
    expect(maskEdgeRadii(192, 1, 1)).toEqual({ inset: 6, softness: 6 });
    expect(maskEdgeRadii(192, 0.5, 0.25)).toEqual({ inset: 2, softness: 3 }); // 1.5 → 2
    expect(maskEdgeRadii(288, 1, 1)).toEqual({ inset: 9, softness: 9 });
    expect(maskEdgeRadii(288, 0.5, 0.5)).toEqual({ inset: 5, softness: 5 }); // 4.5 → 5
    expect(maskEdgeRadii(36, 1, 1)).toEqual({ inset: 1, softness: 1 }); // 1.125
    expect(maskEdgeRadii(32, 1, 0)).toEqual({ inset: 0, softness: 1 });
    expect(maskEdgeRadii(192, 2, -1)).toEqual({ inset: 0, softness: 6 });
    expect(maskEdgeRadii(192, Number.NaN, 0)).toEqual({ inset: 0, softness: 0 });
  });
});

describe("processMaskEdge", () => {
  it("identity: both radii 0 returns the frame itself (no copy)", () => {
    const a = rows([0, 255, 128, 255, 0], 32);
    expect(processMaskEdge(a, 5, 32, 0, 0)).toBe(a);
    // A tiny mask rounds every radius to 0: unchanged too.
    const tiny = rows([0, 255, 0], 8);
    expect(processMaskEdge(tiny, 3, 8, 1, 1)).toBe(tiny);
    // A malformed frame is never touched.
    expect(processMaskEdge(a, 4, 32, 1, 1)).toBe(a);
  });

  it("inset only: erode rows, then columns (min over ±i, clamp-to-edge)", () => {
    const out = processMaskEdge(rows([0, 255, 255, 255, 0], 32), 5, 32, 0, 1);
    for (let y = 0; y < 32; y++) expect(rowAt(out, 5, y)).toEqual([0, 0, 255, 0, 0]);
  });

  it("clamps to the edge: nothing outside the frame counts as 0", () => {
    const out = processMaskEdge(rows([255, 255, 0, 255, 255], 32), 5, 32, 0, 1);
    expect(rowAt(out, 5, 0)).toEqual([255, 0, 0, 0, 255]);
    expect(rowAt(out, 5, 31)).toEqual([255, 0, 0, 0, 255]);
  });

  it("the column pass erodes vertically (a 1-pixel-wide mask)", () => {
    const col = new Uint8Array(32);
    col.set([0, 255, 255, 255, 0]);
    const out = processMaskEdge(col, 1, 32, 0, 1);
    expect([...out.subarray(0, 6)]).toEqual([0, 0, 255, 0, 0, 0]);
  });

  it("rows then columns: one dark pixel erodes a 3×3 neighbourhood clipped to the frame", () => {
    const a = new Uint8Array(3 * 32).fill(255);
    a[1] = 0; // (x 1, y 0)
    const out = processMaskEdge(a, 3, 32, 0, 1);
    expect(rowAt(out, 3, 0)).toEqual([0, 0, 0]);
    expect(rowAt(out, 3, 1)).toEqual([0, 0, 0]);
    expect(rowAt(out, 3, 2)).toEqual([255, 255, 255]);
  });

  it("softness only: box blur rows, columns, rows, columns — (Σ + s) ÷ (2s + 1)", () => {
    // Pass 1 (rows): [0,0,255,0,0] → [0, 85, 85, 85, 0]   (256 ÷ 3 = 85)
    // Columns: constant, unchanged ((3·85 + 1) ÷ 3 = 85).
    // Pass 2 (rows): → [86÷3, 171÷3, 256÷3, 171÷3, 86÷3] = [28, 57, 85, 57, 28]
    const out = processMaskEdge(rows([0, 0, 255, 0, 0], 32), 5, 32, 1, 0);
    for (let y = 0; y < 32; y++) expect(rowAt(out, 5, y)).toEqual([28, 57, 85, 57, 28]);
  });

  it("both: erode first, then soften", () => {
    // Erode [0,255,255,255,0] → [0,0,255,0,0], then the softness case above.
    const out = processMaskEdge(rows([0, 255, 255, 255, 0], 32), 5, 32, 1, 1);
    expect(rowAt(out, 5, 7)).toEqual([28, 57, 85, 57, 28]);
    // Soften-then-erode would differ: the order is part of the contract.
    const reversed = processMaskEdge(processMaskEdge(rows([0, 255, 255, 255, 0], 32), 5, 32, 1, 0), 5, 32, 0, 1);
    expect(rowAt(reversed, 5, 7)).not.toEqual([28, 57, 85, 57, 28]);
  });

  it("k scaling: a 288-row mask erodes by 9 at inset 1, a 192-row one by 6", () => {
    const column = (height: number, from: number, to: number) => {
      const c = new Uint8Array(height);
      c.fill(255, from, to + 1);
      return c;
    };
    const tall = processMaskEdge(column(288, 100, 199), 1, 288, 0, 1);
    expect(tall.indexOf(255)).toBe(109);
    expect(tall.lastIndexOf(255)).toBe(190);
    const short = processMaskEdge(column(192, 100, 150), 1, 192, 0, 1);
    expect(short.indexOf(255)).toBe(106);
    expect(short.lastIndexOf(255)).toBe(144);
  });

  it("softness widens the edge: values strictly between 0 and 255 appear around a hard edge", () => {
    const hard = rows([...new Array(20).fill(0), ...new Array(20).fill(255)], 192);
    const soft = processMaskEdge(hard, 40, 192, 0.5, 0);
    const row = rowAt(soft, 40, 96);
    const ramp = row.filter((v) => v > 0 && v < 255).length;
    expect(ramp).toBeGreaterThan(4);
    expect(row[0]).toBe(0);
    expect(row[39]).toBe(255);
  });
});
