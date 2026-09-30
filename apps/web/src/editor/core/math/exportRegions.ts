/**
 * The exporter's region compositing NUMBERS — ports of private / inline code
 * in apps/macos/CaptureCat/Services/VideoExporter.swift (commit da569841):
 *
 * - per-frame selection (export(), 1614-1616 / 1630-1632 / 1783-1785);
 * - `applyRegionBlur` (2636-2724);
 * - `applyRegionHighlight` (2726-2804) + `highlightOutsideMaskImage`
 *   geometry (2806-2877);
 * - the Depth Focus block (1633-1664; the mask itself is focusMath.ts);
 * - `Easing.regionEnvelope` / `Easing.smootherStep`
 *   (Services/EasingFunctions.swift — hoist into a shared `easing.ts`).
 *
 * Golden-vector units (verbatim oracles in WebVectors+RegionsOracle.swift):
 * `exportActiveRegions`, `exportRegionBlur`, `exportRegionHighlight`,
 * `exportFocusPlan`; `regionEnvelope` locks the real Easing functions.
 *
 * ## Spaces and order (what the web renderer must do)
 * All times are SOURCE seconds (`currentTime` = the frame's source time from
 * the SpeedTimeMap). All rects here are the exporter's CI space: output
 * pixels, Y-UP (origin bottom-left) — flip with `flipRectY(rect, outputH)`
 * (regionsSupport.ts) at the GPU boundary. `containerRect` is
 * `layout.videoRect` of the UNZOOMED card (`compositeFrame` runs with
 * zoom 1.0): blur, focus and highlight are baked into the card BEFORE the
 * card-level transforms (camera-layout squeeze, device dip, perspective tilt,
 * zoom about the focal point), so on screen the regions ride those transforms
 * exactly like the video does.
 *
 * Per frame, in this order (VideoExporter.export ~1613-1795):
 * 1. every active BLUR region, in project order, onto the (window-masked)
 *    video layer — `exportRegionBlurPlan`;
 * 2. every active FOCUS region, in project order — `exportFocusPlan`;
 * 3. outer frame clip, device-segment clip, compose over the card base,
 *    menu bar, island, cursor + click ripple;
 * 4. every active HIGHLIGHT region, in project order, over the whole
 *    composited frame (cursor included) — `exportRegionHighlightPlan`;
 * 5. subtitles, keystrokes, annotations, curtain, then the card transforms.
 *
 * Timing: a region is active when `start <= t && t <= end` (both inclusive).
 * Blur and Depth Focus regions have NO fade — they switch on/off hard at
 * those bounds (only the pixelate grid animates, per `BlurStyleMath`
 * 0.125 s step). Highlights fade in/out with `regionEnvelope(t, start, end,
 * settings.animationSpeed.duration)` INSIDE the region.
 *
 * ### Blur region (CoreImage recipe)
 * - blurred = style == "Blur":
 *     CIGaussianBlur(video.clampedToExtent(), inputRadius = gaussianRadius)
 *     — inputRadius IS the Gaussian sigma, and the exporter passes
 *     `blurRadius(in:)` UNHALVED (the Mac preview uses radius / 2: a Swift
 *     preview/export mismatch; the web must follow the exporter);
 *   style == "Pixelate":
 *     CIPixellate(video.clampedToExtent(), inputScale = pixellate.scale,
 *     inputCenter = pixellate.center) — blocks of `scale` px tiled from
 *     `center` (CI Y-UP: the region's BOTTOM-left + jitter).
 *   Both cropped back to the video layer's extent.
 * - mask = a HARD rect (CI crop: pixel centres inside `pixelRect` = 1, no
 *   antialiasing) over transparent; when `feathered` it is Gaussian-blurred
 *   (clampedToExtent first, so a region flush with the frame edge does not
 *   fade there) with sigma `featherSigma`.
 * - out = mix(video, blurred, mask) (CIBlendWithMask).
 *
 * ### Highlight region (dim outside a rounded hole)
 * - mask raster (`mask`): `width × height` = ceil of the frame extent; white
 *   over `dimRect` (the video rect), then a BLACK circular-corner rounded rect
 *   (`CGPath(roundedRect:)`, radius `cornerRadius`) over `holeRect`; CG
 *   antialiased; the bitmap is sRGB-tagged 8-bit, so CI linearises edge
 *   coverage through the sRGB curve. Outside `dimRect` the raster is
 *   transparent (mask 0).
 * - dark = black with alpha `linearOpacity`, masked by that raster, then
 *   source-over the frame. In LINEAR light: out = frame × (1 − linearOpacity ×
 *   mask). `linearOpacity = 1 − (1 − dimOpacity × envelope)^2.2` converts the
 *   SwiftUI sRGB-space dim into CI's linear compositing.
 */
import type { BlurRegion, FocusRegion, HighlightRegion, Rect } from "../model/types";
import { type AffineTransform, rectHeight, rectWidth, minX, minY, concatTransform, scaleTransform, translationTransform } from "./geometry";
import { gridJitter, pixelScale } from "./blurStyleMath";
import { blurSigma, maskSize } from "./focusMath";
import {
  blurRegionBlurRadius,
  blurRegionFeatherSigma,
  blurRegionRectInImageSpace,
  highlightRegionCornerRadius,
  highlightRegionDimOpacity,
  highlightRegionRectInImageSpace,
} from "./regionGeometry";
import { smax, smin } from "./swift";

// ── Easing (Services/EasingFunctions.swift) ─────────────────────────────────
// Single source: easing.ts (locked by `easingEnvelopes` + `regionEnvelope`).
import { regionEnvelope, smootherStep } from "./easing";
export { regionEnvelope, smootherStep };

// ── Per-frame selection ─────────────────────────────────────────────────────

type Timed = { startTime: number; endTime: number };

/** `regions.filter { currentTime >= $0.startTime && currentTime <= $0.endTime }`
 * — indices in project order (bounds inclusive). */
export function activeRegionIndices(regions: readonly Timed[], currentTime: number): number[] {
  const out: number[] = [];
  regions.forEach((r, i) => {
    if (currentTime >= r.startTime && currentTime <= r.endTime) out.push(i);
  });
  return out;
}

// ── applyRegionBlur ─────────────────────────────────────────────────────────

export interface RegionBlurPlan {
  /** False → the region is skipped (zero/NaN-size pixel rect). */
  applied: boolean;
  /** `rectInImageSpace(in: containerRect)` — CI Y-UP output px. */
  pixelRect: Rect;
  style?: BlurRegion["style"];
  /** CIGaussianBlur inputRadius (a SIGMA) for style "Blur", else null. */
  gaussianRadius?: number | null;
  /** CIPixellate parameters for style "Pixelate", else null. */
  pixellate?: { scale: number; center: { x: number; y: number } } | null;
  /** CIGaussianBlur sigma for the region MASK. */
  featherSigma?: number;
  /** The mask is blurred only when featherSigma > 0.01. */
  feathered?: boolean;
}

/** The numbers `applyRegionBlur(to:region:containerRect:at:)` feeds CoreImage. */
export function exportRegionBlurPlan(region: BlurRegion, containerRect: Rect, currentTime: number): RegionBlurPlan {
  const pixelRect = blurRegionRectInImageSpace(region, containerRect);
  if (!(rectWidth(pixelRect) > 0 && rectHeight(pixelRect) > 0)) return { applied: false, pixelRect };
  const containerSize = { width: containerRect.width, height: containerRect.height };
  let gaussianRadius: number | null = null;
  let pixellate: RegionBlurPlan["pixellate"] = null;
  if (region.style === "Blur") {
    gaussianRadius = blurRegionBlurRadius(region, containerSize);
  } else {
    const block = pixelScale(region.intensity, { width: pixelRect.width, height: pixelRect.height });
    const jitter = gridJitter(currentTime, region.animated, block);
    pixellate = { scale: block, center: { x: minX(pixelRect) + jitter.x, y: minY(pixelRect) + jitter.y } };
  }
  const featherSigma = blurRegionFeatherSigma(region, containerSize);
  return {
    applied: true,
    pixelRect,
    style: region.style,
    gaussianRadius,
    pixellate,
    featherSigma,
    feathered: featherSigma > 0.01,
  };
}

// ── applyRegionHighlight + highlightOutsideMaskImage ────────────────────────

export interface RegionHighlightPlan {
  /** False → the frame is returned untouched. */
  applied: boolean;
  pixelRect: Rect;
  cornerRadius?: number;
  envelope?: number;
  /** `dimOpacity × envelope` (sRGB-space dim, the preview's layer opacity). */
  srgbOpacity?: number;
  /** Alpha of the black overlay CI composites in linear light. */
  linearOpacity?: number;
  /** The outside mask raster: size, white `dimRect`, black rounded `holeRect`
   * (both relative to the raster origin; CI Y-UP), placed at `translate`. */
  mask?: { width: number; height: number; dimRect: Rect; holeRect: Rect; cornerRadius: number; translate: { x: number; y: number } } | null;
}

/**
 * The numbers `applyRegionHighlight(to:region:dimRect:containerRect:currentTime:
 * transitionDuration:)` computes. The exporter passes `dimRect ==
 * containerRect == layout.videoRect` and `imageExtent` = the output frame
 * (0, 0, W, H); `transitionDuration` = `settings.animationSpeed.duration`.
 */
export function exportRegionHighlightPlan(
  region: HighlightRegion,
  imageExtent: Rect,
  dimRect: Rect,
  containerRect: Rect,
  currentTime: number,
  transitionDuration: number,
): RegionHighlightPlan {
  const pixelRect = highlightRegionRectInImageSpace(region, containerRect);
  if (!(rectWidth(pixelRect) > 0 && rectHeight(pixelRect) > 0)) return { applied: false, pixelRect };
  const cornerRadius = highlightRegionCornerRadius(region, containerRect);
  const envelope = regionEnvelope(currentTime, region.startTime, region.endTime, transitionDuration);
  if (!(envelope > 0)) return { applied: false, pixelRect, cornerRadius, envelope };
  // Gamma-correct opacity: linear_opacity = 1 - (1 - srgb_opacity)^2.2
  const srgbOpacity = highlightRegionDimOpacity(region) * envelope;
  const linearOpacity = 1.0 - Math.pow(1.0 - srgbOpacity, 2.2);

  const extent = imageExtent;
  const holeRect = pixelRect;
  const width = Math.ceil(rectWidth(extent));
  const height = Math.ceil(rectHeight(extent));
  let mask: RegionHighlightPlan["mask"] = null;
  if (width > 0 && height > 0) {
    mask = {
      width,
      height,
      dimRect: {
        x: minX(dimRect) - minX(extent),
        y: minY(dimRect) - minY(extent),
        width: rectWidth(dimRect),
        height: rectHeight(dimRect),
      },
      holeRect: {
        x: minX(holeRect) - minX(extent),
        y: minY(holeRect) - minY(extent),
        width: rectWidth(holeRect),
        height: rectHeight(holeRect),
      },
      cornerRadius,
      translate: { x: minX(extent), y: minY(extent) },
    };
  }
  return { applied: mask !== null, pixelRect, cornerRadius, envelope, srgbOpacity, linearOpacity, mask };
}

// ── Depth Focus (VideoExporter 1633-1664) ───────────────────────────────────

export interface FocusPlan {
  /** Mask raster size + its CI placement (scale to the video rect, then
   * translate to its CI Y-UP origin); null → no focus blur (video ≤ 1 px). */
  mask: { width: number; height: number; transform: AffineTransform } | null;
  /** CIMaskedVariableBlur inputRadius (a sigma). */
  sigma: number;
}

/** What the exporter does for one active FocusRegion over `videoRect` (CI Y-UP). */
export function exportFocusPlan(region: FocusRegion, videoRect: Rect): FocusPlan {
  const videoSize = { width: videoRect.width, height: videoRect.height };
  const size = maskSize(videoSize);
  let mask: FocusPlan["mask"] = null;
  if (size) {
    const transform = concatTransform(
      scaleTransform(rectWidth(videoRect) / size.width, rectHeight(videoRect) / size.height),
      translationTransform(minX(videoRect), minY(videoRect)),
    );
    mask = { width: size.width, height: size.height, transform };
  }
  return { mask, sigma: blurSigma(region.intensity, videoSize) };
}
