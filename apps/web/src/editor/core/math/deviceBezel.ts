/**
 * The iPhone 16 Pro chrome as a DRAW RECIPE (numbers only) — port of
 * apps/macos/CaptureCat/Services/DeviceBezelRenderer.swift (drawSideButtons
 * 171-209, drawSideSlab 215-228, drawBody 233-320, drawIsland 323-362,
 * fillVertical 367-387) and the exporter's layer split in
 * Services/DeviceFrameRenderer.swift (34-78).
 *
 * Golden-vector unit: `deviceBezelRecipe` (verbatim oracle over the REAL
 * DeviceFrameLayout.metrics), plus deviceFrameLayout.ts's units.
 *
 * ## Space
 * Everything is Y-DOWN (the screen's TOP is `videoRect.minY`), in output
 * pixels for the exporter / points × scale for a preview raster. The
 * exporter's rects are CI Y-UP: `DeviceFrameRenderer.flip` =
 * `flipRectY(videoRectCI, extent.height)` first.
 *
 * ## Paint semantics the renderer must implement
 * - Every `{rect, cornerRadius}` shape is `ContinuousRoundedRect.path`
 *   (`continuousRoundedPath` in deviceFrameLayout.ts) EXCEPT the island pill
 *   (`CGPath(roundedRect:)`: a circular-corner capsule, radius = h/2) and the
 *   lens (ellipse).
 * - A stroke of `lineWidth` is centred on its path (CG stroke). The Swift
 *   already pre-insets rects by half the line width where it wants an inside
 *   stroke — draw the numbers as given.
 * - Gradients: linear from `start` to `end`, extended before/after
 *   (`.drawsBeforeStartLocation, .drawsAfterEndLocation`), stops in sRGB with
 *   straight alpha, interpolated in PREMULTIPLIED OKLAB (OklabGradient.swift
 *   `mix`: Lab weighted by alpha, alpha linear), pre-sampled by Swift into
 *   257 sRGB stops then linearly interpolated by CG. A port of
 *   OklabGradient belongs with the background-gradient cluster.
 * - Fills are CLIPPED to their shape (`clip` = the shape's continuous path).
 * - The rim: the stroke outline of the rim path (`replacePathWithStrokedPath`)
 *   is the clip; the white gradient fills it.
 * - Body: band + rim + AO are drawn inside ONE transparency layer carrying the
 *   drop shadow (`shadow`: CGContext.setShadow offset/blur/colour — blur in
 *   DEVICE pixels, already × deviceScale here). The exporter passes
 *   shadowRadius/opacity 0 (it composites its own `makeFrameShadow` layer),
 *   so its shadow colour alpha is 0.
 * - Draw order (preview, one raster): sideButtons, sideSlab (offset by
 *   TiltMath.deviceSideOffset in Y-down), body(+shadow), glass; island layer
 *   above the video.
 * - Exporter layers (per whole-take or per stitched segment): bezel image =
 *   sideButtons + body (shadow 0) — static; side image = sideSlab with
 *   offset ZERO, translated per frame by deviceSideOffset(pitch, yaw,
 *   videoWidth) with y NEGATED for CI (only when max(|pitch|,|yaw|) > 0.05°);
 *   island image = seam + pill + lens above the video (phone aspect only).
 */
import type { Rect, Size } from "../model/types";
import {
  bandBottom,
  bandMid,
  bandTop,
  buttonBottom,
  buttonRim,
  buttonTop,
  cameraDotFraction,
  cameraDotOffsetFraction,
  glassColor,
  innerShadow,
  isPhoneAspect,
  islandSize,
  islandTopInset,
  metrics,
  metricsValue,
  rgbMix,
  rgbSRGBA,
  rimHighlight,
  rimMid,
  rimShadowSide,
  sideBottom,
  sideButtons,
  sideTop,
  type RGB,
} from "./deviceFrameLayout";
import { insetBy, maxX, maxY, midX, midY, minX, minY, offsetBy, rectHeight, rectWidth } from "./geometry";
import { type SRGBA, srgba, srgbaWhite } from "./regionsSupport";
import { smax } from "./swift";

/** `DeviceBezelRenderer.shadowBlurFactor` — SwiftUI `.shadow(radius:)` vs CG blur (measured). */
export const shadowBlurFactor = 2.2;

export interface GradientStop {
  location: number;
  color: SRGBA;
}

/** A linear gradient (Oklab-interpolated, extended both ends). */
export interface LinearGradient {
  stops: GradientStop[];
  start: { x: number; y: number };
  end: { x: number; y: number };
}

export interface SideButtonRecipe {
  rect: Rect;
  cornerRadius: number;
  fill: LinearGradient;
  hairline: { rect: Rect; cornerRadius: number; lineWidth: number; color: SRGBA };
}

export interface SideSlabRecipe {
  rect: Rect;
  cornerRadius: number;
  fill: LinearGradient;
}

export interface BodyRecipe {
  rect: Rect;
  cornerRadius: number;
  shadow: { offset: Size; blur: number; color: SRGBA };
  band: LinearGradient;
  rim: { rect: Rect; cornerRadius: number; lineWidth: number; gradient: LinearGradient };
  ao: { rect: Rect; cornerRadius: number; lineWidth: number; color: SRGBA };
  glass: { rect: Rect; cornerRadius: number; color: SRGBA } | null;
}

export interface IslandRecipe {
  seam: { rect: Rect; cornerRadius: number; lineWidth: number; color: SRGBA };
  /** Circular-corner capsule (`CGPath(roundedRect:)`), filled. */
  pill: { rect: Rect; cornerRadius: number; color: SRGBA };
  /** Filled ellipse. */
  lens: { rect: Rect; color: SRGBA };
  /** Stroked ellipse. */
  lensRing: { rect: Rect; lineWidth: number; color: SRGBA };
}

/** `fillVertical` — three-stop top → bottom ramp over `rect`. */
export function fillVertical(rect: Rect, top: RGB, mid: RGB, bottom: RGB): LinearGradient {
  return {
    stops: [
      { location: 0, color: rgbSRGBA(top) },
      { location: 0.5, color: rgbSRGBA(mid) },
      { location: 1, color: rgbSRGBA(bottom) },
    ],
    start: { x: midX(rect), y: minY(rect) },
    end: { x: midX(rect), y: maxY(rect) },
  };
}

/** `drawSideButtons(in:videoRect:)` — empty unless phone aspect. */
export function sideButtonsRecipe(videoRect: Rect): SideButtonRecipe[] {
  const m = metrics(videoRect);
  const bezelRect = m.bodyRect;
  if (!(rectWidth(bezelRect) > 0 && rectHeight(bezelRect) > 0)) return [];
  const out: SideButtonRecipe[] = [];
  if (m.isPhone) {
    for (const button of sideButtons) {
      const thickness = smax(1, metricsValue(m, button.thicknessFraction));
      const w = thickness + 1;
      const h = rectHeight(bezelRect) * button.lengthFraction;
      const cx = button.isLeft ? minX(bezelRect) - w / 2 + 1 : maxX(bezelRect) + w / 2 - 1;
      const cy = minY(bezelRect) + rectHeight(bezelRect) * button.centerFraction;
      const rect: Rect = { x: cx - w / 2, y: cy - h / 2, width: w, height: h };
      const lw = smax(0.75, thickness * 0.16);
      out.push({
        rect,
        cornerRadius: thickness / 2,
        fill: fillVertical(rect, buttonTop, rgbMix(buttonTop, buttonBottom), buttonBottom),
        hairline: {
          rect: insetBy(rect, lw / 2, lw / 2),
          cornerRadius: smax(0, thickness / 2 - lw / 2),
          lineWidth: lw,
          color: srgbaWhite(1, buttonRim),
        },
      });
    }
  }
  return out;
}

/** `drawSideSlab(in:videoRect:offset:)` — null when the rect is empty. */
export function sideSlabRecipe(videoRect: Rect, offset: Size): SideSlabRecipe | null {
  const m = metrics(videoRect);
  const sideRect = offsetBy(m.bodyRect, offset.width, offset.height);
  if (!(rectWidth(sideRect) > 0 && rectHeight(sideRect) > 0)) return null;
  return {
    rect: sideRect,
    cornerRadius: m.bodyCornerRadius,
    fill: fillVertical(sideRect, sideTop, rgbMix(sideTop, sideBottom), sideBottom),
  };
}

/**
 * `drawBody(in:videoRect:shadowRadius:shadowOpacity:)`. `deviceScale` =
 * `sqrt(|ctm.a·ctm.d − ctm.b·ctm.c|)` of the drawing context (the raster
 * scale; 1 for the exporter's 1:1 bitmap).
 */
export function bodyRecipe(
  videoRect: Rect,
  shadowRadius: number,
  shadowOpacity: number,
  deviceScale: number,
): BodyRecipe | null {
  const m = metrics(videoRect);
  const bezelRect = m.bodyRect;
  const radius = m.bodyCornerRadius;
  if (!(rectWidth(bezelRect) > 0 && rectHeight(bezelRect) > 0)) return null;
  const rim = m.rimWidth;
  const aoInset = rim * 1.5;
  const glass =
    m.isPhone && !rectsEqual(m.glassRect, m.screenRect)
      ? { rect: m.glassRect, cornerRadius: m.glassCornerRadius, color: rgbSRGBA(glassColor) }
      : null;
  return {
    rect: bezelRect,
    cornerRadius: radius,
    shadow: {
      offset: { width: 0, height: shadowRadius / 3 },
      blur: shadowRadius * shadowBlurFactor * deviceScale,
      color: srgbaWhite(0, 0.45 * shadowOpacity),
    },
    band: fillVertical(bezelRect, bandTop, bandMid, bandBottom),
    rim: {
      rect: insetBy(bezelRect, rim / 2, rim / 2),
      cornerRadius: smax(0, radius - rim / 2),
      lineWidth: rim,
      gradient: {
        stops: [
          { location: 0, color: srgbaWhite(1, rimHighlight) },
          { location: 0.5, color: srgbaWhite(1, rimMid) },
          { location: 1, color: srgbaWhite(1, rimShadowSide) },
        ],
        start: { x: minX(bezelRect), y: minY(bezelRect) },
        end: { x: maxX(bezelRect), y: maxY(bezelRect) },
      },
    },
    ao: {
      rect: insetBy(bezelRect, aoInset, aoInset),
      cornerRadius: smax(0, radius - 2 * aoInset),
      lineWidth: smax(1, rim * 0.6),
      color: srgbaWhite(0, innerShadow),
    },
    glass,
  };
}

/** `drawIsland(in:videoRect:)` — null unless phone aspect. */
export function islandRecipe(videoRect: Rect): IslandRecipe | null {
  if (!isPhoneAspect({ width: videoRect.width, height: videoRect.height })) return null;
  const m = metrics(videoRect);
  const seam = m.seamWidth;
  const size = islandSize(rectWidth(videoRect));
  const topInset = islandTopInset(rectWidth(videoRect));
  const rect: Rect = {
    x: midX(videoRect) - size.width / 2,
    y: minY(videoRect) + topInset,
    width: size.width,
    height: size.height,
  };
  const dot = metricsValue(m, cameraDotFraction);
  const dotRect: Rect = {
    x: midX(rect) + metricsValue(m, cameraDotOffsetFraction) - dot / 2,
    y: midY(rect) - dot / 2,
    width: dot,
    height: dot,
  };
  return {
    seam: {
      rect: insetBy(videoRect, seam / 2, seam / 2),
      cornerRadius: m.screenCornerRadius,
      lineWidth: seam,
      color: srgbaWhite(0, 0.55),
    },
    pill: { rect, cornerRadius: size.height / 2, color: srgbaWhite(0) },
    lens: { rect: dotRect, color: srgba(0.07, 0.08, 0.11) },
    lensRing: {
      rect: insetBy(dotRect, dot * 0.05, dot * 0.05),
      lineWidth: smax(0.5, dot * 0.1),
      color: srgbaWhite(1, 0.13),
    },
  };
}

/** `CGRect ==` (CGRectEqualToRect compares the standardized rects). */
function rectsEqual(a: Rect, b: Rect): boolean {
  return minX(a) === minX(b) && minY(a) === minY(b) && rectWidth(a) === rectWidth(b) && rectHeight(a) === rectHeight(b);
}
