/**
 * Port of Services/BackgroundGradientRenderer.swift — the background ramp's
 * geometry: `Axis`, the gradient-line endpoints `draw(in:rect:start:end:axis:)`
 * hands to `CGContext.drawLinearGradient` (options `.drawsBeforeStartLocation`
 * + `.drawsAfterEndLocation`, i.e. clamp t to 0…1), and the bitmap size
 * `image(start:end:size:axis:scale:)` allocates.
 *
 * Locked by the golden-vector unit `backgroundGradientAxis` (the endpoint
 * switch is inline in draw() — a verbatim oracle CROSS-CHECKED against the
 * real draw() by rendering both) and, for pixels, `backgroundLookPixels`.
 *
 * SPACE: `drawPoints` returns points in the CG context's Y-UP pixel space
 * (origin bottom-left) — exactly what Swift computes. The web renders Y-down:
 * convert a point with `yDown = H − yUp` (H = bitmap height). `gradientT`
 * below does that conversion for a Y-down pixel centre, so a WGSL pass can
 * use the returned p0/p1 as-is together with the flip.
 */
import type { Point, Rect, Size } from "../model/types";
import { maxX, maxY, midX, midY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { sInt, srounded } from "./swift";

/** `BackgroundGradientRenderer.Axis` */
export type GradientAxis =
  | { kind: "diagonal" } // .topLeading → .bottomTrailing
  | { kind: "vertical" } // .top → .bottom
  | { kind: "angle"; degrees: number }; // CSS-style: 0° = bottom→top, 90° = left→right

/** Endpoints of the gradient line in Y-UP space; null when draw() skips (`rect.width > 0, rect.height > 0` fails). */
export function drawPoints(rect: Rect, axis: GradientAxis): { p0: Point; p1: Point } | null {
  if (!(rectWidth(rect) > 0 && rectHeight(rect) > 0)) return null;
  switch (axis.kind) {
    case "diagonal":
      return { p0: { x: minX(rect), y: maxY(rect) }, p1: { x: maxX(rect), y: minY(rect) } };
    case "vertical":
      return { p0: { x: midX(rect), y: maxY(rect) }, p1: { x: midX(rect), y: minY(rect) } };
    case "angle": {
      const theta = (axis.degrees * Math.PI) / 180;
      const d = { x: Math.sin(theta), y: Math.cos(theta) };
      const length = Math.abs(rectWidth(rect) * d.x) + Math.abs(rectHeight(rect) * d.y);
      const c = { x: midX(rect), y: midY(rect) };
      return {
        p0: { x: c.x - (d.x * length) / 2, y: c.y - (d.y * length) / 2 },
        p1: { x: c.x + (d.x * length) / 2, y: c.y + (d.y * length) / 2 },
      };
    }
  }
}

/** `image(...)` bitmap size: `Int((size × scale).rounded())` per axis; null when either is ≤ 0. */
export function imageSize(size: Size, scale: number): { width: number; height: number } | null {
  const w = sInt(srounded(size.width * scale));
  const h = sInt(srounded(size.height * scale));
  if (!(w > 0 && h > 0)) return null;
  return { width: w, height: h };
}

/**
 * The gradient parameter CG evaluates for a pixel: projection of the pixel
 * centre onto p0→p1, clamped to 0…1 (both extend options are on). `px`, `py`
 * are Y-DOWN integer pixel indices of a bitmap `height` pixels tall; p0/p1
 * are the Y-UP points from `drawPoints`. (Executable spec for the WGSL pass;
 * checked against real CG pixels by `backgroundLookPixels`.)
 */
export function gradientT(p0: Point, p1: Point, px: number, py: number, height: number): number {
  const x = px + 0.5;
  const y = height - (py + 0.5);
  const dx = p1.x - p0.x;
  const dy = p1.y - p0.y;
  const len2 = dx * dx + dy * dy;
  if (!(len2 > 0)) return 0;
  const t = ((x - p0.x) * dx + (y - p0.y) * dy) / len2;
  return t < 0 ? 0 : t > 1 ? 1 : t;
}
