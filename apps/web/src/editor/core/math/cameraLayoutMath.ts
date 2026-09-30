/**
 * Port of Services/CameraLayoutMath.swift — dynamic camera layouts (bubble /
 * camera-only / side-by-side / screen-only), interpolated across mode
 * boundaries with a smootherstep morph so a switch reads as a morph, not a
 * cut. Shared by the preview compositor and the exporter (each passes its OWN
 * card rect and bubble rect; the output is consumed identically).
 *
 * Functions: `ease`, `bubbleApproxCornerRadius`, `region(at:regions:)`,
 * `mode(at:regions:)`, `columns(in:)`, `resolve(...)` (incl. the private
 * `target(mode:...)` and `lerp` helpers, exercised through `resolve`),
 * `cardTransform(_:videoRect:)`, `boundaries(_:duration:)`; constants
 * `transitionDuration`, `sideBySideScreenFraction`, `sideBySideGapFraction`.
 *
 * Locked by the golden-vector units `cameraLayoutMathBasics`,
 * `cameraLayoutResolve`, `cameraLayoutBoundaries` and `styleConstants`.
 *
 * Space: the card squeeze is a UNIFORM scale plus an X-ONLY translation about
 * the card centre, so the same numbers are valid in Y-down (preview/web) and
 * Y-up (CoreImage) space. The web passes its Y-down card rect and Y-down
 * bubble rect (`ReactiveCameraLayout.cameraRect(..., yAxisIsUp: false)`).
 *
 * Faithful-port notes:
 * - `boundaries` returns only the filtered, sorted region edges; its Swift doc
 *   mentions "plus the tail of each morph" but the code adds no tails.
 * - `lerp(CGRect)` interpolates `minX`/`minY`/`width`/`height` (standardized
 *   accessors), so a negative-size rect is normalized by the morph.
 */
import type { CameraLayoutRegion, Rect, Size } from "../model/types";
import type { CameraLayoutMode, CameraShape } from "../model/enums";
import {
  type AffineTransform,
  identityTransform,
  maxX,
  midX,
  midY,
  minX,
  minY,
  rectHeight,
  rectWidth,
  scaledBy,
  translatedBy,
} from "./geometry";
import { smax, smin } from "./swift";

/** Morph length at every mode boundary (seconds). */
export const transitionDuration = 0.45;
/** Side-by-side: the screen keeps 60% of the card width. */
export const sideBySideScreenFraction = 0.6;
/** Side-by-side gutter as a fraction of the card width. */
export const sideBySideGapFraction = 0.03;

/** Smootherstep 6t⁵−15t⁴+10t³ on a clamped t. */
export function ease(t: number): number {
  const x = smin(1, smax(0, t));
  return x * x * x * (x * (x * 6 - 15) + 10);
}

/** `CameraLayoutMath.Resolved` */
export interface CameraLayoutResolved {
  /** null = the project has no camera at all. */
  cameraRect: Rect | null;
  cameraCornerRadius: number;
  cameraOpacity: number;
  chromeOpacity: number;
  cardScale: number;
  cardTranslationX: number;
  isPlainBubble: boolean;
}

/** `bubbleApproxCornerRadius(shape:customRadius:size:)` (customRadius pre-scaled). */
export function bubbleApproxCornerRadius(shape: CameraShape, customRadius: number, size: Size): number {
  const short = smin(size.width, size.height);
  switch (shape) {
    case "Circle":
      return short / 2;
    case "Square":
      return 0;
    case "Rounded Rectangle":
      return smin(smax(0, customRadius), short / 2);
    case "Squircle":
      return short * 0.25;
  }
}

/** `region(at:regions:)` — the FIRST region containing t (closed interval). */
export function region(t: number, regions: readonly CameraLayoutRegion[]): CameraLayoutRegion | null {
  for (const r of regions) if (t >= r.startTime && t <= r.endTime) return r;
  return null;
}

/** `mode(at:regions:)` — `.bubble` outside every region. */
export function mode(t: number, regions: readonly CameraLayoutRegion[]): CameraLayoutMode {
  return region(t, regions)?.mode ?? "bubble";
}

/** `columns(in:)` — side-by-side tiles (screen leading, camera trailing). */
export function columns(videoRect: Rect): { screen: Rect; camera: Rect } {
  const gap = rectWidth(videoRect) * sideBySideGapFraction;
  const screenWidth = rectWidth(videoRect) * sideBySideScreenFraction;
  const cameraWidth = rectWidth(videoRect) - screenWidth - gap;
  const tileHeight = rectHeight(videoRect) * sideBySideScreenFraction;
  const tileY = midY(videoRect) - tileHeight / 2;
  return {
    screen: { x: minX(videoRect), y: tileY, width: screenWidth, height: tileHeight },
    camera: { x: maxX(videoRect) - cameraWidth, y: tileY, width: cameraWidth, height: tileHeight },
  };
}

/** private `target(mode:videoRect:bubbleRect:bubbleCornerRadius:cardCornerRadius:)` */
function target(
  m: CameraLayoutMode,
  videoRect: Rect,
  bubbleRect: Rect,
  bubbleCornerRadius: number,
  cardCornerRadius: number,
): CameraLayoutResolved {
  switch (m) {
    case "bubble":
      return {
        cameraRect: bubbleRect,
        cameraCornerRadius: bubbleCornerRadius,
        cameraOpacity: 1,
        chromeOpacity: 1,
        cardScale: 1,
        cardTranslationX: 0,
        isPlainBubble: true,
      };
    case "cameraOnly":
      return {
        cameraRect: videoRect,
        cameraCornerRadius: cardCornerRadius,
        cameraOpacity: 1,
        chromeOpacity: 0,
        cardScale: 1,
        cardTranslationX: 0,
        isPlainBubble: false,
      };
    case "sideBySide": {
      const cols = columns(videoRect);
      const scale = rectWidth(videoRect) > 0 ? rectWidth(cols.screen) / rectWidth(videoRect) : 1;
      return {
        cameraRect: cols.camera,
        cameraCornerRadius: cardCornerRadius,
        cameraOpacity: 1,
        chromeOpacity: 0,
        cardScale: scale,
        cardTranslationX: midX(cols.screen) - midX(videoRect),
        isPlainBubble: false,
      };
    }
    case "screenOnly":
      return {
        cameraRect: bubbleRect,
        cameraCornerRadius: bubbleCornerRadius,
        cameraOpacity: 0,
        chromeOpacity: 0,
        cardScale: 1,
        cardTranslationX: 0,
        isPlainBubble: false,
      };
  }
}

function lerp(a: number, b: number, p: number): number {
  return a + (b - a) * p;
}

function lerpRect(a: Rect, b: Rect, p: number): Rect {
  return {
    x: lerp(minX(a), minX(b), p),
    y: lerp(minY(a), minY(b), p),
    width: lerp(rectWidth(a), rectWidth(b), p),
    height: lerp(rectHeight(a), rectHeight(b), p),
  };
}

/**
 * `resolve(at:regions:videoRect:bubbleRect:bubbleCornerRadius:cardCornerRadius:hasCamera:)`.
 * A pure function of timeline position (never a wall clock).
 */
export function resolve(
  t: number,
  regions: readonly CameraLayoutRegion[],
  videoRect: Rect,
  bubbleRect: Rect,
  bubbleCornerRadius: number,
  cardCornerRadius: number,
  hasCamera: boolean,
): CameraLayoutResolved {
  if (!hasCamera) {
    return {
      cameraRect: null,
      cameraCornerRadius: 0,
      cameraOpacity: 0,
      chromeOpacity: 0,
      cardScale: 1,
      cardTranslationX: 0,
      isPlainBubble: false,
    };
  }
  if (regions.length === 0) {
    return target("bubble", videoRect, bubbleRect, bubbleCornerRadius, cardCornerRadius);
  }

  const current = mode(t, regions);
  const settled = target(current, videoRect, bubbleRect, bubbleCornerRadius, cardCornerRadius);

  const edges = regions.flatMap((r) => [r.startTime, r.endTime]).sort((a, b) => a - b);
  let boundary: number | undefined;
  for (let i = edges.length - 1; i >= 0; i--) {
    if (edges[i] <= t) {
      boundary = edges[i];
      break;
    }
  }
  if (boundary === undefined || !(boundary > 0.05) || !(t - boundary < transitionDuration)) {
    return settled;
  }

  const previous = mode(boundary - 0.001, regions);
  if (previous === current) return settled;

  const from = target(previous, videoRect, bubbleRect, bubbleCornerRadius, cardCornerRadius);
  const p = ease((t - boundary) / transitionDuration);

  return {
    cameraRect: lerpRect(from.cameraRect ?? bubbleRect, settled.cameraRect ?? bubbleRect, p),
    cameraCornerRadius: lerp(from.cameraCornerRadius, settled.cameraCornerRadius, p),
    cameraOpacity: lerp(from.cameraOpacity, settled.cameraOpacity, p),
    chromeOpacity: lerp(from.chromeOpacity, settled.chromeOpacity, p),
    cardScale: lerp(from.cardScale, settled.cardScale, p),
    cardTranslationX: lerp(from.cardTranslationX, settled.cardTranslationX, p),
    isPlainBubble: false,
  };
}

/** `cardTransform(_:videoRect:)` — uniform scale + X translation about the card centre. */
export function cardTransform(resolved: CameraLayoutResolved, videoRect: Rect): AffineTransform {
  if (!(resolved.cardScale !== 1 || resolved.cardTranslationX !== 0)) return identityTransform;
  const c = { x: midX(videoRect), y: midY(videoRect) };
  let t = translatedBy(identityTransform, c.x + resolved.cardTranslationX, c.y);
  t = scaledBy(t, resolved.cardScale, resolved.cardScale);
  t = translatedBy(t, -c.x, -c.y);
  return t;
}

/** `boundaries(_:duration:)` — region edges strictly inside (0.05, duration − 0.05), sorted. */
export function boundaries(regions: readonly CameraLayoutRegion[], duration: number): number[] {
  return regions
    .flatMap((r) => [r.startTime, r.endTime])
    .filter((e) => e > 0.05 && e < duration - 0.05)
    .sort((a, b) => a - b);
}
