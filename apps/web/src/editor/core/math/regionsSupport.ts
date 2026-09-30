/**
 * Shared helpers for the REGIONS cluster ports — candidates for hoisting into
 * shared modules (see the notes on each export).
 *
 * - `continuousRoundedRectPath` ports Services/ContinuousRoundedRect.swift
 *   `path(rect:cornerRadius:)` (Apple's continuous-corner "squircle", used by
 *   the device bezel, the squircle frame shape, curtain clip and annotations).
 *   Locked by the golden-vector unit `continuousRoundedPath` (every CGPath
 *   element, incl. the `CGPath(rect:)` fallback). It belongs in its own
 *   `continuousRoundedRect.ts` once the coordinator hoists it.
 * - `cgRectPath` reproduces `CGPath(rect:transform: nil)` element emission.
 * - `SRGBA` mirrors Services/OklabGradient.swift `SRGBA` (straight alpha).
 * - `flipRectY` is the CI (Y-up) ↔ Y-down conversion every exporter-space
 *   rect needs at the GPU boundary.
 */
import { cgPathRect } from "./styleSupport";
import * as CRR from "./continuousRoundedRect";
import { toTyped } from "./pathElements";
import type { Point, Rect } from "../model/types";
import { maxX, maxY, midY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { smax, smin } from "./swift";

/** One CGPath element, in emission order (`CGPath.applyWithBlock`). */
export type PathElement =
  | { type: "move"; points: [Point] }
  | { type: "line"; points: [Point] }
  | { type: "quad"; points: [Point, Point] }
  | { type: "curve"; points: [Point, Point, Point] }
  | { type: "close"; points: [] };

/** OklabGradient.swift SRGBA — single source: oklabGradient.ts. */
export type { SRGBA } from "./oklabGradient";
export { srgbaWhite } from "./oklabGradient";
import type { SRGBA as OklabSRGBA } from "./oklabGradient";

export function srgba(red: number, green: number, blue: number, alpha = 1): OklabSRGBA {
  return { red, green, blue, alpha };
}

/** `CGPath(rect:transform: nil)` — move(minX,minY) → (maxX,minY) → (maxX,maxY)
 * → (minX,maxY) → close, on the STANDARDIZED rect (vector-verified). */
export function cgRectPath(rect: Rect): PathElement[] {
  return toTyped(cgPathRect(rect));
}

// ── ContinuousRoundedRect.swift ─────────────────────────────────────────────

/** Corner reach as a multiple of `r` when nothing is capping it. */
export const continuousFullReach = 1.528665;
const aFull = 1.08849;
const bFull = 0.868407;
const aMin = 0.96;
const bMin = 0.82;
const endLong = 0.631494;
const endShort = 0.074911;
const midLong = 0.372824;
const midShort = 0.16906;

function controls(p: number): { a: number; b: number } {
  const t = (p - 1) / (continuousFullReach - 1);
  return { a: aMin + (aFull - aMin) * t, b: bMin + (bFull - bMin) * t };
}

function pt(x: number, y: number): Point {
  return { x, y };
}

/**
 * `ContinuousRoundedRect.path(rect:cornerRadius:)` — the continuous-corner
 * rounded rect as CGPath elements (Y-down or Y-up agnostic: it only uses the
 * rect's min/max). Emission order mirrors SwiftUI: start mid-right edge, then
 * bottom-right → bottom-left → top-left → top-right ("bottom" = maxY).
 */
export function continuousRoundedRectPath(rect: Rect, cornerRadius: number): PathElement[] {
  return toTyped(CRR.path(rect, cornerRadius));
}

/** Hoisted to geometry.ts (single source). */
export { flipRectY } from "./geometry";
