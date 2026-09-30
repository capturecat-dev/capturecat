/**
 * Port of Services/CursorSpringMath.swift `CursorSpringMath` — fluid cursor
 * movement: a damped spring (semi-implicit Euler at a fixed 240 Hz step,
 * resampled to 120 Hz) chases the recorded path, with click pinning over
 * PRESSED INTERVALS so a click never moves off the thing it clicked.
 *
 * Funcs: `apply(events:settings:)`, `simulate(events:tension:friction:mass:)`
 * and the constants.
 *
 * Locked to Swift by the `cursorSpringSimulate` golden vectors (and, as part
 * of the full chain, `cursorChain`). Only `+ − × ÷` — no libm — so the port
 * is bit-exact when the operation order matches (it does, term for term).
 *
 * Swift returns the SAME array when a guard fails (value semantics); the port
 * returns a shallow copy so callers can never alias the input.
 */
import type { CursorEvent, ProjectSettings } from "../model/types";
import { interpolate } from "./cursorSmoother";
import { smax, smin } from "./swift";

/** Integration step (Hz). Fixed so the result is bit-identical everywhere. */
export const simulationRate = 240;
/** Output sample rate of the resimulated path (Hz). */
export const outputRate = 120;
/** Seconds around a click over which the spring blends into the raw pin. */
export const clickPinWindow = 0.12;

/** Swift `ClosedRange<Double>` bounds. */
export interface ClosedRange {
  readonly lowerBound: number;
  readonly upperBound: number;
}
export const tensionRange: ClosedRange = Object.freeze({ lowerBound: 20, upperBound: 600 });
export const frictionRange: ClosedRange = Object.freeze({ lowerBound: 2, upperBound: 80 });
export const massRange: ClosedRange = Object.freeze({ lowerBound: 0.2, upperBound: 6 });

export type CursorSpringSettings = Pick<
  ProjectSettings,
  "cursorFluidEnabled" | "cursorTension" | "cursorFriction" | "cursorMass"
>;

/** `CursorSpringMath.apply(events:settings:)` — the pipeline entry point both
 * renderers call after smoothing. */
export function apply(events: readonly CursorEvent[], settings: CursorSpringSettings): CursorEvent[] {
  if (!settings.cursorFluidEnabled) return events.slice();
  return simulate(events, settings.cursorTension, settings.cursorFriction, settings.cursorMass);
}

/** `CursorSpringMath.simulate(events:tension:friction:mass:)`. */
export function simulate(
  events: readonly CursorEvent[],
  tension: number,
  friction: number,
  mass: number,
): CursorEvent[] {
  if (!(events.length > 1)) return events.slice();
  const first = events[0];
  const last = events[events.length - 1];
  if (!(last.timestamp > first.timestamp)) return events.slice();

  const k = smin(tensionRange.upperBound, smax(tensionRange.lowerBound, tension));
  const c = smin(frictionRange.upperBound, smax(frictionRange.lowerBound, friction));
  const m = smin(massRange.upperBound, smax(massRange.lowerBound, mass));

  const dt = 1 / simulationRate;
  const emitStep = 1 / outputRate;

  let px = first.x;
  let py = first.y;
  let vx = 0.0;
  let vy = 0.0;
  const out: CursorEvent[] = [];

  let t = first.timestamp;
  let nextEmit = first.timestamp;
  while (t <= last.timestamp + dt / 2) {
    const target = interpolate(events, t);
    // Semi-implicit Euler: a = (k·(target − p) − c·v) / m.
    vx += ((k * (target.x - px) - c * vx) / m) * dt;
    vy += ((k * (target.y - py) - c * vy) / m) * dt;
    px += vx * dt;
    py += vy * dt;
    if (t >= nextEmit - dt / 2) {
      out.push({ timestamp: t, x: px, y: py, isClick: false });
      nextEmit += emitStep;
    }
    t += dt;
  }
  if (out.length === 0) return events.slice();

  // Click pinning over PRESSED INTERVALS (runs of isClick samples).
  const intervals: { start: number; end: number }[] = [];
  let runStart: number | null = null;
  let runEnd: number | null = null;
  for (const event of events) {
    if (event.isClick) {
      if (runStart === null) runStart = event.timestamp;
      runEnd = event.timestamp;
    } else if (runStart !== null && runEnd !== null) {
      intervals.push({ start: runStart, end: runEnd });
      runStart = null;
      runEnd = null;
    }
  }
  if (runStart !== null && runEnd !== null) intervals.push({ start: runStart, end: runEnd });
  if (intervals.length === 0) return out;

  let intervalIndex = 0;
  for (let i = 0; i < out.length; i++) {
    const sampleTime = out[i].timestamp;
    while (
      intervalIndex + 1 < intervals.length &&
      sampleTime > intervals[intervalIndex].end + clickPinWindow
    ) {
      intervalIndex += 1;
    }
    const interval = intervals[intervalIndex];
    let distance: number;
    if (sampleTime < interval.start) {
      distance = interval.start - sampleTime;
    } else if (sampleTime > interval.end) {
      distance = sampleTime - interval.end;
    } else {
      distance = 0;
    }
    if (!(distance < clickPinWindow)) continue;
    const raw = interpolate(events, sampleTime);
    // Half an output period of slack (see Swift).
    if (distance <= emitStep / 2) {
      out[i] = { timestamp: sampleTime, x: raw.x, y: raw.y, isClick: true };
    } else {
      // Smoothstep 1 at the interval edge → 0 at the window edge.
      const u = 1 - distance / clickPinWindow;
      const w = u * u * (3 - 2 * u);
      out[i] = {
        timestamp: sampleTime,
        x: out[i].x + (raw.x - out[i].x) * w,
        y: out[i].y + (raw.y - out[i].y) * w,
        isClick: false,
      };
    }
  }
  return out;
}
