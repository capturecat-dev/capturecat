/**
 * Hit zones + drag math of the stage surface against the Mac's
 * PreviewInteractionView numbers (content points × u card px), including a
 * pointer → card → hit round trip through zoomed / tilted cameras.
 */
import { describe, expect, it } from "vitest";

import type { Annotation, Rect } from "../../core/model";
import { projectionTransform } from "../../core/math/tiltMath";
import { invert, multiply, scaleAbout, translate, type Mat3 } from "../../engine/mat3";
import {
  adjustRegionRect,
  annotationHandleHit,
  annotationHitRect,
  blurDrawRect,
  focalHit,
  handleDragPatch,
  isActiveAt,
  movedAnnotation,
  normalizedVideoPoint,
  regionHit,
  regionPillHitRect,
  regionPillLayout,
  regionPixelRect,
  sliderFraction,
  sliderValue,
  type HitGeometry,
} from "./stageGeometry";
import { canvasToCard, cardToCanvas } from "./stageMapping";

const G1: HitGeometry = { videoRect: { x: 100, y: 50, width: 800, height: 450 }, u: 1 };
const G2: HitGeometry = { videoRect: { x: 200, y: 100, width: 1600, height: 900 }, u: 2 };

function ann(p: Partial<Annotation>): Annotation {
  return {
    id: "a",
    type: "rectangle",
    startTime: 0,
    endTime: 5,
    x: 0.2,
    y: 0.2,
    arrowEndX: 0.5,
    arrowEndY: 0.6,
    text: "Hello",
    fontSize: 24,
    showBackground: true,
    color: { red: 1, green: 1, blue: 1, opacity: 1 },
    backgroundColor: { red: 0, green: 0, blue: 0, opacity: 0.7 },
    lineWidth: 3,
    drawingStrokes: [],
    fontWeight: "Semibold",
    uppercase: false,
    opacity: 1,
    cornerRadius: 8,
    animatesIn: true,
    showShadow: false,
    enterEffect: "None",
    exitEffect: "None",
    backdropOpacity: 0,
    ...p,
  } as Annotation;
}

describe("region hit zones (regionDragMode)", () => {
  const norm: Rect = { x: 0.25, y: 0.2, width: 0.4, height: 0.3 };

  it("scales every Mac metric by u", () => {
    for (const g of [G1, G2]) {
      const r = regionPixelRect(norm, g);
      const u = g.u;
      // Unselected: body only; corner zones are inert.
      expect(regionHit({ x: r.x + r.width / 2, y: r.y + r.height / 2 }, norm, false, g)).toEqual({ kind: "move" });
      expect(regionHit({ x: r.x - 6 * u, y: r.y - 6 * u }, norm, false, g)).toBeNull();
      // Selected: 24pt corner zones centred on the corners.
      expect(regionHit({ x: r.x - 11 * u, y: r.y - 11 * u }, norm, true, g)).toEqual({ kind: "resize", left: true, right: false, top: true, bottom: false });
      expect(regionHit({ x: r.x + r.width + 11 * u, y: r.y + r.height - 11 * u }, norm, true, g)).toEqual({ kind: "resize", left: false, right: true, top: false, bottom: true });
      expect(regionHit({ x: r.x - 13 * u, y: r.y - 13 * u }, norm, true, g)).toBeNull();
      // 18pt edge strips (inset 16pt from the corners along the edge).
      expect(regionHit({ x: r.x + r.width / 2, y: r.y - 8 * u }, norm, true, g)).toEqual({ kind: "resize", left: false, right: false, top: true, bottom: false });
      expect(regionHit({ x: r.x + r.width + 8 * u, y: r.y + r.height / 2 }, norm, true, g)).toEqual({ kind: "resize", left: false, right: true, top: false, bottom: false });
      // The Mac pill hit rect (below the region, 8pt gap, 26pt tall).
      const pill = regionPillHitRect(r, g);
      expect(pill.y).toBeCloseTo(r.y + r.height + 8 * u, 9);
      expect(pill.height).toBeCloseTo(26 * u, 9);
      const hit = regionHit({ x: pill.x + pill.width / 2, y: pill.y + 5 * u }, norm, true, g);
      expect(hit?.kind).toBe("slider");
      if (hit?.kind === "slider") expect(hit.track.width).toBeCloseTo(pill.width - 54 * u, 9);
    }
  });

  it("enforces the 30×20pt minimum pixel rect", () => {
    const tiny: Rect = { x: 0.5, y: 0.5, width: 0.001, height: 0.001 };
    const r = regionPixelRect(tiny, G2);
    expect(r.width).toBe(60);
    expect(r.height).toBe(40);
  });

  it("flips the pill inside the bottom edge when it does not fit below, and clamps it horizontally", () => {
    const low: Rect = { x: 0.9, y: 0.8, width: 0.1, height: 0.2 };
    const r = regionPixelRect(low, G1);
    const pill = regionPillHitRect(r, G1);
    expect(pill.y).toBeCloseTo(r.y + r.height - 8 - 26, 9);
    expect(pill.x + pill.width).toBeLessThanOrEqual(G1.videoRect.x + G1.videoRect.width + 1e-9);
    // The drawn pill (SelectionChromeKit): centred 8pt past the region's bottom edge
    // when below, and it also accepts the slider (web extension, outside the Mac zones).
    const mid: Rect = { x: 0.45, y: 0.2, width: 0.05, height: 0.2 };
    const rm = regionPixelRect(mid, G1);
    const layout = regionPillLayout(rm, G1, "eye", "eye.slash.fill");
    expect(layout.pill.y + layout.pill.height / 2).toBeCloseTo(rm.y + rm.height + 8, 9);
    const probe = { x: layout.pill.x + 3, y: layout.pill.y + 3 };
    expect(regionHit(probe, mid, true, G1)).toBeNull();
    expect(regionHit(probe, mid, true, G1, { leading: "eye", trailing: "eye.slash.fill" })?.kind).toBe("slider");
  });

  it("maps the slider like the Mac (blur/focus 0.1…1, highlight 0.1…0.9)", () => {
    const track = { minX: 100, width: 150 };
    expect(sliderFraction(50, track)).toBe(0);
    expect(sliderFraction(400, track)).toBe(1);
    expect(sliderValue("blur", sliderFraction(175, track))).toBeCloseTo(0.55, 12);
    expect(sliderValue("highlight", 1)).toBeCloseTo(0.9, 12);
    expect(sliderValue("focus", 0)).toBeCloseTo(0.1, 12);
  });

  it("adjust(): move clamps inside the video, resize keeps the 0.04 minimum", () => {
    const init: Rect = { x: 0.7, y: 0.1, width: 0.2, height: 0.3 };
    const none = { left: false, right: false, top: false, bottom: false };
    expect(adjustRegionRect(init, 0.5, -0.5, none, true)).toEqual({ x: 0.8, y: 0, width: 0.2, height: 0.3 });
    const r = adjustRegionRect(init, 0.5, 0, { ...none, left: true }, false);
    expect(r.x).toBeCloseTo(0.86, 12);
    expect(r.width).toBeCloseTo(0.04, 12);
    const b = adjustRegionRect(init, 0, 5, { ...none, bottom: true }, false);
    expect(b.y + b.height).toBe(1);
  });
});

describe("annotation hit zones", () => {
  it("handle radius shrinks with small shapes (min(12, max(5, min(w,h)/4)))", () => {
    const big = ann({ x: 0.1, y: 0.1, arrowEndX: 0.6, arrowEndY: 0.7 });
    const vr = G1.videoRect;
    const tl = { x: vr.x + 0.1 * vr.width, y: vr.y + 0.1 * vr.height };
    expect(annotationHandleHit(big, { x: tl.x + 11.9, y: tl.y }, G1)).toEqual({ xIsStart: true, yIsStart: true });
    expect(annotationHandleHit(big, { x: tl.x + 12.1, y: tl.y }, G1)).toBeNull();
    const small = ann({ x: 0.1, y: 0.1, arrowEndX: 0.13, arrowEndY: 0.14 }); // 24 × 18 px → radius 5
    expect(annotationHandleHit(small, { x: tl.x + 4.9, y: tl.y }, G1)).not.toBeNull();
    expect(annotationHandleHit(small, { x: tl.x + 5.5, y: tl.y }, G1)).toBeNull();
    const br = { x: vr.x + 0.13 * vr.width, y: vr.y + 0.14 * vr.height };
    expect(annotationHandleHit(small, br, G1)).toEqual({ xIsStart: false, yIsStart: false });
    // Arrow: head before tail.
    const arrow = ann({ type: "arrow", x: 0.5, y: 0.5, arrowEndX: 0.5, arrowEndY: 0.5 + 1e-9 });
    expect(annotationHandleHit(arrow, { x: vr.x + 0.5 * vr.width, y: vr.y + 0.5 * vr.height }, G1)).toEqual({ xIsStart: false, yIsStart: false });
    // Text has no handles.
    expect(annotationHandleHit(ann({ type: "text" }), tl, G1)).toBeNull();
  });

  it("hit rects: shapes pad 10pt, arrows/callouts 16pt, tap max(24, fontSize), drawing ink bbox + 12pt", () => {
    const vr = G2.videoRect;
    const shape = annotationHitRect(ann({ x: 0.1, y: 0.2, arrowEndX: 0.3, arrowEndY: 0.4 }), G2, () => null);
    expect(shape.x).toBeCloseTo(vr.x + 0.1 * vr.width - 20, 9);
    expect(shape.width).toBeCloseTo(0.2 * vr.width + 40, 9);
    const arrow = annotationHitRect(ann({ type: "arrow", x: 0.3, y: 0.4, arrowEndX: 0.1, arrowEndY: 0.2 }), G2, () => null);
    expect(arrow.x).toBeCloseTo(vr.x + 0.1 * vr.width - 32, 9);
    const tap = annotationHitRect(ann({ type: "tap", fontSize: 30 }), G2, () => null);
    expect(tap.width).toBeCloseTo(120, 9);
    const drawing = annotationHitRect(ann({ type: "drawing", drawingStrokes: [[{ x: 0.2, y: 0.3 }, { x: 0.4, y: 0.5 }]] }), G2, () => null);
    expect(drawing.x).toBeCloseTo(vr.x + 0.2 * vr.width - 24, 9);
    expect(drawing.height).toBeCloseTo(0.2 * vr.height + 48, 9);
    const fresh = annotationHitRect(ann({ type: "drawing", drawingStrokes: [] }), G2, () => null);
    expect(fresh).toEqual(vr);
    const pill = { x: 500, y: 300, width: 120, height: 40 };
    const text = annotationHitRect(ann({ type: "text" }), G2, () => pill);
    expect(text).toEqual({ x: 484, y: 284, width: 152, height: 72 });
  });

  it("two-point shapes move as a unit, clamped so their size never changes", () => {
    const m = movedAnnotation("rectangle", { x: 0.6, y: 0.2 }, { x: 0.9, y: 0.5 }, 0.3, -0.5);
    expect(m.x).toBeCloseTo(0.7, 12);
    expect(m.arrowEndX).toBeCloseTo(1, 12);
    expect(m.y).toBeCloseTo(0, 12);
    expect(m.arrowEndY).toBeCloseTo(0.3, 12);
    const t = movedAnnotation("text", { x: 0.9, y: 0.1 }, { x: 0, y: 0 }, 0.3, -0.3);
    expect(t).toEqual({ x: 1, y: 0 });
  });

  it("handle drags ride the cursor (position, not delta)", () => {
    const vr = G1.videoRect;
    const patch = handleDragPatch({ x: vr.x + vr.width * 0.25, y: vr.y + vr.height * 1.5 }, G1, { xIsStart: false, yIsStart: true });
    expect(patch).toEqual({ arrowEndX: 0.25, y: 1 });
  });
});

describe("blur draw + focal target", () => {
  it("drag rect, click growth to 2× the minimum, clipping", () => {
    const drag = blurDrawRect({ x: 0.2, y: 0.3 }, { x: 0.5, y: 0.6 })!;
    expect(drag.x).toBeCloseTo(0.2, 12);
    expect(drag.y).toBeCloseTo(0.3, 12);
    expect(drag.width).toBeCloseTo(0.3, 12);
    expect(drag.height).toBeCloseTo(0.3, 12);
    const click = blurDrawRect({ x: 0.5, y: 0.5 }, { x: 0.5, y: 0.5 })!;
    expect(click.width).toBeCloseTo(0.08, 12);
    expect(click.x).toBeCloseTo(0.46, 12);
    const corner = blurDrawRect({ x: 1, y: 1 }, { x: 1, y: 1 })!;
    expect(corner.width).toBeCloseTo(0.04, 12);
    expect(corner.x + corner.width).toBe(1);
  });

  it("focal grab radius is 22pt / max(1, zoom) in content space", () => {
    const vr = G2.videoRect;
    const c = { x: vr.x + 0.5 * vr.width, y: vr.y + 0.5 * vr.height };
    expect(focalHit({ x: c.x + 43, y: c.y }, { x: 0.5, y: 0.5 }, G2, 1)).toBe(true);
    expect(focalHit({ x: c.x + 45, y: c.y }, { x: 0.5, y: 0.5 }, G2, 1)).toBe(false);
    expect(focalHit({ x: c.x + 21, y: c.y }, { x: 0.5, y: 0.5 }, G2, 2)).toBe(true);
    expect(focalHit({ x: c.x + 23, y: c.y }, { x: 0.5, y: 0.5 }, G2, 2)).toBe(false);
  });

  it("normalizedVideoPoint clamps to the video", () => {
    expect(normalizedVideoPoint({ x: 0, y: 1e6 }, G1)).toEqual({ x: 0, y: 1 });
    expect(isActiveAt({ startTime: 1, endTime: 2 }, 2)).toBe(true);
    expect(isActiveAt({ startTime: 1, endTime: 2 }, 2.0001)).toBe(false);
  });
});

describe("hit-testing follows the camera (pointer → card → zone)", () => {
  const toMat3 = (h: ReturnType<typeof projectionTransform>): Mat3 => [h.m11, h.m21, h.m31, h.m12, h.m22, h.m32, h.m13, h.m23, h.m33];
  const cameras: Array<[string, Mat3]> = [
    ["identity", [1, 0, 0, 0, 1, 0, 0, 0, 1]],
    ["zoom 2.4 about a focal point + offset", multiply(translate(-180, 95), scaleAbout(2.4, 620, 330))],
    ["zoom 1.6 + tilt 18/−12/5", multiply(scaleAbout(1.6, 500, 280), toMat3(projectionTransform(18, -12, 5, { x: 500, y: 275 }, 2200)))],
  ];
  const norm: Rect = { x: 0.3, y: 0.25, width: 0.35, height: 0.3 };

  for (const [name, H] of cameras) {
    it(`${name}: pointer on a drawn corner resizes, on the body moves`, () => {
      const inv = invert(H);
      const r = regionPixelRect(norm, G1);
      // Where the pixels are: the corner and the body centre projected by the camera.
      const cornerOnScreen = cardToCanvas(H, { x: r.x + 1, y: r.y + 1 });
      const bodyOnScreen = cardToCanvas(H, { x: r.x + r.width / 2, y: r.y + r.height / 2 });
      expect(regionHit(canvasToCard(inv, cornerOnScreen), norm, true, G1)).toEqual({ kind: "resize", left: true, right: false, top: true, bottom: false });
      expect(regionHit(canvasToCard(inv, bodyOnScreen), norm, true, G1)).toEqual({ kind: "move" });
      // Annotation handle at the shape's BR corner.
      const a = ann({ x: 0.2, y: 0.2, arrowEndX: 0.6, arrowEndY: 0.7 });
      const vr = G1.videoRect;
      const br = cardToCanvas(H, { x: vr.x + 0.6 * vr.width + 2, y: vr.y + 0.7 * vr.height - 2 });
      expect(annotationHandleHit(a, canvasToCard(inv, br), G1)).toEqual({ xIsStart: false, yIsStart: false });
    });
  }
});
