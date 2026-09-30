/**
 * Port of Services/ZoomFocalMath.swift (`enum ZoomFocalMath`) — ALL of it:
 * cardOffsetLimit, clampCardOffset, RegionTargets, RegionMemory, returnOmega,
 * restSnapZoomEpsilon / restSnapVelocityEpsilon / restLandingBand,
 * settleTowardRest, settleTowardZero, parallaxScale, regionTargets,
 * clampedUnitPoint, cursorFollowBlend, smoothstep (private in Swift),
 * blendedFocalPoint, temporalSmoothFocal, scaledRect.
 *
 * Shared by the preview motion model and the exporter's camera path (the
 * Swift file's whole purpose) — on the web both consume THIS module.
 *
 * Locked to Swift by the golden-vector units `zoomFocalMathScalars`,
 * `zoomFocalMathSettle`, `zoomFocalMathRegionTargets` and
 * `zoomFocalMathSmoothstepOracle` (verbatim oracle — `smoothstep` is private
 * in Swift) in WebVectors+CameraMotion.swift.
 *
 * `inout` translations:
 * - `settleTowardRest(zoom:velocity:dt:)` / `settleTowardZero` RETURN the new
 *   `{zoom, velocity}` / `{value, velocity}` pair.
 * - `regionTargets(..., memory: inout RegionMemory)` MUTATES the passed
 *   `RegionMemory` object in place (it is the carried spring memory).
 *
 * Coordinates: focal points are 0…1 of the video rect, Y-DOWN; card offsets
 * are canvas fractions, Y-down (same as Swift).
 */
import type { Point, Rect, ZoomRegion } from "../model/types";
import { zoomStyleDamping, zoomStyleOmegaMultiplier } from "../model/enums";
import { minX, minY, rectHeight, rectWidth } from "./geometry";
import { smax, smin } from "./swift";
import { rampOutLead, rampOutScale } from "./tiltMath";

/** Card-position excursion bound (canvas fractions, centre-relative, Y-down). */
export const cardOffsetLimit = 1.5;

/** `ZoomFocalMath.clampCardOffset(_:)` */
export function clampCardOffset(v: number): number {
  return smin(cardOffsetLimit, smax(-cardOffsetLimit, v));
}

/** `ZoomFocalMath.RegionTargets` — per-tick zoom-region targets. */
export interface RegionTargets {
  zoom: number;
  focal: Point;
  envelope: number;
  /** Spring frequency multiplier from the block's animation style. */
  omegaMultiplier: number;
  /** Spring damping (zeta) from the block's animation style. */
  damping: number;
  /** Card position excursion target, canvas fractions, Y-down. */
  offset: Point;
  /** Whether the focal may blend toward the cursor. */
  cursorFollow: boolean;
}

/** `ZoomFocalMath.RegionMemory` — carried spring memory between ticks. */
export interface RegionMemory {
  focal: Point;
  omegaMultiplier: number;
  damping: number;
  cursorFollow: boolean;
}

/** `ZoomFocalMath.RegionMemory()` (default values). */
export function makeRegionMemory(): RegionMemory {
  return { focal: { x: 0.5, y: 0.5 }, omegaMultiplier: 1, damping: 0.88, cursorFollow: true };
}

/** `RegionTargets(zoom:focal:envelope:)` with the struct's defaults. */
function makeRegionTargets(
  zoom: number,
  focal: Point,
  envelope: number,
  omegaMultiplier = 1,
  damping = 0.88,
  offset: Point = { x: 0, y: 0 },
  cursorFollow = true,
): RegionTargets {
  return { zoom, focal, envelope, omegaMultiplier, damping, offset, cursorFollow };
}

/** `ZoomFocalMath.returnOmega(time:rampStart:lead:style:)` — return-leg
 * stiffness blended over TIME through the ramp-out window. */
export function returnOmega(time: number, rampStart: number, lead: number, style: number): number {
  const floorOmega = smax(1.25, style);
  const raw = smin(1, smax(0, (time - rampStart) / smax(0.0001, lead)));
  const eased = raw * raw * (3 - 2 * raw);
  return style + (floorOmega - style) * eased;
}

export const restSnapZoomEpsilon = 0.004;
export const restSnapVelocityEpsilon = 0.04;
export const restLandingBand = 0.02;

/** `ZoomFocalMath.settleTowardRest(zoom:velocity:dt:)` — C¹-smooth landing
 * for a return-to-rest zoom. Returns the new (zoom, velocity). */
export function settleTowardRest(
  zoom: number,
  velocity: number,
  dt: number,
): { zoom: number; velocity: number } {
  const depth = 1 - smin(1, Math.abs(zoom - 1) / restLandingBand);
  const weight = depth * depth * (3 - 2 * depth);
  const decay = Math.exp(-10.0 * weight * dt);
  zoom = 1 + (zoom - 1) * decay;
  velocity *= decay;
  if (Math.abs(zoom - 1) < 0.0002 && Math.abs(velocity) < 0.005) {
    zoom = 1;
    velocity = 0;
  }
  return { zoom, velocity };
}

/** `ZoomFocalMath.settleTowardZero(_:_:dt:band:)` — the same smooth landing
 * for any channel returning to zero. Returns the new (value, velocity). */
export function settleTowardZero(
  value: number,
  velocity: number,
  dt: number,
  band: number,
): { value: number; velocity: number } {
  if (!(Math.abs(value) < band)) return { value, velocity };
  const depth = 1 - Math.abs(value) / band;
  const weight = depth * depth * (3 - 2 * depth);
  const decay = Math.exp(-10.0 * weight * dt);
  value *= decay;
  velocity *= decay;
  if (Math.abs(value) < band * 0.02 && Math.abs(velocity) < band * 0.5) {
    value = 0;
    velocity = 0;
  }
  return { value, velocity };
}

/** `ZoomFocalMath.parallaxScale(zoom:strength:)` */
export function parallaxScale(zoom: number, strength: number): number {
  const s = smax(0, smin(1, strength));
  return 1 + smax(0, zoom - 1) * 0.12 * s;
}

/**
 * `ZoomFocalMath.regionTargets(zoomRegions:at:currentZoom:animationDuration:memory:)`.
 * MUTATES `memory` (Swift `inout`).
 */
export function regionTargets(
  zoomRegions: readonly ZoomRegion[],
  time: number,
  currentZoom: number,
  animationDuration = 0.8,
  memory: RegionMemory,
): RegionTargets {
  for (const region of zoomRegions) {
    if (!(time >= region.startTime && time <= region.endTime)) continue;
    const style = region.animationStyle;
    memory.focal = { x: region.focalPoint.x, y: region.focalPoint.y };
    memory.omegaMultiplier = style != null ? zoomStyleOmegaMultiplier(style) : 1;
    memory.damping = style != null ? zoomStyleDamping(style) : 0.88;
    memory.cursorFollow = region.followsCursor ?? true;

    const lead = rampOutLead(region.startTime, region.endTime, animationDuration);
    if (time > region.endTime - lead) {
      const scale = rampOutScale(time, region.startTime, region.endTime, animationDuration);
      const offset = {
        x: clampCardOffset(region.cardOffsetX ?? 0) * scale,
        y: clampCardOffset(region.cardOffsetY ?? 0) * scale,
      };
      return makeRegionTargets(
        1 + (region.zoomLevel - 1) * scale,
        { x: region.focalPoint.x, y: region.focalPoint.y },
        1,
        returnOmega(time, region.endTime - lead, lead, memory.omegaMultiplier),
        smin(memory.damping, 0.95),
        offset,
        memory.cursorFollow,
      );
    }
    const offset = {
      x: clampCardOffset(region.cardOffsetX ?? 0),
      y: clampCardOffset(region.cardOffsetY ?? 0),
    };
    return makeRegionTargets(
      region.zoomLevel,
      { x: region.focalPoint.x, y: region.focalPoint.y },
      1,
      memory.omegaMultiplier,
      memory.damping,
      offset,
      memory.cursorFollow,
    );
  }
  if (Math.abs(currentZoom - 1) > restSnapZoomEpsilon) {
    return makeRegionTargets(
      1,
      { x: memory.focal.x, y: memory.focal.y },
      1,
      smax(1.25, memory.omegaMultiplier),
      smin(memory.damping, 0.95),
      { x: 0, y: 0 },
      memory.cursorFollow,
    );
  }
  return makeRegionTargets(1, { x: 0.5, y: 0.5 }, 0);
}

/** `ZoomFocalMath.clampedUnitPoint(_:)` */
export function clampedUnitPoint(point: Point): Point {
  return { x: smax(0, smin(1, point.x)), y: smax(0, smin(1, point.y)) };
}

/** `ZoomFocalMath.cursorFollowBlend(for:)` — smoothstep of zoom 1 → 1.5. */
export function cursorFollowBlend(zoom: number): number {
  const start = 1.0;
  const full = 1.5;
  const t = smax(0, smin(1, (zoom - start) / (full - start)));
  return t * t * (3 - 2 * t);
}

/** `ZoomFocalMath.smoothstep(_:_:_:)` (private in Swift; locked by the
 * `zoomFocalMathSmoothstepOracle` verbatim oracle). */
export function smoothstep(edge0: number, edge1: number, x: number): number {
  if (!(edge1 > edge0)) return x <= edge0 ? 0 : 1;
  const t = smax(0, smin(1, (x - edge0) / (edge1 - edge0)));
  return t * t * (3 - 2 * t);
}

/** `ZoomFocalMath.blendedFocalPoint(regionFocal:cursorPosition:displayWidth:displayHeight:zoom:envelope:followCursor:)`.
 * `cursorPosition` is in the cursor coordinate space (points, Y-down); null = nil. */
export function blendedFocalPoint(
  regionFocal: Point,
  cursorPosition: Point | null | undefined,
  displayWidth: number,
  displayHeight: number,
  zoom: number,
  envelope = 1.0,
  followCursor = true,
): Point {
  const region = clampedUnitPoint(regionFocal);
  if (!(followCursor && cursorPosition != null && displayWidth > 0 && displayHeight > 0)) {
    return region;
  }
  const cursor = {
    x: smax(0, smin(1, cursorPosition.x / displayWidth)),
    y: smax(0, smin(1, cursorPosition.y / displayHeight)),
  };
  const envelopeGate = smoothstep(0.2, 0.85, envelope);
  const blend = cursorFollowBlend(zoom) * envelopeGate;
  return {
    x: region.x + (cursor.x - region.x) * blend,
    y: region.y + (cursor.y - region.y) * blend,
  };
}

/** `ZoomFocalMath.temporalSmoothFocal(target:previous:deltaTime:smoothCursor:smoothingFactor:zoom:)` */
export function temporalSmoothFocal(
  target: Point,
  previous: Point | null | undefined,
  deltaTime: number,
  smoothCursor: boolean,
  smoothingFactor: number,
  zoom = 1.0,
): Point {
  if (previous == null) return clampedUnitPoint(target);

  const dt = smax(1.0 / 240.0, smin(0.2, deltaTime));
  let tau: number;
  if (zoom > 1.01) {
    const zoomExtra = smin(1.0, zoom - 1.0);
    tau = 0.3 + zoomExtra * 0.15;
  } else {
    const factor = smax(0.0, smin(1.0, smoothingFactor));
    tau = smoothCursor ? smax(0.02, 0.055 - factor * 0.025) : 0.028;
  }

  const targetPoint = clampedUnitPoint(target);
  const alpha = 1 - Math.exp(-dt / tau);
  return {
    x: previous.x + (targetPoint.x - previous.x) * alpha,
    y: previous.y + (targetPoint.y - previous.y) * alpha,
  };
}

/** `ZoomFocalMath.scaledRect(_:scale:anchor:)` — returns `rect` itself when
 * the (floored) scale is 1 within an ulp. */
export function scaledRect(rect: Rect, scale: number, anchor: Point): Rect {
  const safeScale = smax(scale, 0.01);
  if (!(Math.abs(safeScale - 1) > Number.EPSILON)) return rect;
  return {
    x: anchor.x + (minX(rect) - anchor.x) * safeScale,
    y: anchor.y + (minY(rect) - anchor.y) * safeScale,
    width: rectWidth(rect) * safeScale,
    height: rectHeight(rect) * safeScale,
  };
}
