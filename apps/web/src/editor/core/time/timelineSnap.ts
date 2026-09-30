/**
 * Port of Views/Editor/TimelineSnap.swift — the timeline's snap grid and
 * candidate snapping (shared by every track's drag math).
 * Locked to Swift by the `timelineSnap` golden vectors.
 */
import { smax, smin, srounded } from "../math/swift";

const MAJOR_CANDIDATES = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300];

export function majorInterval(pixelsPerSecond: number): number {
  for (const interval of MAJOR_CANDIDATES) {
    if (pixelsPerSecond * interval >= 72) return interval;
  }
  return 300;
}

export function minorInterval(duration: number, trackWidth: number): number {
  if (!(duration > 0 && trackWidth > 0)) return 0;
  const pixelsPerSecond = trackWidth / duration;
  return smax(0.1, majorInterval(pixelsPerSecond) / 5);
}

export function snap(time: number, duration: number, trackWidth: number): number {
  const interval = minorInterval(duration, trackWidth);
  if (!(interval > 0)) return time;
  return srounded(time / interval) * interval;
}

export function snapThreshold(duration: number, trackWidth: number): number {
  if (!(duration > 0 && trackWidth > 0)) return 0;
  // 16px of grab.
  const pixelThresholdTime = (duration * 16) / trackWidth;
  return smax(pixelThresholdTime, minorInterval(duration, trackWidth) * 0.35);
}

export function clampTime(time: number, duration: number): number {
  return smax(0, smin(duration, time));
}

export function nearestCandidate(
  time: number,
  candidates: readonly number[],
  duration: number,
  trackWidth: number,
): number | null {
  const threshold = snapThreshold(duration, trackWidth);
  if (!(threshold > 0)) return null;
  // `.map → .filter(distance <= threshold) → .min(by: distance <)` — Swift's
  // min(by:) keeps the FIRST minimum (replaces only on strictly-less).
  let best: { candidate: number; distance: number } | null = null;
  for (const candidate of candidates) {
    const entry = { candidate: clampTime(candidate, duration), distance: Math.abs(candidate - time) };
    if (!(entry.distance <= threshold)) continue;
    if (best === null || entry.distance < best.distance) best = entry;
  }
  return best ? best.candidate : null;
}

export function magneticSnap(
  time: number,
  candidates: readonly number[],
  duration: number,
  trackWidth: number,
): number {
  const c = nearestCandidate(time, candidates, duration, trackWidth);
  if (c !== null) return c;
  return snap(time, duration, trackWidth);
}

/** Which edge of a resolved block rests on a snap candidate (the guide line). */
export function snappedEdge(
  start: number,
  end: number,
  candidates: readonly number[],
  checkStart: boolean,
  checkEnd: boolean,
): number | null {
  const epsilon = 0.0005;
  if (checkStart && candidates.some((c) => Math.abs(c - start) < epsilon)) return start;
  if (checkEnd && candidates.some((c) => Math.abs(c - end) < epsilon)) return end;
  return null;
}
