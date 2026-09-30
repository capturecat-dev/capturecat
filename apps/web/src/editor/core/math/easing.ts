/**
 * Port of Services/EasingFunctions.swift (`enum Easing`) — easeInOutCubic,
 * smootherStep, easeOutCubic, easeInCubic, easeOutQuart, easeOutExpo, spring,
 * regionEnvelope, zoomEnvelope, zoomLevel.
 *
 * Locked to Swift by the `easingCurves`, `easingEnvelopes` and
 * `easingZoomLevel` golden vectors (WebVectors+CameraMotion.swift).
 *
 * Faithful-port notes: `pow`/`exp`/`cos`/`sqrt` are the libm calls Swift makes
 * (JS Math.* agree within an ulp); Swift `min`/`max` go through ./swift.
 */
import type { Point, ZoomRegion } from "../model/types";
import { smax, smin } from "./swift";

/** `Easing.easeInOutCubic(_:)` */
export function easeInOutCubic(t: number): number {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

/** `Easing.smootherStep(_:)` — input clamped to 0…1. */
export function smootherStep(t: number): number {
  const clamped = smax(0, smin(1, t));
  return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10);
}

/** `Easing.easeOutCubic(_:)` */
export function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - t, 3);
}

/** `Easing.easeInCubic(_:)` */
export function easeInCubic(t: number): number {
  return t * t * t;
}

/** `Easing.easeOutQuart(_:)` */
export function easeOutQuart(t: number): number {
  return 1 - Math.pow(1 - t, 4);
}

/** `Easing.easeOutExpo(_:)` */
export function easeOutExpo(t: number): number {
  return t === 1 ? 1 : 1 - Math.pow(2, -10 * t);
}

/** `Easing.spring(_:damping:frequency:)` */
export function spring(t: number, damping = 0.7, frequency = 1.5): number {
  const decay = Math.exp(-damping * frequency * t);
  const oscillation = Math.cos(frequency * Math.PI * 2 * t * Math.sqrt(1 - damping * damping));
  return 1 - decay * oscillation;
}

/** `Easing.regionEnvelope(at:startTime:endTime:transitionDuration:)` —
 * symmetric smootherStep envelope (highlight / blur layers). */
export function regionEnvelope(
  time: number,
  startTime: number,
  endTime: number,
  transitionDuration: number,
): number {
  if (!(endTime >= startTime)) return 0;
  if (!(time >= startTime && time <= endTime)) return 0;

  const regionDuration = smax(0, endTime - startTime);
  const effectiveTransition = smax(0.12, smin(transitionDuration, regionDuration * 0.5));
  const inT = effectiveTransition > 0 ? smin(1, (time - startTime) / effectiveTransition) : 1;
  const outT = effectiveTransition > 0 ? smin(1, (endTime - time) / effectiveTransition) : 1;
  return smin(smootherStep(inT), smootherStep(outT));
}

/** `Easing.zoomEnvelope(at:startTime:endTime:transitionDuration:)` —
 * asymmetric easeOutExpo in / easeOutQuart out, inside the region. */
export function zoomEnvelope(
  time: number,
  startTime: number,
  endTime: number,
  transitionDuration: number,
): number {
  if (!(time >= startTime && time <= endTime)) return 0;

  const regionDuration = smax(0, endTime - startTime);
  const effIn = smax(0.08, smin(transitionDuration * 0.55, regionDuration * 0.28));
  const effOut = smax(0.12, smin(transitionDuration, regionDuration * 0.48));

  const inT = effIn > 0 ? smin(1, (time - startTime) / effIn) : 1;
  const outT = effOut > 0 ? smin(1, (endTime - time) / effOut) : 1;

  const inVal = easeOutExpo(inT);
  const outVal = easeOutQuart(outT);
  return smin(inVal, outVal);
}

export interface ZoomLevelResult {
  zoom: number;
  focalPoint: Point;
  envelope: number;
}

/** `Easing.zoomLevel(at:regions:transitionDuration:)` — first region
 * containing `time` wins; (1, centre, 0) outside every region. */
export function zoomLevel(
  time: number,
  regions: readonly ZoomRegion[],
  transitionDuration: number,
): ZoomLevelResult {
  const center = { x: 0.5, y: 0.5 };
  for (const region of regions) {
    if (!(time >= region.startTime && time <= region.endTime)) continue;
    const envelope = zoomEnvelope(time, region.startTime, region.endTime, transitionDuration);
    const zoom = 1.0 + (region.zoomLevel - 1.0) * envelope;
    const focal = {
      x: center.x + (region.focalPoint.x - center.x) * envelope,
      y: center.y + (region.focalPoint.y - center.y) * envelope,
    };
    return { zoom, focalPoint: focal, envelope };
  }
  return { zoom: 1.0, focalPoint: center, envelope: 0 };
}
