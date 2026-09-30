/**
 * CoreGraphics geometry with CoreGraphics semantics.
 *
 * Swift's `rect.width` / `rect.height` / `minX` / `maxX` are the STANDARDIZED
 * values (CGRectGetWidth is |size.width|; minX is the smaller edge), while
 * `rect.size.width` is the raw stored value. Ports must pick the same accessor
 * the Swift source uses — `r.width` below is the raw stored field
 * (`rect.size.width`); `rectWidth(r)` is `rect.width`.
 */
import type { Point, Rect, Size } from "../model/types";

export function rect(x: number, y: number, width: number, height: number): Rect {
  return { x, y, width, height };
}

export function point(x: number, y: number): Point {
  return { x, y };
}

export function size(width: number, height: number): Size {
  return { width, height };
}

export const zeroRect: Rect = Object.freeze({ x: 0, y: 0, width: 0, height: 0 });
export const zeroPoint: Point = Object.freeze({ x: 0, y: 0 });
export const zeroSize: Size = Object.freeze({ width: 0, height: 0 });

/** `rect.width` (CGRectGetWidth — absolute). */
export function rectWidth(r: Rect): number {
  return Math.abs(r.width);
}
/** `rect.height` (CGRectGetHeight — absolute). */
export function rectHeight(r: Rect): number {
  return Math.abs(r.height);
}
export function minX(r: Rect): number {
  return r.width < 0 ? r.x + r.width : r.x;
}
export function maxX(r: Rect): number {
  return r.width < 0 ? r.x : r.x + r.width;
}
export function minY(r: Rect): number {
  return r.height < 0 ? r.y + r.height : r.y;
}
export function maxY(r: Rect): number {
  return r.height < 0 ? r.y : r.y + r.height;
}
export function midX(r: Rect): number {
  return minX(r) + rectWidth(r) / 2;
}
export function midY(r: Rect): number {
  return minY(r) + rectHeight(r) / 2;
}

/** `rect.standardized`. */
export function standardized(r: Rect): Rect {
  return { x: minX(r), y: minY(r), width: rectWidth(r), height: rectHeight(r) };
}

/** `CGRect.null` — what CG returns for empty intersections / over-insets. */
export const nullRect: Rect = Object.freeze({
  x: Number.POSITIVE_INFINITY,
  y: Number.POSITIVE_INFINITY,
  width: 0,
  height: 0,
});

export function isNullRect(r: Rect): boolean {
  return r.x === Number.POSITIVE_INFINITY || r.y === Number.POSITIVE_INFINITY;
}

/** `rect.insetBy(dx:dy:)` (CGRectInset): standardized, then inset; a negative
 * resulting size yields `CGRect.null`. */
export function insetBy(r: Rect, dx: number, dy: number): Rect {
  const s = standardized(r);
  const w = s.width - 2 * dx;
  const h = s.height - 2 * dy;
  if (w < 0 || h < 0) return nullRect;
  return { x: s.x + dx, y: s.y + dy, width: w, height: h };
}

/** `rect.offsetBy(dx:dy:)`. */
export function offsetBy(r: Rect, dx: number, dy: number): Rect {
  const s = standardized(r);
  return { x: s.x + dx, y: s.y + dy, width: s.width, height: s.height };
}

/** `rect.contains(point)` (CGRectContainsPoint: min inclusive, max exclusive). */
export function rectContains(r: Rect, p: Point): boolean {
  return p.x >= minX(r) && p.x < maxX(r) && p.y >= minY(r) && p.y < maxY(r);
}

/** `rect.intersection(other)` (CGRectIntersection). */
export function intersection(a: Rect, b: Rect): Rect {
  const x0 = Math.max(minX(a), minX(b));
  const y0 = Math.max(minY(a), minY(b));
  const x1 = Math.min(maxX(a), maxX(b));
  const y1 = Math.min(maxY(a), maxY(b));
  if (x1 < x0 || y1 < y0) return nullRect;
  return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
}

/** 2D affine transform, CoreGraphics layout: x' = a·x + c·y + tx, y' = b·x + d·y + ty. */
export interface AffineTransform {
  a: number;
  b: number;
  c: number;
  d: number;
  tx: number;
  ty: number;
}

export const identityTransform: AffineTransform = Object.freeze({ a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 });

export function applyTransform(t: AffineTransform, p: Point): Point {
  return { x: t.a * p.x + t.c * p.y + t.tx, y: t.b * p.x + t.d * p.y + t.ty };
}

/** `t1.concatenating(t2)` (CGAffineTransformConcat: apply t1, then t2). */
export function concatTransform(t1: AffineTransform, t2: AffineTransform): AffineTransform {
  return {
    a: t1.a * t2.a + t1.b * t2.c,
    b: t1.a * t2.b + t1.b * t2.d,
    c: t1.c * t2.a + t1.d * t2.c,
    d: t1.c * t2.b + t1.d * t2.d,
    tx: t1.tx * t2.a + t1.ty * t2.c + t2.tx,
    ty: t1.tx * t2.b + t1.ty * t2.d + t2.ty,
  };
}

export function translationTransform(tx: number, ty: number): AffineTransform {
  return { a: 1, b: 0, c: 0, d: 1, tx, ty };
}

export function scaleTransform(sx: number, sy: number): AffineTransform {
  return { a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0 };
}

/** CGAffineTransform(rotationAngle:). */
export function rotationTransform(angle: number): AffineTransform {
  const c = Math.cos(angle);
  const s = Math.sin(angle);
  return { a: c, b: s, c: -s, d: c, tx: 0, ty: 0 };
}

/** `t.translatedBy(x:y:)` == concat(translation, t). */
export function translatedBy(t: AffineTransform, x: number, y: number): AffineTransform {
  return concatTransform(translationTransform(x, y), t);
}

/** `t.scaledBy(x:y:)` == concat(scale, t). */
export function scaledBy(t: AffineTransform, sx: number, sy: number): AffineTransform {
  return concatTransform(scaleTransform(sx, sy), t);
}

/** `t.rotated(by:)` == concat(rotation, t). */
export function rotatedBy(t: AffineTransform, angle: number): AffineTransform {
  return concatTransform(rotationTransform(angle), t);
}

/**
 * CI (Y-up, origin bottom-left) ↔ Y-down (origin top-left) for a rect inside
 * a canvas of `height` — `DeviceFrameRenderer.flip(_:in:)`:
 * `CGRect(x: rect.minX, y: extent.height - rect.maxY, width: rect.width, height: rect.height)`.
 * Its own inverse. Use it exactly once at the GPU boundary for every
 * exporter-space (CI Y-up) rect.
 */
export function flipRectY(rect: Rect, height: number): Rect {
  return { x: minX(rect), y: height - maxY(rect), width: rectWidth(rect), height: rectHeight(rect) };
}

/** CI (Y-up) ↔ Y-down for a point in a canvas of `height`. Its own inverse. */
export function flipPointY(p: Point, height: number): Point {
  return { x: p.x, y: height - p.y };
}
