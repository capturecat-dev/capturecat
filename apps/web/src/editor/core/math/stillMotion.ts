/**
 * Port of Services/StillMotionComposer.swift `enum StillMotionComposer` —
 * Tuning, cornerTour, compose(duration:) and clampFocal — the "Motion"
 * one-click cinematic tour for still-image captures. (`StillMotionApplier`,
 * which installs a plan into a project, is `applyStillMotion` in
 * core/edit/autoZoom.ts.)
 *
 * A four-corner tour: wide hold → contiguous corner segments TL → TR → BR →
 * BL (glide between corners, no dip out) with a slight tilt leaning into
 * each corner → pull back wide for the tail. Fully deterministic: fixed
 * quadrant anchors, depth/tilt from the corner index.
 *
 * Locked to the REAL Swift by `core/vectors/autoZoom.test.ts` (MCP
 * `auto_zoom` on image-capture projects routes to StillMotionApplier).
 */
import type { Point, TiltRegion, ZoomRegion } from "../model/types";
import { newUUID } from "../model/defaults";
import { smax, smin } from "./swift";

/** `StillMotionComposer.Tuning`. */
export const StillMotionTuning = {
  /** Fraction of the timeline held wide before the first push-in. */
  wideHoldFraction: 0.12,
  /** Fraction of the timeline held wide after the last pull-back. */
  tailFraction: 0.18,
  /** Focal inset from each corner (fraction of the frame). */
  cornerInset: 0.23,
  /** Depth alternates gently by corner index — a calm 1.8/2.0 pulse. */
  zoomLevels: [1.9, 2.0, 1.8, 2.0] as readonly number[],
  /** Slight skew leaning into the corner; degrees. */
  yawMagnitude: 2.5,
  pitchMagnitude: 1.5,
  /** A segment shorter than this reads as a glitch — tour fewer corners. */
  minSegmentDuration: 1.0,
  /** Focal keeps this margin inside the visible-viewport clamp. */
  edgeMargin: 0.02,
} as const;

const T = StillMotionTuning;

/** `StillMotionComposer.Plan`. */
export interface StillMotionPlan {
  zoomRegions: ZoomRegion[];
  tiltRegions: TiltRegion[];
}

/** `StillMotionComposer.cornerTour` — TL → TR → BR → BL, normalized Y-down. */
export function cornerTour(): Point[] {
  const lo = T.cornerInset;
  const hi = 1 - T.cornerInset;
  return [
    { x: lo, y: lo }, // top-left
    { x: hi, y: lo }, // top-right
    { x: hi, y: hi }, // bottom-right
    { x: lo, y: hi }, // bottom-left
  ];
}

/** `StillMotionComposer.clampFocal(_:zoomLevel:)` — same rule as
 * AutoZoomGenerator.clampFocal, with this type's own edgeMargin. */
export function stillMotionClampFocal(focal: Point, zoomLevel: number): Point {
  const halfVisible = 0.5 / smax(1.0, zoomLevel);
  const lower = halfVisible + T.edgeMargin;
  const upper = 1 - halfVisible - T.edgeMargin;
  if (!(lower < upper)) return { x: 0.5, y: 0.5 };
  return { x: smax(lower, smin(upper, focal.x)), y: smax(lower, smin(upper, focal.y)) };
}

/**
 * `StillMotionComposer.compose(duration:)` — lays the tour onto the
 * timeline. Empty plan for `duration <= 1` or segments ≤ 0.3 s. `makeId`
 * mints UUIDs in Swift's construction order (zoom, tilt, zoom, tilt, …).
 */
export function composeStillMotion(duration: number, makeId: () => string = newUUID): StillMotionPlan {
  if (!(duration > 1)) return { zoomRegions: [], tiltRegions: [] };

  const corners = cornerTour();
  const journeyStart = duration * T.wideHoldFraction;
  const journeyEnd = duration * (1 - T.tailFraction);

  // Four corners when the clip allows; deterministically drop trailing
  // corners on very short clips rather than composing glitch segments.
  let count = corners.length;
  const segmentLength = (n: number) => (journeyEnd - journeyStart) / n;
  while (count > 1 && segmentLength(count) < T.minSegmentDuration) {
    count -= 1;
  }
  const segment = segmentLength(count);
  if (!(segment > 0.3)) return { zoomRegions: [], tiltRegions: [] };

  const zooms: ZoomRegion[] = [];
  const tilts: TiltRegion[] = [];
  for (let index = 0; index < count; index++) {
    const corner = corners[index];
    const start = journeyStart + index * segment;
    const end = start + segment;
    const zoomLevel = T.zoomLevels[index % T.zoomLevels.length];
    zooms.push({
      id: makeId(),
      startTime: start,
      endTime: end,
      zoomLevel,
      focalPoint: stillMotionClampFocal(corner, zoomLevel),
      animationStyle: "Cinematic",
      followsCursor: false,
      isAuto: true,
    });
    // Lean INTO the corner: yaw positive tips the left edge back, pitch
    // positive tips the top edge back.
    const yawSign = corner.x < 0.5 ? 1 : -1;
    const pitchSign = corner.y < 0.5 ? 1 : -1;
    tilts.push({
      id: makeId(),
      startTime: start,
      endTime: end,
      pitch: T.pitchMagnitude * pitchSign,
      yaw: T.yawMagnitude * yawSign,
      roll: 0,
      animationStyle: "Cinematic",
    });
  }
  return { zoomRegions: zooms, tiltRegions: tilts };
}
