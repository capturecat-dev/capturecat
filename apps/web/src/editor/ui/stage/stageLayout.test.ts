import { describe, expect, it } from "vitest";

import { DEFAULT_EXPORT_SETTINGS } from "../../engine/contract";
import { canvasScaleFor, resolvedOutputSize } from "../../engine/layout";
import { backingDpr, clampPreviewZoom, engineViewport, MAX_BACKING_PIXELS, MAX_BACKING_SIDE, stageCanvasAspect, stageReferenceSize } from "./stageLayout";

const settings = (aspectRatio: string, e: Partial<typeof DEFAULT_EXPORT_SETTINGS> = {}) =>
  ({ aspectRatio, exportSettings: { ...DEFAULT_EXPORT_SETTINGS, collapseStaticSpans: false, ...e } }) as never;

describe("stage canvas aspect = the exported file's shape", () => {
  const source = { width: 3024, height: 1964 };

  it("Auto follows the source through resolvedOutputSize (even-rounded height)", () => {
    const out = resolvedOutputSize(DEFAULT_EXPORT_SETTINGS, "Auto", source);
    expect(stageCanvasAspect(settings("Auto"), source)).toBe(out.width / out.height);
    expect(out).toEqual({ width: 1920, height: 1248 });
  });

  it("re-letterboxes for every aspect / resolution / custom size", () => {
    expect(stageCanvasAspect(settings("9:16"), source)).toBe(1920 / 3414);
    expect(stageCanvasAspect(settings("4:5", { resolution: "4K" }), source)).toBe(3840 / 4800);
    // Custom ignores the aspect setting: the file is W × H.
    expect(stageCanvasAspect(settings("16:9", { resolution: "Custom", customWidth: 1000, customHeight: 1000 }), source)).toBe(1);
    expect(stageCanvasAspect(settings("16:9", { resolution: "Custom", customWidth: 1081, customHeight: 607 }), source)).toBe(1082 / 608);
  });

  it("before the source loads, Auto is 16:9 (the Mac's zero videoSize)", () => {
    expect(stageCanvasAspect(settings("Auto"), null)).toBe(1920 / 1080);
    expect(stageCanvasAspect(null, null)).toBe(16 / 9);
  });
});

describe("preview zoom is magnification only", () => {
  it("the reference is the unmagnified letterbox (previewCanvasSize)", () => {
    const wide = stageReferenceSize({ width: 1000, height: 500 }, 16 / 9);
    expect(wide.height).toBe(500);
    expect(wide.width).toBeCloseTo(500 * (16 / 9), 9);
    expect(stageReferenceSize({ width: 600, height: 800 }, 1)).toEqual({ width: 600, height: 600 });
  });

  it("canvasScale grows with the zoom, the reference does not", () => {
    const reference = { width: 800, height: 450 };
    for (const zoom of [0.25, 1, 4]) {
      const v = engineViewport({ cssWidth: 800 * zoom, cssHeight: 450 * zoom, dpr: 1, zoom, reference });
      expect(v.reference).toEqual(reference);
      const target = { width: Math.round(v.cssWidth * v.dpr), height: Math.round(v.cssHeight * v.dpr) };
      expect(canvasScaleFor(target, v.reference!)).toBeCloseTo(zoom, 12);
    }
  });

  it("without a reported reference, falls back to CSS ÷ zoom", () => {
    expect(engineViewport({ cssWidth: 1600, cssHeight: 900, dpr: 2, zoom: 2 }).reference).toEqual({ width: 800, height: 450 });
  });

  it("the backing store stays inside the GPU limits", () => {
    expect(backingDpr(900, 500, 2)).toBe(2);
    const d = backingDpr(4400, 2480, 2); // 400 % of a 1100×620 stage on Retina
    expect(Math.round(4400 * d)).toBeLessThanOrEqual(MAX_BACKING_SIDE);
    expect(4400 * d * 2480 * d).toBeLessThanOrEqual(MAX_BACKING_PIXELS + 1);
    expect(backingDpr(9000, 100, 1)).toBeCloseTo(MAX_BACKING_SIDE / 9000, 12);
  });

  it("clamps pinch zoom to 0.25…4", () => {
    expect(clampPreviewZoom(10)).toBe(4);
    expect(clampPreviewZoom(0.01)).toBe(0.25);
    expect(clampPreviewZoom(1.37)).toBe(1.37);
    expect(clampPreviewZoom(Number.NaN)).toBe(1);
  });
});
