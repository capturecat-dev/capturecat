/**
 * Region geometry — ports of the region models' math:
 *
 * - Models/BlurRegion.swift: `rectInViewSpace(in:)`, `rectInImageSpace(in:)`,
 *   `blurRadius(in:)`, `duration`, `previewCornerRadius`;
 * - Models/BlurRegion+Feather.swift: `featherRadius(in:)`, `featherSigma(in:)`
 *   and the feather constants;
 * - Models/HighlightRegion.swift: `rectInViewSpace`, `rectInImageSpace`,
 *   `cornerRadius(for:in:)` (static), `cornerRadius(in:)`, `dimOpacity`,
 *   `duration`, `previewCornerRadius`, `cornerRadiusRatio`;
 * - Models/FocusRegion.swift: `rectInViewSpace(in:)`, `duration`.
 *
 * Golden-vector units: `blurRegionGeometry`, `highlightRegionGeometry`,
 * `focusRegionGeometry`, `regionConstants` (core/vectors/regions.test.ts).
 *
 * Coordinates: `region.rect` is normalized 0…1 of the visible video frame,
 * Y-DOWN (top-left origin). `rectInViewSpace` maps it into a Y-DOWN container
 * (the preview's view space); `rectInImageSpace` maps it into a Y-UP
 * container (CoreImage — the exporter's output-pixel space), flipping Y
 * inside the container. Swift reads `rect.origin.x/y` RAW but `rect.width /
 * height` ABSOLUTE and `containerRect.minX/minY/maxY/width/height`
 * standardized — ported accessor-for-accessor.
 *
 * Blur-sigma conventions (CLAUDE.md: CIGaussianBlur's inputRadius is a sigma):
 * - `featherSigma` = `featherRadius / 2` — the exporter's CIGaussianBlur on the
 *   region MASK (see exportRegions.ts).
 * - `blurRadius(in:)` — NOTE the exporter passes this value to CIGaussianBlur
 *   UNHALVED as the sigma, while the Mac preview halves it (a preview/export
 *   mismatch in Swift; the web follows the exporter). See exportRegions.ts.
 */
import type { BlurRegion, FocusRegion, HighlightRegion, Rect, Size } from "../model/types";
import { maxY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { smax, smin } from "./swift";

// ── BlurRegion ──────────────────────────────────────────────────────────────

/** `BlurRegion.previewCornerRadius`. */
export const blurRegionPreviewCornerRadius = 0;
/** `BlurRegion.blurFeatherFraction` — feather width, fraction of the smaller side. */
export const blurFeatherFraction = 0.1;
/** `BlurRegion.blurFeatherMinimum` — floor in the evaluating space's units. */
export const blurFeatherMinimum = 6;
/** `BlurRegion.blurFeatherMaxFraction` — ceiling, fraction of the smaller side. */
export const blurFeatherMaxFraction = 0.25;

type HasRect = { rect: Rect };

/** `rectInViewSpace(in:)` (identical body on Blur/Highlight/FocusRegion). */
function rectInViewSpace(region: HasRect, containerRect: Rect): Rect {
  const r = region.rect;
  return {
    x: minX(containerRect) + r.x * rectWidth(containerRect),
    y: minY(containerRect) + r.y * rectHeight(containerRect),
    width: rectWidth(r) * rectWidth(containerRect),
    height: rectHeight(r) * rectHeight(containerRect),
  };
}

/** `rectInImageSpace(in:)` (identical body on Blur/HighlightRegion). */
function rectInImageSpace(region: HasRect, containerRect: Rect): Rect {
  const r = region.rect;
  return {
    x: minX(containerRect) + r.x * rectWidth(containerRect),
    y: maxY(containerRect) - (r.y + rectHeight(r)) * rectHeight(containerRect),
    width: rectWidth(r) * rectWidth(containerRect),
    height: rectHeight(r) * rectHeight(containerRect),
  };
}

export function blurRegionDuration(region: Pick<BlurRegion, "startTime" | "endTime">): number {
  return region.endTime - region.startTime;
}

export function blurRegionRectInViewSpace(region: Pick<BlurRegion, "rect">, containerRect: Rect): Rect {
  return rectInViewSpace(region, containerRect);
}

export function blurRegionRectInImageSpace(region: Pick<BlurRegion, "rect">, containerRect: Rect): Rect {
  return rectInImageSpace(region, containerRect);
}

/** `BlurRegion.blurRadius(in:)` — clamped 6…36, scaled by intensity. */
export function blurRegionBlurRadius(region: Pick<BlurRegion, "rect" | "intensity">, containerSize: Size): number {
  const blurWidth = rectWidth(region.rect) * containerSize.width;
  const blurHeight = rectHeight(region.rect) * containerSize.height;
  const maxBlur = smax(blurWidth, blurHeight) * 0.18;
  const clampedIntensity = smax(0.1, smin(1.0, region.intensity));
  return smin(36, smax(6, maxBlur * clampedIntensity));
}

/** `BlurRegion.featherRadius(in:)` — SwiftUI-style feather radius. */
export function blurRegionFeatherRadius(region: Pick<BlurRegion, "rect">, containerSize: Size): number {
  const width = rectWidth(region.rect) * containerSize.width;
  const height = rectHeight(region.rect) * containerSize.height;
  const smallerSide = smin(width, height);
  if (!(smallerSide > 0)) return 0;
  const ceiling = smallerSide * blurFeatherMaxFraction;
  const preferred = smax(smallerSide * blurFeatherFraction, blurFeatherMinimum);
  return smin(ceiling, preferred);
}

/** `BlurRegion.featherSigma(in:)` — the CI Gaussian sigma (= radius / 2). */
export function blurRegionFeatherSigma(region: Pick<BlurRegion, "rect">, containerSize: Size): number {
  return blurRegionFeatherRadius(region, containerSize) / 2;
}

// ── HighlightRegion ─────────────────────────────────────────────────────────

/** `HighlightRegion.previewCornerRadius`. */
export const highlightPreviewCornerRadius = 16;
/** `HighlightRegion.cornerRadiusRatio`. */
export const highlightCornerRadiusRatio = 0.12;

export function highlightRegionDuration(region: Pick<HighlightRegion, "startTime" | "endTime">): number {
  return region.endTime - region.startTime;
}

export function highlightRegionRectInViewSpace(region: Pick<HighlightRegion, "rect">, containerRect: Rect): Rect {
  return rectInViewSpace(region, containerRect);
}

export function highlightRegionRectInImageSpace(region: Pick<HighlightRegion, "rect">, containerRect: Rect): Rect {
  return rectInImageSpace(region, containerRect);
}

/** `HighlightRegion.cornerRadius(for:in:)` (static). */
export function highlightCornerRadiusFor(rect: Rect, containerRect: Rect): number {
  const pixelMinDimension = smin(
    rectWidth(rect) * rectWidth(containerRect),
    rectHeight(rect) * rectHeight(containerRect),
  );
  return smin(pixelMinDimension / 2, smax(6, smin(pixelMinDimension * highlightCornerRadiusRatio, 24)));
}

/** `HighlightRegion.cornerRadius(in:)`. */
export function highlightRegionCornerRadius(region: Pick<HighlightRegion, "rect">, containerRect: Rect): number {
  return highlightCornerRadiusFor(region.rect, containerRect);
}

/** `HighlightRegion.dimOpacity` — outside dim clamped to 0.05…0.95. */
export function highlightRegionDimOpacity(region: Pick<HighlightRegion, "opacity">): number {
  return smax(0.05, smin(0.95, region.opacity));
}

// ── FocusRegion ─────────────────────────────────────────────────────────────

export function focusRegionDuration(region: Pick<FocusRegion, "startTime" | "endTime">): number {
  return region.endTime - region.startTime;
}

export function focusRegionRectInViewSpace(region: Pick<FocusRegion, "rect">, containerRect: Rect): Rect {
  return rectInViewSpace(region, containerRect);
}
