/**
 * Port of Services/CursorSmoother.swift — the zero-lag symmetric cursor path
 * smoother plus the bracketing interpolation every cursor consumer uses
 * (exporter camera follow, cursor overlay, click chain).
 *
 * Locked to Swift by the `cursorSmoother` golden vectors.
 *
 * Note (faithful port): the window half-width is
 * `Int(((1/factor) − 1) / 2.0.rounded())` — Swift's `.rounded()` binds to the
 * literal `2.0`, so the quotient is TRUNCATED, not rounded. Kept as-is.
 */
import type { CursorEvent, Point } from "../model/types";
import { sInt, smax, smin } from "./swift";

export const freshnessThreshold = 0.12;

/** `CursorSmoother(factor:).smooth(events:)` */
export function smooth(events: readonly CursorEvent[], factor = 0.15): CursorEvent[] {
  if (!(events.length > 2 && factor > 0 && factor < 1)) return events.slice();
  const half = smin(15, smax(1, sInt((1.0 / factor - 1.0) / 2.0)));
  const out: CursorEvent[] = new Array(events.length);
  const last = events.length - 1;
  for (let i = 0; i < events.length; i++) {
    const lo = smax(0, i - half);
    const hi = smin(last, i + half);
    let sx = 0.0;
    let sy = 0.0;
    for (let j = lo; j <= hi; j++) {
      sx += events[j].x;
      sy += events[j].y;
    }
    const n = hi - lo + 1;
    const e = events[i];
    out[i] = {
      timestamp: e.timestamp,
      // A click must stay on the sample it happened on.
      x: e.isClick ? e.x : sx / n,
      y: e.isClick ? e.y : sy / n,
      isClick: e.isClick,
    };
  }
  return out;
}

/** `CursorSmoother.interpolate(events:at:)` — linear between the bracketing
 * samples (binary search), clamped to the ends; `.zero` when empty. */
export function interpolate(events: readonly CursorEvent[], time: number): Point {
  if (events.length === 0) return { x: 0, y: 0 };
  if (events.length === 1) return { x: events[0].x, y: events[0].y };

  let lo = 0;
  let hi = events.length - 1;
  if (time <= events[lo].timestamp) return { x: events[lo].x, y: events[lo].y };
  if (time >= events[hi].timestamp) return { x: events[hi].x, y: events[hi].y };

  while (hi - lo > 1) {
    const mid = Math.trunc((lo + hi) / 2);
    if (events[mid].timestamp <= time) lo = mid;
    else hi = mid;
  }

  const a = events[lo];
  const b = events[hi];
  const dt = b.timestamp - a.timestamp;
  if (!(dt > 0)) return { x: a.x, y: a.y };
  const t = (time - a.timestamp) / dt;
  return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
}

/** `CursorSmoother.interpolateIfFresh(events:at:freshnessThreshold:)` — nil
 * before the first sample or more than `threshold` past the last. */
export function interpolateIfFresh(
  events: readonly CursorEvent[],
  time: number,
  threshold: number = freshnessThreshold,
): Point | null {
  if (events.length === 0) return null;
  const first = events[0];
  const last = events[events.length - 1];
  if (!(time >= first.timestamp && time <= last.timestamp + threshold)) return null;
  if (time >= last.timestamp) {
    if (!(time - last.timestamp <= threshold)) return null;
    return { x: last.x, y: last.y };
  }
  return interpolate(events, time);
}
