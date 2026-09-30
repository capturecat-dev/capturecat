/**
 * Frame-shape outlines that cannot be an analytic SDF.
 *
 * `continuousRoundedRectPath` is a literal port of
 * `ContinuousRoundedRect.path(rect:cornerRadius:)` (Apple's continuous
 * "squircle" corner, sampled from SwiftUI — three cubics per corner). The
 * outline is symmetric about both rect axes, so the Swift Y-up path and this
 * Y-down path are the same set of points.
 *
 * Squircle masks are rasterized once per layout with Canvas2D (available in
 * workers via OffscreenCanvas) — the same "CG raster of the path → mask
 * image" approach `roundedRectangleMaskImage` takes — and uploaded as an
 * r8unorm texture. Rounded rects stay analytic (SDF) in the shaders.
 */
import type { Rect } from "./layout";

const FULL_REACH = 1.528665;
const A_FULL = 1.08849;
const B_FULL = 0.868407;
const A_MIN = 0.96;
const B_MIN = 0.82;
const END_LONG = 0.631494;
const END_SHORT = 0.074911;
const MID_LONG = 0.372824;
const MID_SHORT = 0.16906;

function controls(p: number): [number, number] {
  const t = (p - 1) / (FULL_REACH - 1);
  return [A_MIN + (A_FULL - A_MIN) * t, B_MIN + (B_FULL - B_MIN) * t];
}

/** Minimal path sink so the geometry is testable without Canvas2D. */
export interface PathSink {
  moveTo(x: number, y: number): void;
  lineTo(x: number, y: number): void;
  bezierCurveTo(c1x: number, c1y: number, c2x: number, c2y: number, x: number, y: number): void;
  closePath(): void;
}

export function continuousRoundedRectPath(sink: PathSink, rect: Rect, cornerRadius: number): void {
  const { x: minX, y: minY, width, height } = rect;
  const maxX = minX + width;
  const maxY = minY + height;
  if (!(width > 0 && height > 0)) return;
  const r = Math.min(Math.max(0, cornerRadius), Math.min(width, height) / 2);
  if (!(r > 0)) {
    sink.moveTo(minX, minY);
    sink.lineTo(maxX, minY);
    sink.lineTo(maxX, maxY);
    sink.lineTo(minX, maxY);
    sink.closePath();
    return;
  }
  const reachY = Math.min(FULL_REACH, height / 2 / r);
  const reachX = Math.min(FULL_REACH, width / 2 / r);
  const [aY, bY] = controls(reachY);
  const [aX, bX] = controls(reachX);
  const pY = reachY * r;
  const pX = reachX * r;
  const aYr = aY * r, bYr = bY * r, aXr = aX * r, bXr = bX * r;
  const eL = END_LONG * r, eS = END_SHORT * r, mL = MID_LONG * r, mS = MID_SHORT * r;

  sink.moveTo(maxX, minY + height / 2);
  // "bottom-right" in the Swift source (maxY corner).
  sink.lineTo(maxX, maxY - pY);
  sink.bezierCurveTo(maxX, maxY - aYr, maxX, maxY - bYr, maxX - eS, maxY - eL);
  sink.bezierCurveTo(maxX - mS, maxY - mL, maxX - mL, maxY - mS, maxX - eL, maxY - eS);
  sink.bezierCurveTo(maxX - bXr, maxY, maxX - aXr, maxY, maxX - pX, maxY);
  sink.lineTo(minX + pX, maxY);
  sink.bezierCurveTo(minX + aXr, maxY, minX + bXr, maxY, minX + eL, maxY - eS);
  sink.bezierCurveTo(minX + mL, maxY - mS, minX + mS, maxY - mL, minX + eS, maxY - eL);
  sink.bezierCurveTo(minX, maxY - bYr, minX, maxY - aYr, minX, maxY - pY);
  sink.lineTo(minX, minY + pY);
  sink.bezierCurveTo(minX, minY + aYr, minX, minY + bYr, minX + eS, minY + eL);
  sink.bezierCurveTo(minX + mS, minY + mL, minX + mL, minY + mS, minX + eL, minY + eS);
  sink.bezierCurveTo(minX + bXr, minY, minX + aXr, minY, minX + pX, minY);
  sink.lineTo(maxX - pX, minY);
  sink.bezierCurveTo(maxX - aXr, minY, maxX - bXr, minY, maxX - eL, minY + eS);
  sink.bezierCurveTo(maxX - mL, minY + mS, maxX - mS, minY + mL, maxX - eS, minY + eL);
  sink.bezierCurveTo(maxX, minY + bYr, maxX, minY + aYr, maxX, minY + pY);
  sink.closePath();
}

export interface ShapeRaster {
  /** Integer pixel origin of the mask in target space. */
  originX: number;
  originY: number;
  width: number;
  height: number;
  /** Coverage 0…255, row-major, `width × height`. */
  coverage: Uint8Array<ArrayBuffer>;
}

/**
 * Rasterizes the squircle covering `rect` (Y-down target pixels) with a 2px
 * clear margin, pixel-aligned to the target grid so a mask texel IS a target
 * pixel. Works in workers and on the main thread (OffscreenCanvas).
 */
export function rasterizeSquircle(rect: Rect, cornerRadius: number): ShapeRaster {
  const originX = Math.floor(rect.x) - 2;
  const originY = Math.floor(rect.y) - 2;
  const width = Math.ceil(rect.x + rect.width) + 2 - originX;
  const height = Math.ceil(rect.y + rect.height) + 2 - originY;
  const canvas = new OffscreenCanvas(width, height);
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) throw new Error("Canvas2D unavailable for the squircle mask");
  const path = new Path2D();
  continuousRoundedRectPath(path, { x: rect.x - originX, y: rect.y - originY, width: rect.width, height: rect.height }, cornerRadius);
  ctx.fillStyle = "#fff";
  ctx.fill(path);
  const rgba = ctx.getImageData(0, 0, width, height).data;
  const coverage = new Uint8Array(width * height);
  for (let i = 0; i < coverage.length; i++) coverage[i] = rgba[i * 4 + 3];
  return { originX, originY, width, height, coverage };
}

/** Rounded-box SDF, Y-down px — the float64 twin of WGSL `sdRoundRect` (shaders.ts `common`). */
export function sdRoundRect(px: number, py: number, rect: Rect, radius: number): number {
  const hx = rect.width / 2;
  const hy = rect.height / 2;
  const r = Math.max(0, Math.min(radius, Math.min(hx, hy)));
  const qx = Math.abs(px - (rect.x + hx)) - hx + r;
  const qy = Math.abs(py - (rect.y + hy)) - hy + r;
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}

/** Coverage 0…1 of a pixel-aligned raster at the target pixel containing (x, y); 0 outside it. */
export function rasterCoverageAt(r: ShapeRaster, x: number, y: number): number {
  const ix = Math.floor(x) - r.originX;
  const iy = Math.floor(y) - r.originY;
  if (ix < 0 || iy < 0 || ix >= r.width || iy >= r.height) return 0;
  return r.coverage[iy * r.width + ix] / 255;
}

/**
 * `raster` × a second clip evaluated at every texel centre (= target pixel
 * centre; the rasters are pixel-aligned) — what CoreImage yields blending an
 * image with two masks in turn. Returns a new raster; `coverageAt` is 0…1.
 */
export function multiplyRaster(raster: ShapeRaster, coverageAt: (x: number, y: number) => number): ShapeRaster {
  const coverage = new Uint8Array(raster.coverage.length);
  for (let j = 0; j < raster.height; j++) {
    for (let i = 0; i < raster.width; i++) {
      const k = j * raster.width + i;
      const a = raster.coverage[k];
      if (a === 0) continue;
      const c = Math.max(0, Math.min(1, coverageAt(raster.originX + i + 0.5, raster.originY + j + 0.5)));
      coverage[k] = Math.round(a * c);
    }
  }
  return { ...raster, coverage };
}
