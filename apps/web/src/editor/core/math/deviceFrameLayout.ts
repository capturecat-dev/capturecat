/**
 * Port of apps/macos/CaptureCat/Services/DeviceFrameLayout.swift — the shared
 * geometry + materials for the iPhone 16 Pro bezel (a CLAUDE.md "shared
 * source of truth": the preview compositor and the exporter both read it).
 *
 * All fractions are relative to the SCREEN WIDTH (the video rect's width).
 * Functions are coordinate-convention agnostic (they only inset/outset
 * symmetric rects); the bezel renderer draws them Y-DOWN (see deviceBezel.ts).
 *
 * Golden-vector units: `deviceFrameLayoutConstants`, `deviceFrameLayoutRGB`,
 * `deviceFrameLayoutScalars`, `deviceFrameLayoutMetrics`,
 * `continuousRoundedPath` (suite core/vectors/regions.test.ts).
 *
 * CGRect semantics matter here: Swift reads `videoRect.width` (ABSOLUTE) for
 * the unit but `videoRect.size` (RAW) for `isPhoneAspect` /
 * `screenCornerRadius` — ported accessor-for-accessor.
 */
import type { Rect, Size } from "../model/types";
import { insetBy, rectWidth } from "./geometry";
import { type PathElement, type SRGBA, continuousRoundedRectPath } from "./regionsSupport";
import { smax } from "./swift";

// ── Colors ──────────────────────────────────────────────────────────────────

/** `DeviceFrameLayout.RGB` — tiny sRGB triple (+ alpha). */
export interface RGB {
  r: number;
  g: number;
  b: number;
  a: number;
}

/** `RGB(_:_:_:_:)`. */
export function rgb(r: number, g: number, b: number, a = 1): RGB {
  return { r, g, b, a };
}

/** `RGB(hex:alpha:)` — from an 8-bit hex literal (`UInt32`; bits above 24 ignored). */
export function rgbFromHex(hex: number, alpha = 1): RGB {
  return rgb(((hex >>> 16) & 0xff) / 255, ((hex >>> 8) & 0xff) / 255, (hex & 0xff) / 255, alpha);
}

/** `RGB.mix(_:_:_:)` — linear blend (default t = 0.5, the middle gradient stop). */
export function rgbMix(x: RGB, y: RGB, t = 0.5): RGB {
  return rgb(x.r + (y.r - x.r) * t, x.g + (y.g - x.g) * t, x.b + (y.b - x.b) * t, x.a + (y.a - x.a) * t);
}

/** `RGB.srgba`. */
export function rgbSRGBA(c: RGB): SRGBA {
  return { red: c.r, green: c.g, blue: c.b, alpha: c.a };
}

// ── Black titanium finish ───────────────────────────────────────────────────

export const bandTop = rgbFromHex(0x4c4a47);
export const bandMid = rgbFromHex(0x2e2c2a);
export const bandBottom = rgbFromHex(0x242220);
export const sideTop = rgbFromHex(0x232120);
export const sideBottom = rgbFromHex(0x0d0c0c);
export const glassColor = rgbFromHex(0x0a0a0b);

export const rimHighlight = 0.58;
export const rimMid = 0.1;
export const rimShadowSide = 0.28;
export const innerShadow = 0.5;

// ── Side buttons ────────────────────────────────────────────────────────────

export const buttonTop = rgbFromHex(0x3e3c3a);
export const buttonBottom = rgbFromHex(0x232120);
export const buttonRim = 0.3;

/** `DeviceFrameLayout.SideButton` — fractions of the BODY height from the
 * screen-TOP end; `thicknessFraction` of the screen width. */
export interface SideButton {
  centerFraction: number;
  lengthFraction: number;
  isLeft: boolean;
  thicknessFraction: number;
}

export const sideButtons: readonly SideButton[] = [
  // Left rail
  { centerFraction: 0.185, lengthFraction: 0.045, isLeft: true, thicknessFraction: 0.012 }, // Action
  { centerFraction: 0.268, lengthFraction: 0.072, isLeft: true, thicknessFraction: 0.013 }, // Volume up
  { centerFraction: 0.36, lengthFraction: 0.072, isLeft: true, thicknessFraction: 0.013 }, // Volume down
  // Right rail
  { centerFraction: 0.283, lengthFraction: 0.118, isLeft: false, thicknessFraction: 0.013 }, // Side / power
  { centerFraction: 0.455, lengthFraction: 0.075, isLeft: false, thicknessFraction: 0.008 }, // Camera Control
];

// ── Metrics (fractions of the screen width) ─────────────────────────────────

export const borderFraction = 0.042;
export const glassMarginFraction = 0.012;
export const screenCornerFraction = 0.155;
export const islandWidthFraction = 0.315;
export const islandHeightFraction = 0.093;
export const islandTopFraction = 0.028;
export const cameraDotFraction = 0.03;
export const cameraDotOffsetFraction = 0.1;
export const padCornerFraction = 0.045;

/** Polished-rim stroke width. */
export function rimWidth(width: number): number {
  return smax(1, width * 0.0045);
}

/** Dark seam stroked around the screen. */
export function seamWidth(width: number): number {
  return smax(1, width * 0.002);
}

/** `continuousRoundedPath(rect:cornerRadius:)` → `ContinuousRoundedRect.path`. */
export function continuousRoundedPath(rect: Rect, cornerRadius: number): PathElement[] {
  return continuousRoundedRectPath(rect, cornerRadius);
}

// ── Derived geometry ────────────────────────────────────────────────────────

/** Portrait-phone aspect (≈19.5:9) — RAW size fields. */
export function isPhoneAspect(size: Size): boolean {
  return size.height > size.width * 1.5;
}

/** Border width for a given screen width. */
export function bezelWidth(videoWidth: number): number {
  return smax(4, videoWidth * borderFraction);
}

export function screenCornerRadius(videoSize: Size): number {
  return videoSize.width * (isPhoneAspect(videoSize) ? screenCornerFraction : padCornerFraction);
}

export function bezelRect(videoRect: Rect): Rect {
  const bezel = bezelWidth(rectWidth(videoRect));
  return insetBy(videoRect, -bezel, -bezel);
}

export function bezelCornerRadius(videoSize: Size): number {
  return screenCornerRadius(videoSize) + bezelWidth(videoSize.width);
}

/** Dynamic Island pill size; only meaningful for phone-aspect video. */
export function islandSize(videoWidth: number): Size {
  return { width: videoWidth * islandWidthFraction, height: videoWidth * islandHeightFraction };
}

export function islandTopInset(videoWidth: number): number {
  return videoWidth * islandTopFraction;
}

// ── Resolved metrics ────────────────────────────────────────────────────────

/** `DeviceFrameLayout.Metrics`. */
export interface Metrics {
  isPhone: boolean;
  /** Screen width — the unit all fractions are expressed in. */
  unit: number;
  screenRect: Rect;
  screenCornerRadius: number;
  bodyRect: Rect;
  bodyCornerRadius: number;
  /** Black glass ring hugging the screen. */
  glassRect: Rect;
  glassCornerRadius: number;
  rimWidth: number;
  seamWidth: number;
}

/** `Metrics.value(_:)`. */
export function metricsValue(m: Metrics, fraction: number): number {
  return m.unit * fraction;
}

export function metrics(videoRect: Rect): Metrics {
  const size: Size = { width: videoRect.width, height: videoRect.height };
  const isPhone = isPhoneAspect(size);
  const unit = rectWidth(videoRect);
  const screenRadius = screenCornerRadius(size);
  const glassMargin = isPhone ? unit * glassMarginFraction : 0;
  return {
    isPhone,
    unit,
    screenRect: videoRect,
    screenCornerRadius: screenRadius,
    bodyRect: bezelRect(videoRect),
    bodyCornerRadius: bezelCornerRadius(size),
    glassRect: insetBy(videoRect, -glassMargin, -glassMargin),
    glassCornerRadius: screenRadius + glassMargin,
    rimWidth: rimWidth(unit),
    seamWidth: seamWidth(unit),
  };
}
