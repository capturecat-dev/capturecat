/**
 * Port of Services/ReactiveCameraLayout.swift — the camera bubble's reactive
 * placement (shrinks as the screen zooms in, grows back as it releases; the
 * corner never changes). CLAUDE.md names it a preview/export source of truth:
 * the preview compositor AND the exporter feed it the same smoothed zoom.
 *
 * Functions: `envelope(forZoom:)`, `shapeAspect(shape:videoAspect:orientation:)`,
 * `bubbleSize(baseSize:aspect:)`, `canvasFitScale(for:)`, `fraction(for:)`,
 * `cameraRect(in:basePosition:customPosition:baseSize:zoom:padding:aspect:yAxisIsUp:)`
 * and the constants `minSizeFactor`, `squircleMaxAspect`, `verticalAspect`.
 *
 * Locked by the golden-vector units `reactiveCameraLayoutScalars`,
 * `reactiveCameraLayoutCameraRect` and `styleConstants`.
 *
 * Coordinate note: `customPosition` is ALWAYS Y-down (0…1). `yAxisIsUp` only
 * mirrors the vertical fraction for CoreImage consumers (the exporter passes
 * true with its Y-up output rect). The web keeps everything Y-down, so the
 * web renderer passes `yAxisIsUp = false`; the flag is ported so the vectors
 * can exercise the exporter's own call.
 */
import type { Point, Rect, Size } from "../model/types";
import type { CameraOrientation, CameraPosition, CameraShape } from "../model/enums";
import { minX, minY, rectHeight, rectWidth } from "./geometry";
import { smax, smin } from "./swift";

/** Camera size at full envelope, as a fraction of base size. */
export const minSizeFactor = 0.75;
/** Squircle tile aspect cap (and the forced `.wide` tile aspect). */
export const squircleMaxAspect = 1.2;
/** Forced-portrait tile aspect (`cameraOrientation == .vertical`). */
export const verticalAspect = 0.8;

/** `envelope(forZoom:)` — smoothstep of (zoom − 1) / 0.5, clamped to 0…1. */
export function envelope(zoom: number): number {
  const t = smax(0, smin(1, (zoom - 1.0) / 0.5));
  return t * t * (3 - 2 * t);
}

/** `shapeAspect(shape:videoAspect:orientation:)` */
export function shapeAspect(
  shape: CameraShape,
  videoAspect: number,
  orientation: CameraOrientation,
): number {
  switch (shape) {
    case "Circle":
    case "Square":
      return 1;
    case "Rounded Rectangle":
    case "Squircle": {
      switch (orientation) {
        case "Vertical":
          return verticalAspect;
        case "Wide":
          return squircleMaxAspect;
        case "Auto":
          break;
      }
      if (shape === "Rounded Rectangle") return videoAspect;
      return videoAspect >= 1
        ? smin(videoAspect, squircleMaxAspect)
        : smax(videoAspect, 1 / squircleMaxAspect);
    }
  }
}

/** `bubbleSize(baseSize:aspect:)` — `baseSize` controls the LONGER side. */
export function bubbleSize(baseSize: number, aspect: number): Size {
  const size = smax(1, baseSize);
  const safeAspect = smax(0.01, aspect);
  return safeAspect >= 1
    ? { width: size, height: size / safeAspect }
    : { width: size * safeAspect, height: size };
}

/** `canvasFitScale(for:)` — nominal 1456×728 canvas → current canvas. */
export function canvasFitScale(canvas: Size): number {
  if (!(canvas.width > 0 && canvas.height > 0)) return 1;
  return smin(canvas.width / 1456, canvas.height / 728);
}

/** `fraction(for:)` — Y-down corner fraction. */
export function fraction(position: CameraPosition): Point {
  switch (position) {
    case "Top Left":
      return { x: 0, y: 0 };
    case "Top Right":
      return { x: 1, y: 0 };
    case "Bottom Left":
      return { x: 0, y: 1 };
    case "Bottom Right":
      return { x: 1, y: 1 };
  }
}

/**
 * `cameraRect(in:basePosition:customPosition:baseSize:zoom:padding:aspect:yAxisIsUp:)`.
 * `customPosition` null/undefined = use the corner. Rect is in `contentRect`'s
 * space (Y-up when `yAxisIsUp`).
 */
export function cameraRect(
  contentRect: Rect,
  basePosition: CameraPosition,
  customPosition: Point | null | undefined,
  baseSize: number,
  zoom: number,
  padding: number,
  /** Swift default 1 (square bubble). */
  aspect: number,
  yAxisIsUp: boolean,
): Rect {
  const env = envelope(zoom);
  const sizeFactor = 1.0 - (1.0 - minSizeFactor) * env;
  const size = bubbleSize(baseSize * sizeFactor, aspect);

  const f =
    customPosition != null
      ? { x: smin(1, smax(0, customPosition.x)), y: smin(1, smax(0, customPosition.y)) }
      : fraction(basePosition);
  const fy = yAxisIsUp ? 1 - f.y : f.y;

  const usableW = rectWidth(contentRect) - 2 * padding - size.width;
  const usableH = rectHeight(contentRect) - 2 * padding - size.height;
  const originX = minX(contentRect) + padding + smax(0, usableW) * f.x;
  const originY = minY(contentRect) + padding + smax(0, usableH) * fy;

  return { x: originX, y: originY, width: size.width, height: size.height };
}
