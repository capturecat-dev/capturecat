/**
 * The camera bubble's STATIC assets, rasterised once per scene on the CPU —
 * the web twin of the exporter's `CameraStaticAssets` bake
 * (VideoExporter.export: `cameraShapeMaskImage`, `cameraShapeStrokeImage`,
 * `cameraShapeShadowImage`, `CameraStyleMath.ringImage`,
 * `CameraStyleMath.tagBitmap`). All numbers come from the core port
 * (`exportCameraStatics`, `ringRecipe`, `tagBitmapRecipe`); this file only
 * rasterises them.
 *
 * Each result is a premultiplied RGBA8 bitmap in the WORKING space plus where
 * it sits in Y-DOWN output pixels at the canonical `baseRect`; the passes
 * re-target it every frame with the per-frame `assetTransform` (bilinear),
 * exactly as the Mac re-targets its baked CIImages — so stroke width, shadow
 * blur and tag scale WITH the bubble.
 *
 * CG bitmaps are Y-UP with their bottom-left at the extent origin; Canvas2D is
 * Y-down, so paths from the core (Y-up, bitmap-relative) are drawn through a
 * vertical flip and the bitmap's top-left lands at (x, H − y − rows).
 */
import type { ProjectSettings, Rect, Size } from "../../core/model/types";
import type { ExportCameraAssets, MaskBitmap, StrokeBitmap } from "../../core/math/exportCameraBubble";
import {
  ringColor,
  systemTagLineHeight,
  tagBitmapRecipe,
  type RingRecipe,
  type TagMeasure,
} from "../../core/math/cameraStyleMath";
import type { PathElement } from "../../core/math/styleSupport";
import { srgbToWorking, type WorkingSpace } from "../color";

export interface BakedAsset {
  /** Premultiplied RGBA8, row 0 = top. */
  rgba: Uint8Array<ArrayBuffer>;
  width: number;
  height: number;
  /** Top-left of texel (0,0) in Y-down output px (asset space = baseRect placement). */
  origin: { x: number; y: number };
  /** Crop rect (Y-down output px) applied before the per-frame transform. */
  crop: Rect;
}

export interface BakedCameraAssets {
  mask: BakedAsset | null;
  stroke: BakedAsset | null;
  shadow: BakedAsset | null;
  ring: BakedAsset | null;
  tag: BakedAsset | null;
}

type Ctx2D = OffscreenCanvasRenderingContext2D;

function canvas2d(w: number, h: number): Ctx2D {
  const c = new OffscreenCanvas(Math.max(1, w), Math.max(1, h));
  const ctx = c.getContext("2d", { colorSpace: "srgb", willReadFrequently: true });
  if (!ctx) throw new Error("Canvas2D unavailable (camera assets)");
  return ctx;
}

function tracePath(ctx: Ctx2D, path: readonly PathElement[]): void {
  ctx.beginPath();
  for (const e of path) {
    const p = e.pts;
    switch (e.op) {
      case "move":
        ctx.moveTo(p[0].x, p[0].y);
        break;
      case "line":
        ctx.lineTo(p[0].x, p[0].y);
        break;
      case "quad":
        ctx.quadraticCurveTo(p[0].x, p[0].y, p[1].x, p[1].y);
        break;
      case "curve":
        ctx.bezierCurveTo(p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y);
        break;
      case "close":
        ctx.closePath();
        break;
    }
  }
}

/** CG Y-up bitmap convention on a Y-down canvas of `rows` rows. */
function flipY(ctx: Ctx2D, rows: number): void {
  ctx.setTransform(1, 0, 0, -1, 0, rows);
}

/** Alpha coverage (0…1) of `path` filled in a w×h Y-up bitmap. */
function coverage(w: number, h: number, path: readonly PathElement[]): Float32Array {
  const ctx = canvas2d(w, h);
  flipY(ctx, h);
  ctx.fillStyle = "#fff";
  tracePath(ctx, path);
  ctx.fill("nonzero");
  const img = ctx.getImageData(0, 0, w, h).data;
  const out = new Float32Array(w * h);
  for (let i = 0; i < out.length; i++) out[i] = img[i * 4 + 3] / 255;
  return out;
}

/** Separable Gaussian (CIGaussianBlur twin: radius = σ), clear outside, same size. */
export function gaussianBlur(src: Float32Array, w: number, h: number, sigma: number): Float32Array {
  if (!(sigma > 0)) return src.slice();
  const r = Math.max(1, Math.ceil(sigma * 3));
  const k = new Float32Array(2 * r + 1);
  let sum = 0;
  for (let i = -r; i <= r; i++) {
    const v = Math.exp((-0.5 * i * i) / (sigma * sigma));
    k[i + r] = v;
    sum += v;
  }
  for (let i = 0; i < k.length; i++) k[i] /= sum;
  const tmp = new Float32Array(w * h);
  const out = new Float32Array(w * h);
  for (let y = 0; y < h; y++) {
    const row = y * w;
    for (let x = 0; x < w; x++) {
      let acc = 0;
      const lo = Math.max(-r, -x);
      const hi = Math.min(r, w - 1 - x);
      for (let i = lo; i <= hi; i++) acc += k[i + r] * src[row + x + i];
      tmp[row + x] = acc;
    }
  }
  for (let y = 0; y < h; y++) {
    const lo = Math.max(-r, -y);
    const hi = Math.min(r, h - 1 - y);
    for (let x = 0; x < w; x++) {
      let acc = 0;
      for (let i = lo; i <= hi; i++) acc += k[i + r] * tmp[(y + i) * w + x];
      out[y * w + x] = acc;
    }
  }
  return out;
}

const q8 = (v: number) => Math.max(0, Math.min(255, Math.round(v * 255)));

/** Straight sRGB colour → premultiplied working-space RGBA8 × per-pixel alpha. */
function tinted(alpha: Float32Array, rgb: [number, number, number], space: WorkingSpace): Uint8Array<ArrayBuffer> {
  const [r, g, b] = srgbToWorking(rgb, space);
  const out = new Uint8Array(alpha.length * 4);
  for (let i = 0; i < alpha.length; i++) {
    const a = Math.max(0, Math.min(1, alpha[i]));
    out[i * 4] = q8(r * a);
    out[i * 4 + 1] = q8(g * a);
    out[i * 4 + 2] = q8(b * a);
    out[i * 4 + 3] = q8(a);
  }
  return out;
}

/** Canvas ImageData (straight sRGB) → premultiplied working-space RGBA8. */
function premultiplied(img: Uint8ClampedArray, space: WorkingSpace): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(img.length);
  for (let i = 0; i < img.length; i += 4) {
    const a = img[i + 3] / 255;
    if (a <= 0) continue;
    const [r, g, b] =
      space === "srgb" ? [img[i] / 255, img[i + 1] / 255, img[i + 2] / 255] : srgbToWorking([img[i] / 255, img[i + 1] / 255, img[i + 2] / 255], space);
    out[i] = q8(r * a);
    out[i + 1] = q8(g * a);
    out[i + 2] = q8(b * a);
    out[i + 3] = img[i + 3];
  }
  return out;
}

const yDownRect = (r: Rect, H: number): Rect => ({ x: r.x, y: H - r.y - r.height, width: r.width, height: r.height });

/** Placement of a CG bitmap (Y-up bottom-left at `extent` origin) in Y-down px. */
function placed(m: { extent: Rect; width: number; height: number }, H: number) {
  return { origin: { x: m.extent.x, y: H - m.extent.y - m.height }, crop: yDownRect(m.extent, H) };
}

/** cameraShapeMaskImage: black opaque base, white shape — grey level = coverage. */
function bakeMask(m: MaskBitmap, H: number): BakedAsset {
  const cov = coverage(m.width, m.height, m.path);
  const rgba = new Uint8Array(cov.length * 4);
  for (let i = 0; i < cov.length; i++) {
    const v = q8(cov[i]);
    rgba[i * 4] = v;
    rgba[i * 4 + 1] = v;
    rgba[i * 4 + 2] = v;
    rgba[i * 4 + 3] = 255;
  }
  return { rgba, width: m.width, height: m.height, ...placed(m, H) };
}

/** cameraShapeStrokeImage: clear base, the shape stroked (centred) with lineWidth + colour. */
function bakeStroke(s: StrokeBitmap, H: number, space: WorkingSpace): BakedAsset {
  const ctx = canvas2d(s.width, s.height);
  flipY(ctx, s.height);
  const c = s.color;
  ctx.strokeStyle = `rgba(${c.red * 255}, ${c.green * 255}, ${c.blue * 255}, ${c.alpha})`;
  ctx.lineWidth = s.lineWidth;
  ctx.lineJoin = "miter";
  ctx.miterLimit = 10;
  tracePath(ctx, s.path);
  ctx.stroke();
  const img = ctx.getImageData(0, 0, s.width, s.height).data;
  return { rgba: premultiplied(img, space), width: s.width, height: s.height, ...placed(s, H) };
}

/** cameraShapeShadowImage: shape × black α0.45, CIGaussianBlur(σ), cropped to the extent. */
function bakeShadow(mask: MaskBitmap, alpha: number, sigma: number, H: number): BakedAsset {
  const cov = coverage(mask.width, mask.height, mask.path);
  for (let i = 0; i < cov.length; i++) cov[i] *= alpha;
  const blurred = gaussianBlur(cov, mask.width, mask.height, sigma);
  const rgba = new Uint8Array(blurred.length * 4);
  for (let i = 0; i < blurred.length; i++) rgba[i * 4 + 3] = q8(blurred[i]);
  return { rgba, width: mask.width, height: mask.height, ...placed(mask, H) };
}

/**
 * CameraStyleMath.ringImage: fill the clip path with the ring colour, blur
 * (σ, clear outside), then keep only OUTSIDE the shape (even-odd clip of the
 * padded rect ∪ path) at global alpha. Placed at baseRect − pad (Y-up),
 * cropped to baseRect ± pad.
 */
function bakeRing(recipe: RingRecipe, origin: { x: number; y: number }, crop: Rect, H: number, space: WorkingSpace): BakedAsset {
  const { pxW, pxH } = recipe;
  const fill = coverage(pxW, pxH, recipe.path);
  const blurred = gaussianBlur(fill, pxW, pxH, recipe.sigma);
  // The clip: (0,0,padded) XOR path — the path lies inside, so outside = rect − path.
  const ctx = canvas2d(pxW, pxH);
  flipY(ctx, pxH);
  ctx.fillStyle = "#fff";
  ctx.beginPath();
  ctx.rect(0, 0, recipe.padded.width, recipe.padded.height);
  for (const e of recipe.path) {
    const p = e.pts;
    if (e.op === "move") ctx.moveTo(p[0].x, p[0].y);
    else if (e.op === "line") ctx.lineTo(p[0].x, p[0].y);
    else if (e.op === "quad") ctx.quadraticCurveTo(p[0].x, p[0].y, p[1].x, p[1].y);
    else if (e.op === "curve") ctx.bezierCurveTo(p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y);
    else ctx.closePath();
  }
  ctx.fill("evenodd");
  const clip = ctx.getImageData(0, 0, pxW, pxH).data;
  // The blurred pxW×pxH raster is drawn into (0,0,padded) points (scale 1).
  const sx = pxW / recipe.padded.width;
  const sy = pxH / recipe.padded.height;
  const alpha = new Float32Array(pxW * pxH);
  for (let y = 0; y < pxH; y++) {
    for (let x = 0; x < pxW; x++) {
      const fx = Math.min(pxW - 1, Math.max(0, (x + 0.5) * sx - 0.5));
      const fy = Math.min(pxH - 1, Math.max(0, (y + 0.5) * sy - 0.5));
      const x0 = Math.floor(fx);
      const y0 = Math.floor(fy);
      const x1 = Math.min(pxW - 1, x0 + 1);
      const y1 = Math.min(pxH - 1, y0 + 1);
      const tx = fx - x0;
      const ty = fy - y0;
      const b =
        (blurred[y0 * pxW + x0] * (1 - tx) + blurred[y0 * pxW + x1] * tx) * (1 - ty) +
        (blurred[y1 * pxW + x0] * (1 - tx) + blurred[y1 * pxW + x1] * tx) * ty;
      alpha[y * pxW + x] = b * recipe.alpha * (clip[(y * pxW + x) * 4 + 3] / 255);
    }
  }
  return {
    rgba: tinted(alpha, [ringColor.r, ringColor.g, ringColor.b], space),
    width: pxW,
    height: pxH,
    origin: { x: origin.x, y: H - origin.y - pxH },
    crop: yDownRect(crop, H),
  };
}

// ── Tag text (NSAttributedString in the tag font) ──────────────────────────

const SYSTEM_STACK = `system-ui, -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif`;

function tagFont(fontName: string | null, size: number): string {
  // System = SF Pro SEMIBOLD (NSFont.systemFont(ofSize:weight:.semibold)).
  if (!fontName) return `600 ${size}px ${SYSTEM_STACK}`;
  return `${size}px "${fontName.replace(/"/g, "")}", ${SYSTEM_STACK}`;
}

let measureCtx: Ctx2D | null = null;

/**
 * `NSAttributedString.size()` of a tag line. Width from the browser's font
 * (SF Pro on macOS Chrome/Safari); the SYSTEM font's height comes from the
 * calibrated macOS line-height table (core `systemTagLineHeight`), so the pill
 * HEIGHT matches the Mac exactly; named fonts use the font's ascent+descent.
 */
export const measureTag: TagMeasure = (text, fontName, fontSize) => {
  measureCtx ??= canvas2d(4, 4);
  measureCtx.font = tagFont(fontName, fontSize);
  const m = measureCtx.measureText(text);
  const height = fontName
    ? (m.fontBoundingBoxAscent ?? fontSize * 0.8) + (m.fontBoundingBoxDescent ?? fontSize * 0.2)
    : systemTagLineHeight(fontSize);
  return { width: m.width, height };
};

type TagSettings = Pick<
  ProjectSettings,
  "cameraTagText" | "cameraTagSubtext" | "cameraTagFontName" | "cameraTagBackgroundColor" | "cameraTagTextColor"
>;

/** CameraStyleMath.tagBitmap at scale 1, placed with its bottom-left at `tagRect.origin` (Y-up), uncropped. */
function bakeTag(s: TagSettings, bubbleWidth: number, tagRectYUp: Rect, H: number, space: WorkingSpace): BakedAsset | null {
  const r = tagBitmapRecipe(s, bubbleWidth, 1, measureTag);
  if (!r) return null;
  const ctx = canvas2d(r.pxW, r.pxH);
  // Pill: symmetric → draw through the Y-up flip like CG.
  flipY(ctx, r.pxH);
  const bg = r.background;
  ctx.fillStyle = `rgba(${bg.red * 255}, ${bg.green * 255}, ${bg.blue * 255}, ${bg.alpha})`;
  tracePath(ctx, r.pillPath);
  ctx.fill();
  // Text: Y-down (never draw glyphs flipped). A line box starts at its rect's
  // Y-up TOP (= Y-down pxH − maxY); baseline one ascent below; centred.
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.textAlign = "center";
  ctx.textBaseline = "alphabetic";
  const fontName = s.cameraTagFontName ?? null;
  const line = (text: string, size: number, rect: Rect, c: { red: number; green: number; blue: number; alpha: number }) => {
    ctx.font = tagFont(fontName, size);
    const m = ctx.measureText(text);
    const ascent = m.fontBoundingBoxAscent ?? size * 0.9668;
    const top = r.pxH - (rect.y + rect.height);
    ctx.fillStyle = `rgba(${c.red * 255}, ${c.green * 255}, ${c.blue * 255}, ${c.alpha})`;
    ctx.fillText(text, rect.x + rect.width / 2, top + ascent);
  };
  const trim = (v: string) => v.replace(/^[\p{Z}\t\n\v\f\r\u0085]+|[\p{Z}\t\n\v\f\r\u0085]+$/gu, "");
  line(trim(s.cameraTagText), r.layout.fontSize, r.mainRect, r.textColor);
  if (r.subRect) line(trim(s.cameraTagSubtext), r.layout.subFontSize, r.subRect, r.subTextColor);
  const img = ctx.getImageData(0, 0, r.pxW, r.pxH).data;
  const origin = { x: tagRectYUp.x, y: H - tagRectYUp.y - r.pxH };
  return {
    rgba: premultiplied(img, space),
    width: r.pxW,
    height: r.pxH,
    origin,
    crop: { x: origin.x, y: origin.y, width: r.pxW, height: r.pxH },
  };
}

/** Rasterises every static camera asset the core resolved (`exportCameraStatics().assets`). */
export function bakeCameraAssets(
  a: ExportCameraAssets,
  s: TagSettings,
  outputSize: Size,
  space: WorkingSpace,
): BakedCameraAssets {
  const H = outputSize.height;
  return {
    mask: a.mask ? bakeMask(a.mask, H) : null,
    stroke: a.stroke ? bakeStroke(a.stroke, H, space) : null,
    shadow: a.shadow ? bakeShadow(a.shadow.mask, a.shadow.alpha, a.shadow.sigma, H) : null,
    ring: a.ring ? bakeRing(a.ring.recipe, a.ring.origin, a.ring.crop, H, space) : null,
    tag: a.tag ? bakeTag(s, a.baseRect.width, a.tag.rect, H, space) : null,
  };
}
