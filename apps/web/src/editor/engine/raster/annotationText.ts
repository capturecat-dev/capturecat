/**
 * Annotation text on the web: `AnnotationRenderer.TextLine` measurement
 * (via raster/fontCatalog) and the recorded `text` op drawn so every glyph
 * lands on the pixel CoreText puts it on in the Mac exporter's CG raster.
 */
import { displayText } from "../../core/math/annotationEffectMath";
import type { AnnotationMeasure } from "../../core/math/annotationGeometry";
import type { RGBA } from "../../core/math/overlaySupport";
import type { SubtitleWeight } from "../../core/model/enums";
import { cssColor, EMPTY_BOX, type Box, type Ctx2D } from "./cgReplay";
import { canvasFont, measureLine, resolveFace, type FaceSpec } from "./fontCatalog";

/** `TextLine(a, scale:)` on the web (raster/fontCatalog). */
export const measureAnnotation: AnnotationMeasure = (a, scale) => {
  return measureLine(displayText(a), resolveFace(a.fontName, a.fontWeight), a.fontSize * scale);
};

/** Draws one recorded `text` op (TextLine.draw) — baseline at (originX, baselineY), upright. */
export function drawTextOp(ctx: Ctx2D, op: Record<string, unknown>): Box {
  const text = String(op.text ?? "");
  const size = Number(op.fontSize);
  if (!text || !(size > 0)) return EMPTY_BOX;
  const face = resolveFace((op.fontName as string | null) ?? null, op.weight as SubtitleWeight);
  const x = Number(op.originX);
  const y = Number(op.baselineY);
  const w = Number(op.width) || size * text.length;
  const h = Number(op.height) || size * 1.3;
  const b = Number(op.baselineFromTop) || size;
  // Generous: overhanging glyphs (italics, swashes, emoji) reach past the advance box.
  const box: Box = { x0: x - size, y0: y - b - size * 0.5, x1: x + w + size, y1: y - b + h + size * 0.5 };
  drawGlyphRun(ctx, text, face, size, x, y, box, cssColor(op.color as RGBA));
  return box;
}

/** Keeps a snapping bias off exact ties (float noise must not flip a rounding). */
const TIE = 1 / 256;

/**
 * CoreText's glyph-origin quantization in a CG bitmap (the Mac exporter's
 * AnnotationRenderer raster), probed with a sweep of fractional origins:
 * horizontally a glyph origin snaps DOWN (floor, device px) to a grid of
 * n = min(5, ⌊100 / (3 · deviceSize)⌋ + 1) phases per pixel (5 phases below
 * 8.33 px, 4 below 11.1, 3 below 16.7, 2 below 33.3, whole pixels above);
 * vertically to n_v = min(5, ⌊25 / (3 · deviceSize)⌋ + 1) phases, floor in
 * CG's Y-UP space = CEIL in the Y-down raster. `deviceSize` = point size ×
 * CTM scale (a Pop / Scale build effect changes it).
 */
export function cgGlyphPhases(deviceSize: number): { h: number; v: number } {
  const s = Math.max(1e-6, deviceSize);
  return { h: Math.min(5, Math.floor(100 / (3 * s)) + 1), v: Math.min(5, Math.floor(25 / (3 * s)) + 1) };
}

let glyphScratch: OffscreenCanvas | null = null;

/**
 * Draws one glyph run so every glyph lands where CoreText puts it. Chrome's
 * canvas snaps each glyph origin to the NEAREST device pixel; CG floors to
 * 1/n px (see `cgGlyphPhases`). n = 1: the run is biased (−½, +½) device px,
 * which turns Chrome's rounding into CG's floor / ceil exactly. n > 1: the run
 * is drawn at n× in device space (so Chrome's snapping grid IS CG's 1/n
 * grid, again biased to floor) and box-downsampled back — measured against
 * real CoreText rasters this halves the per-glyph error (layout advances
 * already agree to < 0.1 px, see fontCatalog). Non axis-aligned CTMs (never
 * produced by the annotation recipes) fall back to a plain `fillText`.
 */
function drawGlyphRun(ctx: Ctx2D, text: string, face: FaceSpec, size: number, x: number, y: number, userBox: Box, color: string): void {
  const font = canvasFont(face, size);
  const m = ctx.getTransform();
  const axisAligned = Math.abs(m.b) < 1e-9 && Math.abs(m.c) < 1e-9 && m.a > 0 && Math.abs(m.a - m.d) < 1e-9;
  const prep = (c: Ctx2D, f: string) => {
    c.font = f;
    c.fontKerning = "normal"; // CoreText kerns across spaces; Chrome's "auto" does not
    c.textAlign = "left";
    c.textBaseline = "alphabetic";
    c.direction = "ltr";
    c.fillStyle = color;
  };
  if (!axisAligned) {
    prep(ctx, font);
    ctx.fillText(text, x, y);
    return;
  }
  const s = m.a;
  const devSize = size * s;
  const ph = cgGlyphPhases(devSize);
  const n = ph.h;
  if (n === 1) {
    prep(ctx, font);
    ctx.fillText(text, x + (-0.5 + TIE) / s, y + (0.5 - TIE) / s);
    return;
  }
  // Device-space box, whole pixels.
  const bx0 = Math.floor(userBox.x0 * s + m.e);
  const by0 = Math.floor(userBox.y0 * s + m.f);
  const bw = Math.ceil(userBox.x1 * s + m.e) - bx0;
  const bh = Math.ceil(userBox.y1 * s + m.f) - by0;
  if (!(bw > 0 && bh > 0) || bw * bh * n * n > 32e6) {
    prep(ctx, font);
    ctx.fillText(text, x + (-0.5 + TIE) / s, y + (0.5 - TIE) / s);
    return;
  }
  const W = bw * n;
  const H = bh * n;
  if (!glyphScratch) glyphScratch = new OffscreenCanvas(W, H);
  if (glyphScratch.width < W || glyphScratch.height < H) {
    glyphScratch.width = Math.max(glyphScratch.width, W);
    glyphScratch.height = Math.max(glyphScratch.height, H);
  }
  const t = glyphScratch.getContext("2d") as Ctx2D;
  t.setTransform(1, 0, 0, 1, 0, 0);
  t.clearRect(0, 0, W, H);
  t.setTransform(n, 0, 0, n, -bx0 * n, -by0 * n);
  // The run in device px: font at deviceSize, origin floored onto CG's grids.
  prep(t, canvasFont(face, devSize));
  const devX = x * s + m.e;
  const devY = y * s + m.f;
  const yq = Math.round((Math.ceil(devY * ph.v - 1e-9) / ph.v) * n) / n;
  t.fillText(text, devX + (-0.5 + TIE) / n, yq);
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(glyphScratch, 0, 0, W, H, bx0, by0, bw, bh);
  ctx.restore();
}
