/**
 * Chrome lands where the camera puts the region: the region outline traced
 * on the overlay must hug the camera-projected region rect (identity, zoom +
 * offset, zoom + tilt), and every chrome path runs for projective cameras.
 * A recording mock stands in for CanvasRenderingContext2D (vitest is Node).
 */
import { describe, expect, it } from "vitest";

import type { Annotation, Rect } from "../../core/model";
import { projectionTransform } from "../../core/math/tiltMath";
import { multiply, scaleAbout, translate, type Mat3 } from "../../engine/mat3";
import { DEFAULT_THEME, drawAnnotationChrome, drawFocalReticle, drawMarquee, drawRegionChrome, type ChromeFrame } from "./stageChrome";
import { regionPixelRect } from "./stageGeometry";
import { boundsOf, cardToCanvas, projectRect } from "./stageMapping";

type Call = { name: string; args: number[]; transform: number[] };

function mockCtx() {
  const calls: Call[] = [];
  let transform = [1, 0, 0, 1, 0, 0];
  const stack: number[][] = [];
  const state: Record<string, unknown> = { globalAlpha: 1, lineWidth: 1 };
  const methods: Record<string, (...a: number[]) => void> = {
    setTransform: (...a) => {
      transform = a.slice(0, 6);
    },
    save: () => void stack.push(transform),
    restore: () => {
      transform = stack.pop() ?? transform;
    },
  };
  const ctx = new Proxy(state, {
    get(t, k: string) {
      if (k in methods) return methods[k];
      if (k in t) return t[k];
      return (...args: number[]) => void calls.push({ name: k, args, transform });
    },
    set(t, k: string, v) {
      t[k] = v;
      return true;
    },
  });
  return { ctx: ctx as unknown as CanvasRenderingContext2D, calls };
}

const toMat3 = (h: ReturnType<typeof projectionTransform>): Mat3 => [h.m11, h.m21, h.m31, h.m12, h.m22, h.m32, h.m13, h.m23, h.m33];
const videoRect: Rect = { x: 120, y: 80, width: 1600, height: 900 };
const cameras: Array<[string, Mat3]> = [
  ["identity", [1, 0, 0, 0, 1, 0, 0, 0, 1]],
  ["zoom 1.8 + offset", multiply(translate(-140, 60), scaleAbout(1.8, 900, 500))],
  ["zoom 1.3 + tilt", multiply(scaleAbout(1.3, 920, 530), toMat3(projectionTransform(16, -20, 4, { x: 920, y: 530 }, 3200)))],
];

describe("stage chrome follows the camera", () => {
  const norm: Rect = { x: 0.3, y: 0.25, width: 0.3, height: 0.35 };

  for (const [name, camera] of cameras) {
    it(`${name}: the region outline hugs the projected region rect`, () => {
      const f: ChromeFrame = { camera, videoRect, u: 2 };
      const { ctx, calls } = mockCtx();
      drawRegionChrome(ctx, f, DEFAULT_THEME, { rect: norm, cornerRadius: 20, sliderValue: 0.5, sliderRange: [0.1, 1], leadingIcon: "eye", trailingIcon: "eye.slash.fill" });
      // The outline is the first traced path drawn under the identity transform
      // after the clip (strokeCardPath traces in canvas px).
      const clipIdx = calls.findIndex((c) => c.name === "clip");
      const strokeIdx = calls.findIndex((c, i) => i > clipIdx && c.name === "stroke");
      const pts: Array<{ x: number; y: number }> = [];
      for (const c of calls.slice(clipIdx + 1, strokeIdx)) {
        if (c.name === "moveTo" || c.name === "lineTo") pts.push({ x: c.args[0], y: c.args[1] });
        if (c.name === "bezierCurveTo") pts.push({ x: c.args[4], y: c.args[5] });
      }
      expect(pts.length).toBeGreaterThan(4);
      const drawn = boundsOf(pts);
      const r = regionPixelRect(norm, f);
      const expected = boundsOf(projectRect({ x: r.x + 2, y: r.y + 2, width: r.width - 4, height: r.height - 4 }, camera));
      // Continuous corners pull the curve inside the corners; edges must coincide.
      expect(Math.abs(drawn.x - expected.x)).toBeLessThan(3);
      expect(Math.abs(drawn.y - expected.y)).toBeLessThan(3);
      expect(Math.abs(drawn.x + drawn.width - (expected.x + expected.width))).toBeLessThan(3);
      expect(Math.abs(drawn.y + drawn.height - (expected.y + expected.height))).toBeLessThan(3);
      // Eight dots, each drawn under the camera's local affine at its centre.
      const dots = calls.filter((c) => c.name === "ellipse" && Math.abs(c.args[2] - 8) < 1e-9);
      expect(dots.length).toBe(8);
      const tl = dots[0];
      const [a, b, c2, d, e, g] = tl.transform;
      const onScreen = { x: a * tl.args[0] + c2 * tl.args[1] + e, y: b * tl.args[0] + d * tl.args[1] + g };
      const want = cardToCanvas(camera, { x: tl.args[0], y: tl.args[1] });
      expect(onScreen.x).toBeCloseTo(want.x, 6);
      expect(onScreen.y).toBeCloseTo(want.y, 6);
    });
  }

  it("annotation chrome, reticle and marquee draw under every camera", () => {
    const a = {
      id: "r",
      type: "rectangle",
      startTime: 0,
      endTime: 5,
      x: 0.2,
      y: 0.2,
      arrowEndX: 0.5,
      arrowEndY: 0.6,
      text: "",
      fontSize: 24,
      opacity: 1,
      cornerRadius: 8,
      drawingStrokes: [],
    } as unknown as Annotation;
    const tap = { ...a, id: "t", type: "tap" } as Annotation;
    for (const [, camera] of cameras) {
      const f: ChromeFrame = { camera, videoRect, u: 2 };
      const { ctx, calls } = mockCtx();
      drawAnnotationChrome(ctx, f, { annotations: [a, tap], time: 1, selectedId: "r", editingId: null, labelRect: () => null });
      drawFocalReticle(ctx, f, { x: 0.5, y: 0.5 });
      drawMarquee(ctx, { x: 10, y: 10 }, { x: 200, y: 120 }, 2);
      expect(calls.filter((c) => c.name === "stroke").length).toBeGreaterThan(5);
      expect(calls.some((c) => c.args.some((v) => typeof v === "number" && !Number.isFinite(v)))).toBe(false);
    }
  });
});
