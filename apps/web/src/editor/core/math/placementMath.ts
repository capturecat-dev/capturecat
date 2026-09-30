/**
 * Port of Services/PlacementMath.swift — the nine-way video placement grid
 * and the freeform (drag-anywhere) card position. Fractions are normalized
 * and Y-DOWN (preview convention). Locked by the `placementMath` vectors.
 */
import type { VideoPlacement } from "../model/enums";
import type { Point, ProjectSettings, Size } from "../model/types";
import { smax, smin } from "./swift";

export interface Fractions {
  x: number;
  y: number;
}

/** Normalized anchor for each placement, Y-down. */
export const fractions: Readonly<Record<VideoPlacement, Fractions>> = {
  "Top Left": { x: 0, y: 0 },
  Top: { x: 0.5, y: 0 },
  "Top Right": { x: 1, y: 0 },
  Left: { x: 0, y: 0.5 },
  Center: { x: 0.5, y: 0.5 },
  Right: { x: 1, y: 0.5 },
  "Bottom Left": { x: 0, y: 1 },
  Bottom: { x: 0.5, y: 1 },
  "Bottom Right": { x: 1, y: 1 },
};

/** Snaps a normalized coordinate onto one of the three grid fractions. */
export function snap(f: number): number {
  return f < 1.0 / 3 ? 0 : f > 2.0 / 3 ? 1 : 0.5;
}

/** Nearest of the nine placements for a normalized (Y-down) canvas point. */
export function nearest(fx: number, fy: number): VideoPlacement {
  const tx = snap(fx);
  const ty = snap(fy);
  for (const [k, v] of Object.entries(fractions) as Array<[VideoPlacement, Fractions]>) {
    if (v.x === tx && v.y === ty) return k;
  }
  return "Center";
}

/** Grid-anchor magnetism for a freeform drop (per axis). */
export const magnetism = 0.05;

/** How far beyond the canvas a freeform card centre may travel. */
export const customFractionRange = { lowerBound: -1.0, upperBound: 2.0 } as const;

type PlacementSettings = Pick<ProjectSettings, "videoPlacement" | "videoCustomX" | "videoCustomY">;

/** Whether the freeform override is active (both axes set). */
export function isCustom(settings: PlacementSettings): boolean {
  return settings.videoCustomX != null && settings.videoCustomY != null;
}

/** Freeform card origin: the fraction is the CARD CENTRE over the canvas. Y-DOWN. */
export function customOrigin(fraction: Fractions, canvas: Size, video: Size): Point {
  return {
    x: canvas.width * fraction.x - video.width / 2,
    y: canvas.height * fraction.y - video.height / 2,
  };
}

/** Effective alignment fractions (Y-DOWN): the freeform override when set,
 * else the placement enum's anchor. SINGLE SOURCE for both renderers. */
export function alignment(settings: PlacementSettings): Fractions {
  if (settings.videoCustomX != null && settings.videoCustomY != null) {
    const r = customFractionRange;
    return {
      x: smin(r.upperBound, smax(r.lowerBound, settings.videoCustomX)),
      y: smin(r.upperBound, smax(r.lowerBound, settings.videoCustomY)),
    };
  }
  return fractions[settings.videoPlacement] ?? { x: 0.5, y: 0.5 };
}
