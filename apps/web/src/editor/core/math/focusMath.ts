/**
 * Port of apps/macos/CaptureCat/Services/FocusMath.swift — the Depth Focus
 * blur PROFILE shared by the Mac preview and exporter: constants,
 * `bandWidth`, `blurRadius`, `blurSigma`, `blurAmount`,
 * `roundedRectOutsideDistance`, and `maskImage` (as a pure byte raster:
 * `maskSize` + `maskValue` + `maskImage`).
 *
 * Golden-vector units: `focusMathScalars`, `focusMathMask` (the REAL Swift
 * CGImage — sampled bytes exact, full-raster byte sum + FNV-1a-32, and the
 * same pixels rendered through a CIContext in linear sRGB / RGBAf within 1e-6
 * of byte/255), `exportFocusPlan`, `regionConstants`.
 *
 * ## How the exporter uses the mask (VideoExporter.export, ~1633-1664)
 *
 * For every active FocusRegion (see exportRegions.ts `activeRegionIndices`):
 * 1. `maskImage(region.rect, style, angle, falloff, cornerRadius,
 *    videoSize: layout.videoRect.size)` → an nx × ny 8-bit gray raster
 *    (long side `maskResolution` = 384; ROW 0 = VIDEO TOP; color space
 *    linearGray, so byte/255 IS the linear mask value — no transfer curve).
 *    white (255) = full blur, black (0) = sharp.
 * 2. The raster is stretched onto the video rect: scale (vr.width / nx,
 *    vr.height / ny) then translate to (vr.minX, vr.minY) in CI Y-up space
 *    (so row 0 lands at the video's top edge). CI samples it bilinearly
 *    (default CI affine sampling), so the web must upsample the nx×ny mask
 *    with LINEAR filtering over the video rect (clamp-to-edge).
 * 3. `CIMaskedVariableBlur` on the video layer (clampedToExtent first, result
 *    cropped back to the layer's extent) with `inputRadius` = `blurSigma(
 *    intensity, videoSize)` (a Gaussian SIGMA, = radius / 2 — the house
 *    convention applied ONLY here). CIMaskedVariableBlur blurs each pixel
 *    with sigma × mask(pixel) (mask sampled from its luminance), i.e. a
 *    variable Gaussian: sharp where the mask is 0, full `sigma` where it is 1.
 * The mask is cached per (rect, style, angle, falloff, cornerRadius,
 * Int(vr.width) × Int(vr.height)).
 *
 * Coordinates: unit space is Y-DOWN (top-left origin, the region-rect
 * convention); distances are evaluated in absolute video units via
 * `videoSize` so the profile is aspect-correct.
 */
import { chypot } from "./libm";
import type { FocusRegionStyle } from "../model/enums";
import type { Point, Rect, Size } from "../model/types";
import { insetBy, maxX, maxY, midX, midY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { sInt, smax, smin, srounded } from "./swift";

/** Default corner rounding, 0…1 of HALF the rect's short side. */
export const defaultCornerRadius = 0.24;
/** Falloff band width, fraction of min(video dims). */
export const minBandFraction = 0.02;
export const maxBandFraction = 0.35;
/** SwiftUI-style blur radius at intensity 1, fraction of min(video dims). */
export const maxBlurRadiusFraction = 0.09;
/** Mask raster resolution (long side). */
export const maskResolution = 384;

/** Falloff band width in video units. */
export function bandWidth(falloff: number, videoSize: Size): number {
  const f = smax(0, smin(1, falloff));
  return (minBandFraction + f * (maxBandFraction - minBandFraction)) * smin(videoSize.width, videoSize.height);
}

/** Max blur as a SwiftUI/CG-style radius in video units. */
export function blurRadius(intensity: number, videoSize: Size): number {
  return smax(0, smin(1, intensity)) * maxBlurRadiusFraction * smin(videoSize.width, videoSize.height);
}

/** The CI sigma for that radius (radius / 2) — `CIMaskedVariableBlur.inputRadius`. */
export function blurSigma(intensity: number, videoSize: Size): number {
  return blurRadius(intensity, videoSize) / 2;
}

/**
 * Normalized blur amount 0…1 at `unitPoint` (unit video space, Y-down).
 * 0 = sharp, 1 = full blur.
 */
export function blurAmount(
  unitPoint: Point,
  regionRect: Rect,
  style: FocusRegionStyle,
  angleDegrees: number,
  falloff: number,
  cornerRadius: number = defaultCornerRadius,
  videoSize: Size,
): number {
  const p = { x: unitPoint.x * videoSize.width, y: unitPoint.y * videoSize.height };
  const r: Rect = {
    x: minX(regionRect) * videoSize.width,
    y: minY(regionRect) * videoSize.height,
    width: rectWidth(regionRect) * videoSize.width,
    height: rectHeight(regionRect) * videoSize.height,
  };
  let d: number;
  if (style === "Area") {
    const corner = (smax(0, smin(1, cornerRadius)) * smin(rectWidth(r), rectHeight(r))) / 2;
    d = roundedRectOutsideDistance(p, r, corner);
  } else {
    const c = { x: midX(r), y: midY(r) };
    const a = (angleDegrees * Math.PI) / 180;
    // Band runs along (cos a, sin a) in Y-down space; distance along the
    // perpendicular. Sharp half-width = the rect's short dimension / 2.
    const nx = -Math.sin(a);
    const ny = Math.cos(a);
    const dist = Math.abs((p.x - c.x) * nx + (p.y - c.y) * ny);
    d = dist - smin(rectWidth(r), rectHeight(r)) / 2;
  }
  if (!(d > 0)) return 0;
  const band = smax(0.0001, bandWidth(falloff, videoSize));
  const t = smin(1, d / band);
  return t * t * (3 - 2 * t); // smoothstep 0→1 across the band
}

/** Distance OUTSIDE a rounded rect (0 inside or on the edge). */
export function roundedRectOutsideDistance(p: Point, rect: Rect, cornerRadius: number): number {
  const r = smax(0, smin(cornerRadius, smin(rectWidth(rect), rectHeight(rect)) / 2));
  const inner = insetBy(rect, r, r);
  const dx = smax(minX(inner) - p.x, 0, p.x - maxX(inner));
  const dy = smax(minY(inner) - p.y, 0, p.y - maxY(inner));
  const d = chypot(dx, dy) - r; // Darwin hypot (see libm.ts)
  return smax(0, d);
}

/** The mask raster size (`nx`, `ny`) — nil (null) when either video side ≤ 1. */
export function maskSize(videoSize: Size): { width: number; height: number } | null {
  if (!(videoSize.width > 1 && videoSize.height > 1)) return null;
  const aspect = videoSize.height / videoSize.width;
  let nx: number;
  let ny: number;
  if (aspect <= 1) {
    nx = maskResolution;
    ny = smax(2, sInt(srounded(maskResolution * aspect)));
  } else {
    ny = maskResolution;
    nx = smax(2, sInt(srounded(maskResolution / aspect)));
  }
  return { width: nx, height: ny };
}

/** Region parameters `maskImage` takes. */
export interface FocusMaskParams {
  regionRect: Rect;
  style: FocusRegionStyle;
  angleDegrees: number;
  falloff: number;
  cornerRadius?: number;
  videoSize: Size;
}

/**
 * One mask byte: pixel (i, j) of an nx × ny raster, row 0 = video TOP —
 * `UInt8(max(0, min(255, (amount * 255).rounded())))` of `blurAmount` at the
 * pixel centre ((i + 0.5) / nx, (j + 0.5) / ny).
 */
export function maskValue(i: number, j: number, nx: number, ny: number, params: FocusMaskParams): number {
  const uy = (j + 0.5) / ny;
  const ux = (i + 0.5) / nx;
  const amount = blurAmount(
    { x: ux, y: uy },
    params.regionRect,
    params.style,
    params.angleDegrees,
    params.falloff,
    params.cornerRadius ?? defaultCornerRadius,
    params.videoSize,
  );
  return sInt(smax(0, smin(255, srounded(amount * 255))));
}

/**
 * `FocusMath.maskImage` as a byte raster (row-major, row 0 = video top,
 * `pixels[j * width + i]`). Upload as an r8unorm texture and treat byte/255
 * as LINEAR (the Swift CGImage is linearGray).
 */
export function maskImage(params: FocusMaskParams): { width: number; height: number; pixels: Uint8Array } | null {
  const size = maskSize(params.videoSize);
  if (!size) return null;
  const { width: nx, height: ny } = size;
  const pixels = new Uint8Array(nx * ny);
  for (let j = 0; j < ny; j++) {
    for (let i = 0; i < nx; i++) pixels[j * nx + i] = maskValue(i, j, nx, ny, params);
  }
  return { width: nx, height: ny, pixels };
}
