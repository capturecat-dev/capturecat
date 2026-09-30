/**
 * Per-frame REGION plans in the engine's space — pure TS (no GPU), shared by
 * the preview and the web exporter (they run the same passes).
 *
 * Every number comes from the core ports locked to the Mac EXPORTER
 * (`core/math/exportRegions.ts`: `exportRegionBlurPlan`,
 * `exportRegionHighlightPlan`, `exportFocusPlan`, `activeRegionIndices`; the
 * mask raster from `core/math/focusMath.ts`). This file only converts spaces:
 *
 *   exporter space  CI output pixels, Y-UP, the EXPORT's resolution
 *   engine space    card/target pixels, Y-DOWN (the canvas we draw into)
 *
 * The plans are evaluated at the EXPORT resolution and scaled by
 * `k = target / export` (1 in the web exporter): the region math has
 * absolute clamps in output pixels (blur σ 6…36, pixelate block ≥ 3, feather
 * ≥ 6, highlight corner 6…24), so evaluating it at a small preview canvas
 * would draw a different picture than the export. With k the preview is the
 * export, scaled — exactly what the user will get.
 *
 * KNOWN MAC BUG, PORTED ON PURPOSE: the exporter passes
 * `BlurRegion.blurRadius(in:)` to CIGaussianBlur UNHALVED, i.e. as the σ (the
 * Mac preview halves it). The export is the reference, so `gaussianSigma` here
 * is the full radius — the web matches the Mac EXPORT, not its preview.
 */
import type { BlurRegion, FocusRegion, HighlightRegion, Project, Rect } from "../../core/model";
import { animationSpeedDuration } from "../../core/model/enums";
import {
  activeRegionIndices,
  exportFocusPlan,
  exportRegionBlurPlan,
  exportRegionHighlightPlan,
} from "../../core/math/exportRegions";
import { maskImage } from "../../core/math/focusMath";
import { resolvedOutputSize, type Size } from "../layout";
import type { Scene } from "./types";

/** Export-resolution frame the plans are evaluated in. */
export interface ExportSpace {
  /** Target pixels per export pixel. */
  k: number;
  /** Export canvas size (Y-flip), = target / k. */
  widthE: number;
  heightE: number;
}

export function exportSpace(scene: Pick<Scene, "settings" | "sourceSize" | "target">): ExportSpace {
  const s = scene.settings;
  const out = resolvedOutputSize(s.exportSettings, s.aspectRatio, scene.sourceSize);
  let k = Math.min(scene.target.width / out.width, scene.target.height / out.height);
  if (!(k > 0) || !Number.isFinite(k)) k = 1;
  // Snap near-1 (the exporter renders at exactly the output size).
  if (Math.abs(k - 1) < 1e-9) k = 1;
  return { k, widthE: scene.target.width / k, heightE: scene.target.height / k };
}

/** Engine Y-down target rect → exporter Y-up export rect. */
export function toExportRect(r: Rect, sp: ExportSpace): Rect {
  const { k, heightE } = sp;
  return { x: r.x / k, y: heightE - (r.y + r.height) / k, width: r.width / k, height: r.height / k };
}

/** Exporter Y-up export rect → engine Y-down target rect. */
export function fromExportRect(r: Rect, sp: ExportSpace): Rect {
  const { k, heightE } = sp;
  return { x: r.x * k, y: (heightE - (r.y + r.height)) * k, width: r.width * k, height: r.height * k };
}

// ── Blur regions (applyRegionBlur) ──────────────────────────────────────────

export interface BlurOp {
  index: number;
  id: string;
  style: "Blur" | "Pixelate";
  /** Hard mask rect (CI crop → area coverage), Y-down target px. */
  rect: Rect;
  /** CIGaussianBlur σ in target px (style Blur) — the UNHALVED radius (Mac export). */
  sigma: number;
  /** CIPixellate block size in target px (style Pixelate). */
  block: number;
  /** Pixelate grid anchor, Y-down target px: x boundaries at gx + n·block,
   * y boundaries at gy + n·block (CI anchors the grid at inputCenter, Y-up). */
  gx: number;
  gy: number;
  /** Mask feather σ in target px; 0 = hard mask. */
  featherSigma: number;
}

export function blurOps(project: Project, videoRect: Rect, sourceTime: number, sp: ExportSpace): BlurOp[] {
  const ops: BlurOp[] = [];
  const container = toExportRect(videoRect, sp);
  for (const i of activeRegionIndices(project.blurRegions, sourceTime)) {
    const region: BlurRegion = project.blurRegions[i];
    const plan = exportRegionBlurPlan(region, container, sourceTime);
    if (!plan.applied) continue;
    const rect = fromExportRect(plan.pixelRect, sp);
    const px = plan.pixellate;
    ops.push({
      index: i,
      id: region.id,
      style: region.style,
      rect,
      sigma: (plan.gaussianRadius ?? 0) * sp.k,
      block: (px?.scale ?? 0) * sp.k,
      gx: (px?.center.x ?? 0) * sp.k,
      gy: (sp.heightE - (px?.center.y ?? 0)) * sp.k,
      featherSigma: plan.feathered ? (plan.featherSigma ?? 0) * sp.k : 0,
    });
  }
  return ops;
}

// ── Depth Focus (VideoExporter 1621-1659) ───────────────────────────────────

export interface FocusOp {
  index: number;
  id: string;
  /** CIMaskedVariableBlur inputRadius in target px (= FocusMath.blurSigma). */
  sigma: number;
  /** The same inputRadius in EXPORT px (CI's pyramid knots live there). */
  radiusE: number;
  /** The FocusMath mask raster (row 0 = video top, byte/255 LINEAR gray). */
  maskKey: string;
  mask: () => { width: number; height: number; pixels: Uint8Array } | null;
  /** Where the raster is stretched (the video rect), Y-down target px. */
  rect: Rect;
}

export function focusOps(project: Project, videoRect: Rect, sourceTime: number, sp: ExportSpace): FocusOp[] {
  const ops: FocusOp[] = [];
  const vr = toExportRect(videoRect, sp);
  for (const i of activeRegionIndices(project.focusRegions, sourceTime)) {
    const region: FocusRegion = project.focusRegions[i];
    const plan = exportFocusPlan(region, vr);
    if (!plan.mask) continue;
    const r = region.rect;
    // The exporter's cache key (VideoExporter 1630): rect, style, angle,
    // falloff, cornerRadius and Int(vr.width) × Int(vr.height).
    const maskKey = `${r.x},${r.y},${r.width},${r.height}|${region.style}|${region.angle}|${region.falloff}|${region.cornerRadius}|${Math.trunc(vr.width)}x${Math.trunc(vr.height)}`;
    ops.push({
      index: i,
      id: region.id,
      sigma: plan.sigma * sp.k,
      radiusE: plan.sigma,
      maskKey,
      mask: () =>
        maskImage({
          regionRect: region.rect,
          style: region.style,
          angleDegrees: region.angle,
          falloff: region.falloff,
          cornerRadius: region.cornerRadius,
          videoSize: { width: vr.width, height: vr.height },
        }),
      rect: videoRect,
    });
  }
  return ops;
}

// ── Highlight regions (applyRegionHighlight) ───────────────────────────────

export interface HighlightOp {
  index: number;
  /** The white fill (dimRect == layout.videoRect), Y-down target px. */
  dimRect: Rect;
  /** The black rounded hole, Y-down target px. */
  holeRect: Rect;
  /** CGPath(roundedRect:) circular corner radius, target px. */
  cornerRadius: number;
  /** Alpha of the black overlay (1 − (1 − dim·envelope)^2.2). */
  alpha: number;
  envelope: number;
}

export function highlightOps(
  project: Project,
  videoRect: Rect,
  sourceTime: number,
  sp: ExportSpace,
): HighlightOp[] {
  const ops: HighlightOp[] = [];
  const vr = toExportRect(videoRect, sp);
  const transition = animationSpeedDuration(project.settings.animationSpeed);
  for (const i of activeRegionIndices(project.highlightRegions, sourceTime)) {
    const region: HighlightRegion = project.highlightRegions[i];
    // imageExtent = the output frame (origin 0,0); the engine draws the mask
    // analytically in that same pixel grid.
    const plan = exportRegionHighlightPlan(
      region,
      { x: 0, y: 0, width: sp.widthE, height: sp.heightE },
      vr,
      vr,
      sourceTime,
      transition,
    );
    if (!plan.applied || !plan.mask) continue;
    ops.push({
      index: i,
      dimRect: videoRect,
      holeRect: fromExportRect(plan.pixelRect, sp),
      cornerRadius: (plan.cornerRadius ?? 0) * sp.k,
      alpha: plan.linearOpacity ?? 0,
      envelope: plan.envelope ?? 0,
    });
  }
  return ops;
}

// ── CIMaskedVariableBlur model (Depth Focus) ────────────────────────────────

/**
 * CIMaskedVariableBlur, as measured on this Mac (line-spread functions over a
 * mask sweep at inputRadius 20 / 40, CoreImage in the exporter's gamma sRGB
 * working space):
 *  - per-pixel radius r = inputRadius × mask, the mask read in the WORKING
 *    (gamma) space, i.e. sRGB-encode(byte/255) of FocusMath's linearGray raster;
 *  - a factor-2 pyramid: levels at r = 1.5·2^k with line-spread sd ≈ f·r
 *    (f = 0.96, 1.005, 1.016, 1.018, …); below r = 0.75 the pixel is sharp;
 *  - between two levels the output is lerp(L_k, L_k+1, log2(r / r_k))
 *    (predicts sd 18.30 / 10.94 at r = 16 / 10; measured 18.303 / 10.944).
 * (A plain Gaussian at σ = radius·mask is visibly wrong: CI's kernel has
 * sd 1.095 × radius at mask 1 and heavier tails between levels.)
 */
export const MVB_SHARP_R = 0.75;
export const MVB_LEVEL0_R = 1.5;
export const MVB_LEVEL_SD = [0.96, 1.005, 1.016, 1.018];

/** The CIMaskedVariableBlur pyramid up to `radius` (export px): level radius r + its line-spread sd. */
export function maskedVariableBlurLevels(radius: number): { r: number; sd: number }[] {
  const levels = [{ r: MVB_SHARP_R, sd: 0 }];
  if (!(radius > MVB_SHARP_R)) return levels;
  for (let k = 0; k < 16; k++) {
    const r = MVB_LEVEL0_R * 2 ** k;
    levels.push({ r, sd: r * MVB_LEVEL_SD[Math.min(k, MVB_LEVEL_SD.length - 1)] });
    if (r >= radius) break;
  }
  return levels;
}

/** Per-level weights for a pixel of radius r (log2-linear between knots; sums to 1). */
export function maskedVariableBlurWeights(levels: { r: number }[], r: number): number[] {
  const x = Math.log2(Math.max(r, 1e-6));
  return levels.map((_, i) => {
    const mid = Math.log2(levels[i].r);
    const lo = i === 0 ? null : Math.log2(levels[i - 1].r);
    const hi = i === levels.length - 1 ? null : Math.log2(levels[i + 1].r);
    if (x <= mid) return lo === null ? 1 : x > lo ? (x - lo) / (mid - lo) : 0;
    return hi === null ? 1 : x < hi ? (hi - x) / (hi - mid) : 0;
  });
}

/** Mip level + corrected σ for a Gaussian of `sigma` (full-res px) run on a 2^j downsample. */
export function blurLevel(sigma: number, minLow: number, maxLevel = 6): { j: number; d: number; sigmaLow: number } {
  let j = 0;
  while (j < maxLevel && sigma / 2 ** (j + 1) >= minLow) j++;
  const d = 2 ** j;
  // 2×2-box mip chain adds (d²−1)/12, bilinear upsample ≈ (d²−1)/6 (px²).
  const v = sigma * sigma - (d * d - 1) / 4;
  return { j, d, sigmaLow: Math.max(0.35, Math.sqrt(Math.max(v, 0)) / d) };
}

/** Full-res clamp padding for a pyramid serving σ at level factor d (a multiple of d). */
export function padFor(sigma: number, d: number): number {
  return Math.ceil((3 * sigma + 2 * d) / d) * d;
}

/** Integer pixel rect covering `r` (CI rounds a fractional extent OUT). */
export function roundOut(r: Rect): { x0: number; y0: number; x1: number; y1: number } {
  return {
    x0: Math.floor(r.x + 1e-9),
    y0: Math.floor(r.y + 1e-9),
    x1: Math.ceil(r.x + r.width - 1e-9),
    y1: Math.ceil(r.y + r.height - 1e-9),
  };
}

export function intersectRect(a: Rect, b: Rect): Rect {
  const x0 = Math.max(a.x, b.x);
  const y0 = Math.max(a.y, b.y);
  const x1 = Math.min(a.x + a.width, b.x + b.width);
  const y1 = Math.min(a.y + a.height, b.y + b.height);
  return { x: x0, y: y0, width: Math.max(0, x1 - x0), height: Math.max(0, y1 - y0) };
}

/**
 * The video LAYER's extent (compositeFrame): with a window mask the layer is
 * blended over clear cropped to contentRect → extent = contentRect; without
 * one it is the video cropped to videoRect ∩ contentRect. CI rounds it out to
 * whole pixels, and `clampedToExtent()` clamps at those pixels.
 */
export function videoLayerExtent(videoRect: Rect, contentRect: Rect, windowMasked: boolean, target: Size) {
  const r = roundOut(windowMasked ? contentRect : intersectRect(videoRect, contentRect));
  const x0 = Math.max(0, r.x0);
  const y0 = Math.max(0, r.y0);
  const x1 = Math.min(target.width, r.x1);
  const y1 = Math.min(target.height, r.y1);
  return { x: x0, y: y0, width: Math.max(0, x1 - x0), height: Math.max(0, y1 - y0) };
}

/**
 * Separable feathered mask of one blur region over the layer extent `E`
 * (VideoExporter.applyRegionBlur): the hard mask is `white.cropped(to:
 * pixelRect)` — CI crop = exact AREA coverage per pixel, which is separable
 * (cx(x)·cy(y)); feathering is CIGaussianBlur(σ) of `hardMask.clampedToExtent()`
 * cropped back to the extent, i.e. a clamped 1-D Gaussian per axis. Returns
 * the two factors (length E.width / E.height) so the GPU evaluates
 * mask(x, y) = mx[x] · my[y] exactly.
 */
export function featherFactors(rect: Rect, featherSigma: number, E: Rect): { mx: Float32Array; my: Float32Array } {
  const axis = (lo: number, hi: number, origin: number, n: number) => {
    const c = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      const p0 = origin + i;
      c[i] = Math.max(0, Math.min(p0 + 1, hi) - Math.max(p0, lo));
    }
    const out = new Float32Array(n);
    if (!(featherSigma > 0.01)) {
      for (let i = 0; i < n; i++) out[i] = c[i];
      return out;
    }
    const r = Math.max(1, Math.ceil(featherSigma * 3));
    const w = new Float64Array(2 * r + 1);
    let sum = 0;
    for (let t = -r; t <= r; t++) sum += w[t + r] = Math.exp(-(t * t) / (2 * featherSigma * featherSigma));
    for (let i = 0; i < n; i++) {
      let acc = 0;
      for (let t = -r; t <= r; t++) {
        const j = Math.min(n - 1, Math.max(0, i + t)); // clampedToExtent
        acc += w[t + r] * c[j];
      }
      out[i] = acc / sum;
    }
    return out;
  };
  return {
    mx: axis(rect.x, rect.x + rect.width, E.x, Math.max(1, E.width)),
    my: axis(rect.y, rect.y + rect.height, E.y, Math.max(1, E.height)),
  };
}
