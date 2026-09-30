/**
 * Port of Services/AnnotationRenderer.swift — every number the ONE shared
 * annotation renderer (Mac preview AND exporter) computes, as data:
 * `labelRect`, `backdropAlpha`, `trimmedStrokes` (Draw On), `boxEdgeIntersection`,
 * and the full draw RECIPE of `image` / `draw` / `drawBackdrop` / `draw(_:)`
 * / `drawText` / `drawArrow` / `drawCallout` / `drawDrawing` / `drawShape` /
 * `drawTap` / `handle` / `selectionRing` / `TextLine.draw` /
 * `SwiftUIShadow.apply`, emitted through the CGContext-shaped
 * `RecordingContext` (overlaySupport.ts) in the renderer's Y-DOWN canvas
 * space. Plus the exporter wrapper `VideoExporter.renderAnnotations`
 * (scale = outputWidth / 1920 · 2, videoRect Y-flip).
 *
 * Locked to Swift by the golden-vector units `annotationGeometry`,
 * `annotationTextMetrics`, `annotationDrawRecipe` (Swift side proves
 * oracle pixels == REAL AnnotationRenderer.image == replay(ops), byte for
 * byte) and `annotationTapRipple` / `oklabGradientStops` (helpers).
 *
 * # Text (CoreText — the web measures and draws it)
 *
 * `TextLine(a, scale)`: font = FontCatalog.font(named: a.fontName, size:
 * a.fontSize · scale, weight: a.fontWeight) — nil/"System"/unknown family →
 * the system face (SF Pro) at that weight (Regular 400, Medium 500, Semibold
 * 600, Bold 700, Heavy 800); a named family resolves to the member nearest
 * the weight (AppKit weight index Regular 5, Medium 6, Semibold 8, Bold 9,
 * Heavy 11; Bold/Heavy add the bold trait). String = `displayText`
 * (uppercase via full Unicode case mapping). Measurements the web must
 * reproduce (see `annotationTextMetrics`): `width`/`height` =
 * NSAttributedString.size() (one line, no wrapping; height = the font's
 * line height), `baselineFromTop` = round(font.ascender) (ties away).
 * The `text` op draws the line with its BASELINE at (`originX`,
 * `baselineY`) in the y-down canvas, glyphs upright, colour `color`.
 * `originX` is already pixel-snapped when `snapToPixels` (it used the CTM's
 * device scale: `round(x · s) / s`).
 *
 * # Effects application order (draw(_:)): translate(anchor + offsetY·scale)
 * → scale(phase.scale) → translate(−anchor) → setAlpha(opacity·phase.alpha)
 * → optional SwiftUI shadow (radius 4·scale, y 1·scale, black 0.35; CG blur
 * = radius · 2.2 · deviceScale) → ONE transparency layer per annotation (the
 * shadow is cast by the finished group). Backdrops (lightbox dims) are all
 * drawn first, even-odd with the rectangle/ellipse cut out.
 *
 * Shape/callout borders are INSET strokes (path inset by lw/2). Arrow: round
 * cap shaft, filled triangular head (size 5·lw, ±30°). Tap: dot + two
 * ripple rings + an Oklab radial glow (`gradient.kind: "oklab"`).
 */
import type { Annotation, CodableColor, CodablePoint, Point, Rect, Size } from "../model/types";
import { effectAnchor, effectPhase, settledPhase, displayText } from "./annotationEffectMath";
import {
  cgEllipsePath,
  continuousRoundedRectPath,
  deviceScale,
  RecordingContext,
  SWIFTUI_SHADOW_BLUR_FACTOR,
  tapRippleProgress,
  type DrawOp,
  type PathElements,
  type RGBA,
} from "./overlaySupport";
import { insetBy, maxX, maxY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { smax, smin, srounded } from "./swift";

/** Measured `TextLine` of an annotation label (see module doc). */
export interface AnnotationTextLine {
  width: number;
  height: number;
  baselineFromTop: number;
}

/** Measures `a`'s label at `scale` (font size a.fontSize · scale). */
export type AnnotationMeasure = (a: Annotation, scale: number) => AnnotationTextLine;

/** `AnnotationRenderer.Chrome` — editor-only decoration (never exported). */
export interface AnnotationChrome {
  isPlaying: boolean;
  selectedID: string | null;
  editingID?: string | null;
}

function isSelected(c: AnnotationChrome, a: Annotation): boolean {
  return c.selectedID != null && c.selectedID === a.id;
}
function showsHandles(c: AnnotationChrome): boolean {
  return !c.isPlaying;
}
function rendersSettled(c: AnnotationChrome | null): boolean {
  return c ? !c.isPlaying : false;
}

function colorRGBA(c: CodableColor): RGBA {
  return { r: c.red, g: c.green, b: c.blue, a: c.opacity };
}

/** macOS selection blue (chrome only). */
const ACCENT: RGBA = { r: 0, g: 0.478, b: 1, a: 1 };

// ── Exporter wrapper (VideoExporter.renderAnnotations) ───────────────────────

/** Annotation pt → export px: `outputSize.width / 1920 · 2`. */
export function exportAnnotationScale(outputWidth: number): number {
  return (outputWidth / 1920.0) * 2;
}

/** The exporter's CI (Y-up) video rect flipped into the renderer's Y-down
 * output space. */
export function exportVideoRectYDown(videoRectYUp: Rect, outputSize: Size): Rect {
  return {
    x: minX(videoRectYUp),
    y: outputSize.height - maxY(videoRectYUp),
    width: rectWidth(videoRectYUp),
    height: rectHeight(videoRectYUp),
  };
}

// ── Shared geometry ─────────────────────────────────────────────────────────

/** private `point(_:_:in:)` — normalized → canvas. */
export function annotationPoint(nx: number, ny: number, videoRect: Rect): Point {
  return { x: minX(videoRect) + nx * rectWidth(videoRect), y: minY(videoRect) + ny * rectHeight(videoRect) };
}

/** `AnnotationRenderer.labelRect(_:videoRect:scale:)` — text pill / callout box. */
export function labelRect(a: Annotation, videoRect: Rect, scale: number, line: AnnotationTextLine): Rect | null {
  if (!(a.type === "text" || a.type === "callout")) return null;
  const center = annotationPoint(a.x, a.y, videoRect);
  const hPad = (a.type === "text" ? 10 : 12) * scale;
  const vPad = (a.type === "text" ? 6 : 8) * scale;
  return {
    x: center.x - line.width / 2 - hPad,
    y: center.y - line.height / 2 - vPad,
    width: line.width + hPad * 2,
    height: line.height + vPad * 2,
  };
}

/** `AnnotationRenderer.backdropAlpha(annotations:at:settled:)` — the canvas-
 * level lightbox dim (strongest active backdrop × its build phase). */
export function backdropAlpha(annotations: readonly Annotation[], time: number, settled = false): number {
  let strongest = 0;
  for (const a of annotations) {
    if (!(time >= a.startTime && time <= a.endTime)) continue;
    const dim = smax(0, smin(0.95, a.backdropOpacity));
    if (!(dim > 0.001)) continue;
    const phase = settled ? 1 : smax(0, smin(1, effectPhase(a, time).alpha));
    strongest = smax(strongest, dim * phase);
  }
  return strongest;
}

/** `AnnotationRenderer.trimmedStrokes(_:progress:)` — Draw On pen position. */
export function trimmedStrokes(strokes: readonly CodablePoint[][], progress: number): CodablePoint[][] {
  const p = smin(1, smax(0, progress));
  if (p >= 1) return strokes.map((s) => s.slice());
  let total = 0;
  for (const s of strokes) total += smax(1, s.length);
  if (!(total > 0)) return [];
  let remaining = p * total;
  const out: CodablePoint[][] = [];
  for (const stroke of strokes) {
    const cost = smax(1, stroke.length);
    if (remaining <= 0) break;
    if (remaining >= cost) {
      out.push(stroke.slice());
      remaining -= cost;
      continue;
    }
    const exact = remaining;
    const whole = Math.trunc(exact);
    const partial = stroke.slice(0, smax(1, whole));
    const fraction = exact - whole;
    if (whole >= 1 && whole < stroke.length && fraction > 0) {
      const a = stroke[whole - 1];
      const b = stroke[whole];
      partial.push({ x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction });
    }
    out.push(partial);
    break;
  }
  return out;
}

/** `AnnotationRenderer.boxEdgeIntersection(from:toward:box:)` */
export function boxEdgeIntersection(from: Point, toward: Point, box: Rect): Point {
  const dx = toward.x - from.x;
  const dy = toward.y - from.y;
  if (!(Math.abs(dx) > 0.001 || Math.abs(dy) > 0.001)) return toward;
  let best = Number.POSITIVE_INFINITY;
  const check = (t: number, x: number, y: number) => {
    const inside =
      t > 0 &&
      t < best &&
      x >= minX(box) - 0.5 &&
      x <= maxX(box) + 0.5 &&
      y >= minY(box) - 0.5 &&
      y <= maxY(box) + 0.5;
    if (inside) best = t;
  };
  if (Math.abs(dx) > 0.001) {
    const t = (minX(box) - from.x) / dx;
    check(t, minX(box), from.y + t * dy);
    const t2 = (maxX(box) - from.x) / dx;
    check(t2, maxX(box), from.y + t2 * dy);
  }
  if (Math.abs(dy) > 0.001) {
    const t = (minY(box) - from.y) / dy;
    check(t, from.x + t * dx, minY(box));
    const t2 = (maxY(box) - from.y) / dy;
    check(t2, from.x + t2 * dx, maxY(box));
  }
  if (!(best < Number.POSITIVE_INFINITY)) return toward;
  return { x: from.x + best * dx, y: from.y + best * dy };
}

// ── Draw recipe ─────────────────────────────────────────────────────────────

export interface AnnotationImageRecipe {
  pixelWidth: number;
  pixelHeight: number;
  /** Starts with the raster base transform (scale(rasterScale) · flip). */
  ops: DrawOp[];
}

/** `AnnotationRenderer.image(size:annotations:currentTime:videoRect:scale:
 * chrome:rasterScale:videoCornerRadius:)` as a recipe (null = empty raster).
 * The exporter calls it with size = output size, rasterScale 1, chrome nil,
 * scale = exportAnnotationScale, videoRect = exportVideoRectYDown(...). */
export function annotationImageRecipe(
  size: Size,
  annotations: readonly Annotation[],
  currentTime: number,
  videoRect: Rect,
  scale: number,
  chrome: AnnotationChrome | null,
  rasterScale: number,
  videoCornerRadius: number,
  measure: AnnotationMeasure,
): AnnotationImageRecipe | null {
  const w = Math.trunc(srounded(size.width * rasterScale));
  const h = Math.trunc(srounded(size.height * rasterScale));
  if (!(w > 0 && h > 0)) return null;
  const ctx = new RecordingContext();
  ctx.scaleBy(rasterScale, rasterScale);
  ctx.translateBy(0, size.height);
  ctx.scaleBy(1, -1);
  drawAnnotations(ctx, annotations, currentTime, videoRect, scale, chrome, videoCornerRadius, measure);
  return { pixelWidth: w, pixelHeight: h, ops: ctx.ops };
}

/** `AnnotationRenderer.draw(in:annotations:...)` — into an ALREADY y-down
 * context: every active backdrop first, then every active annotation. */
export function drawAnnotations(
  ctx: RecordingContext,
  annotations: readonly Annotation[],
  currentTime: number,
  videoRect: Rect,
  scale: number,
  chrome: AnnotationChrome | null,
  videoCornerRadius: number,
  measure: AnnotationMeasure,
): void {
  for (const a of annotations) {
    if (!(currentTime >= a.startTime && currentTime <= a.endTime)) continue;
    drawBackdrop(ctx, a, currentTime, videoRect, scale, chrome, videoCornerRadius);
  }
  for (const a of annotations) {
    if (!(currentTime >= a.startTime && currentTime <= a.endTime)) continue;
    drawOne(ctx, a, currentTime, videoRect, scale, chrome, measure);
  }
}

function selectionRing(ctx: RecordingContext, path: PathElements, scale: number): void {
  ctx.saveGState();
  ctx.addPath(path);
  ctx.setStrokeColor(ACCENT);
  ctx.setLineWidth(1.5 * scale);
  ctx.strokePath();
  ctx.restoreGState();
}

function swiftUIShadow(ctx: RecordingContext, radius: number, dy: number, color: RGBA): void {
  ctx.setShadow(0, dy, radius * SWIFTUI_SHADOW_BLUR_FACTOR * deviceScale(ctx.ctm), color);
}

function drawBackdrop(
  ctx: RecordingContext,
  a: Annotation,
  currentTime: number,
  videoRect: Rect,
  scale: number,
  chrome: AnnotationChrome | null,
  videoCornerRadius: number,
): void {
  const dim = smax(0, smin(0.95, a.backdropOpacity));
  if (!(dim > 0.001)) return;
  const phase = rendersSettled(chrome) ? settledPhase() : effectPhase(a, currentTime);
  const alpha = dim * smax(0, smin(1, phase.alpha));
  if (!(alpha > 0.001)) return;

  ctx.saveGState();
  const cardRadius = smin(smax(0, videoCornerRadius), smin(rectWidth(videoRect), rectHeight(videoRect)) / 2);
  const path: PathElements = continuousRoundedRectPath(videoRect, cardRadius);
  if (a.type === "rectangle" || a.type === "ellipse") {
    const p1 = annotationPoint(smin(a.x, a.arrowEndX), smin(a.y, a.arrowEndY), videoRect);
    const p2 = annotationPoint(smax(a.x, a.arrowEndX), smax(a.y, a.arrowEndY), videoRect);
    const rect = { x: p1.x, y: p1.y, width: p2.x - p1.x, height: p2.y - p1.y };
    if (a.type === "ellipse") path.push(...cgEllipsePath(rect));
    else path.push(...continuousRoundedRectPath(rect, smax(0, a.cornerRadius) * scale));
  }
  // CGColor(gray: 0, alpha:) — black.
  ctx.setFillColor({ r: 0, g: 0, b: 0, a: alpha });
  ctx.addPath(path);
  ctx.fillPath(true);
  ctx.restoreGState();
}

function drawOne(
  ctx: RecordingContext,
  a: Annotation,
  currentTime: number,
  videoRect: Rect,
  scale: number,
  chrome: AnnotationChrome | null,
  measure: AnnotationMeasure,
): void {
  if (chrome != null && chrome.editingID != null && chrome.editingID === a.id) return;
  const phase = rendersSettled(chrome) ? settledPhase() : effectPhase(a, currentTime);
  const alpha = smax(0, smin(1, a.opacity)) * phase.alpha;
  if (!(alpha > 0.001)) return;

  ctx.saveGState();
  const anchor = effectAnchor(a);
  const ax = minX(videoRect) + anchor.x * rectWidth(videoRect);
  const ay = minY(videoRect) + anchor.y * rectHeight(videoRect);
  ctx.translateBy(ax, ay + phase.offsetY * scale);
  ctx.scaleBy(phase.scale, phase.scale);
  ctx.translateBy(-ax, -ay);
  ctx.setAlpha(alpha);
  if (a.showShadow) swiftUIShadow(ctx, 4 * scale, 1 * scale, { r: 0, g: 0, b: 0, a: 0.35 });
  const unscaled = Math.abs(phase.scale - 1) < 1e-9;
  ctx.beginTransparencyLayer();
  switch (a.type) {
    case "text":
      drawText(ctx, a, videoRect, scale, chrome, unscaled, measure);
      break;
    case "arrow":
      drawArrow(ctx, a, videoRect, scale, chrome);
      break;
    case "callout":
      drawCallout(ctx, a, videoRect, scale, chrome, unscaled, measure);
      break;
    case "drawing":
      drawDrawing(ctx, a, videoRect, scale, phase.strokeProgress);
      break;
    case "rectangle":
    case "ellipse":
      drawShape(ctx, a, videoRect, scale, chrome);
      break;
    case "tap":
      drawTap(ctx, a, videoRect, scale, currentTime, chrome);
      break;
  }
  ctx.endTransparencyLayer();
  ctx.restoreGState();
}

/** `TextLine.draw(in:center:color:snapToPixels:)` as a `text` op. */
function drawLine(
  ctx: RecordingContext,
  a: Annotation,
  line: AnnotationTextLine,
  scale: number,
  center: Point,
  color: RGBA,
  snapToPixels: boolean,
): void {
  const text = displayText(a);
  if (text.length === 0) return;
  const baselineY = center.y - line.height / 2 + line.baselineFromTop;
  let originX = center.x - line.width / 2;
  if (snapToPixels) {
    const s = deviceScale(ctx.ctm);
    if (s > 0) originX = srounded(originX * s) / s;
  }
  ctx.record({
    op: "text",
    text,
    fontName: a.fontName ?? null,
    fontSize: a.fontSize * scale,
    weight: a.fontWeight,
    color,
    originX,
    baselineY,
    width: line.width,
    height: line.height,
    baselineFromTop: line.baselineFromTop,
    center,
    snapToPixels,
  });
}

function drawText(
  ctx: RecordingContext,
  a: Annotation,
  videoRect: Rect,
  scale: number,
  chrome: AnnotationChrome | null,
  unscaled: boolean,
  measure: AnnotationMeasure,
): void {
  const center = annotationPoint(a.x, a.y, videoRect);
  const line = measure(a, scale);
  const pill = labelRect(a, videoRect, scale, line) ?? { x: center.x, y: center.y, width: 0, height: 0 };
  const radius = smax(0, a.cornerRadius) * scale;
  if (a.showBackground) {
    ctx.addPath(continuousRoundedRectPath(pill, radius));
    ctx.setFillColor(colorRGBA(a.backgroundColor));
    ctx.fillPath();
  }
  drawLine(ctx, a, line, scale, center, colorRGBA(a.color), unscaled);
  if (chrome && showsHandles(chrome) && isSelected(chrome, a)) {
    const outset = 3 * scale;
    selectionRing(ctx, continuousRoundedRectPath(insetBy(pill, -outset, -outset), radius + outset), scale);
  }
}

function drawArrow(ctx: RecordingContext, a: Annotation, videoRect: Rect, scale: number, chrome: AnnotationChrome | null): void {
  const tail = annotationPoint(a.x, a.y, videoRect);
  const head = annotationPoint(a.arrowEndX, a.arrowEndY, videoRect);
  const color = colorRGBA(a.color);
  const lineWidth = a.lineWidth * scale;
  ctx.setStrokeColor(color);
  ctx.setFillColor(color);
  ctx.setLineWidth(lineWidth);
  ctx.setLineCap("round");
  ctx.move(tail);
  ctx.addLine(head);
  ctx.strokePath();

  const angle = Math.atan2(head.y - tail.y, head.x - tail.x);
  const headSize = lineWidth * 5;
  ctx.move(head);
  ctx.addLine({
    x: head.x - headSize * Math.cos(angle - Math.PI / 6),
    y: head.y - headSize * Math.sin(angle - Math.PI / 6),
  });
  ctx.addLine({
    x: head.x - headSize * Math.cos(angle + Math.PI / 6),
    y: head.y - headSize * Math.sin(angle + Math.PI / 6),
  });
  ctx.closePath();
  ctx.fillPath();

  if (chrome && showsHandles(chrome)) {
    const alpha = isSelected(chrome, a) ? 1 : 0.55;
    handle(ctx, tail, 10 * scale, alpha);
    handle(ctx, head, 10 * scale, alpha);
  }
}

function drawCallout(
  ctx: RecordingContext,
  a: Annotation,
  videoRect: Rect,
  scale: number,
  chrome: AnnotationChrome | null,
  unscaled: boolean,
  measure: AnnotationMeasure,
): void {
  const center = annotationPoint(a.x, a.y, videoRect);
  const tip = annotationPoint(a.arrowEndX, a.arrowEndY, videoRect);
  const color = colorRGBA(a.color);
  const line = measure(a, scale);
  const box = labelRect(a, videoRect, scale, line) ?? { x: center.x, y: center.y, width: 0, height: 0 };
  const radius = smax(0, a.cornerRadius) * scale;
  const stroke = 1.5 * scale;

  // Leader line, stopping at the box edge — drawn UNDER the box.
  const end = boxEdgeIntersection(tip, center, box);
  ctx.setStrokeColor(color);
  ctx.setLineWidth(stroke);
  ctx.setLineCap("butt");
  ctx.move(tip);
  ctx.addLine(end);
  ctx.strokePath();

  const dot = 7 * scale;
  ctx.setFillColor(color);
  ctx.fillEllipse({ x: tip.x - dot / 2, y: tip.y - dot / 2, width: dot, height: dot });

  ctx.addPath(continuousRoundedRectPath(box, radius));
  ctx.setFillColor(colorRGBA(a.backgroundColor));
  ctx.fillPath();
  ctx.addPath(continuousRoundedRectPath(insetBy(box, stroke / 2, stroke / 2), smax(0, radius - stroke / 2)));
  ctx.setStrokeColor(color);
  ctx.setLineWidth(stroke);
  ctx.strokePath();
  drawLine(ctx, a, line, scale, center, color, unscaled);

  if (chrome && showsHandles(chrome) && isSelected(chrome, a)) {
    const outset = 3 * scale;
    selectionRing(ctx, continuousRoundedRectPath(insetBy(box, -outset, -outset), radius + outset), scale);
  }
  if (chrome && showsHandles(chrome)) handle(ctx, tip, 10 * scale, isSelected(chrome, a) ? 1 : 0.55);
}

function drawDrawing(ctx: RecordingContext, a: Annotation, videoRect: Rect, scale: number, progress = 1): void {
  if (a.drawingStrokes.length === 0) return;
  const color = colorRGBA(a.color);
  const lineWidth = a.lineWidth * scale;
  ctx.setStrokeColor(color);
  ctx.setFillColor(color);
  ctx.setLineWidth(lineWidth);
  ctx.setLineCap("round");
  ctx.setLineJoin("round");
  for (const stroke of trimmedStrokes(a.drawingStrokes, progress)) {
    if (stroke.length === 0) continue;
    if (stroke.length === 1) {
      // A single-point stroke: an ellipse of radius lw/2 STROKED at lw.
      const p = annotationPoint(stroke[0].x, stroke[0].y, videoRect);
      const r = lineWidth / 2;
      ctx.addEllipse({ x: p.x - r, y: p.y - r, width: r * 2, height: r * 2 });
      ctx.strokePath();
    } else {
      ctx.beginPath();
      ctx.move(annotationPoint(stroke[0].x, stroke[0].y, videoRect));
      for (let k = 1; k < stroke.length; k++) ctx.addLine(annotationPoint(stroke[k].x, stroke[k].y, videoRect));
      ctx.strokePath();
    }
  }
}

function drawShape(ctx: RecordingContext, a: Annotation, videoRect: Rect, scale: number, chrome: AnnotationChrome | null): void {
  const p1 = annotationPoint(smin(a.x, a.arrowEndX), smin(a.y, a.arrowEndY), videoRect);
  const p2 = annotationPoint(smax(a.x, a.arrowEndX), smax(a.y, a.arrowEndY), videoRect);
  const rect = { x: p1.x, y: p1.y, width: p2.x - p1.x, height: p2.y - p1.y };
  const isEllipse = a.type === "ellipse";
  const radius = smax(0, a.cornerRadius) * scale;
  const lw = a.lineWidth * scale;
  const path = (r: Rect, cornerRadius: number) => (isEllipse ? cgEllipsePath(r) : continuousRoundedRectPath(r, cornerRadius));

  if (a.showBackground) {
    ctx.addPath(path(rect, radius));
    ctx.setFillColor(colorRGBA(a.backgroundColor));
    ctx.fillPath();
  }
  if (lw > 0) {
    // `.strokeBorder` — inside the shape.
    ctx.addPath(path(insetBy(rect, lw / 2, lw / 2), smax(0, radius - lw / 2)));
    ctx.setStrokeColor(colorRGBA(a.color));
    ctx.setLineWidth(lw);
    ctx.strokePath();
  }
  if (!(chrome && showsHandles(chrome))) return;
  if (isSelected(chrome, a)) {
    const outset = 3 * scale;
    selectionRing(ctx, path(insetBy(rect, -outset, -outset), radius + outset), scale);
  }
  const alpha = isSelected(chrome, a) ? 1 : 0.55;
  const corners: Array<[number, number]> = [
    [a.x, a.y],
    [a.arrowEndX, a.y],
    [a.x, a.arrowEndY],
    [a.arrowEndX, a.arrowEndY],
  ];
  for (const [nx, ny] of corners) handle(ctx, annotationPoint(nx, ny, videoRect), 10 * scale, alpha);
}

function drawTap(
  ctx: RecordingContext,
  a: Annotation,
  videoRect: Rect,
  scale: number,
  currentTime: number,
  chrome: AnnotationChrome | null,
): void {
  const center = annotationPoint(a.x, a.y, videoRect);
  const size = smax(20, a.fontSize) * scale;
  const base = colorRGBA(a.color);
  const tinted = (m: number): RGBA => ({ r: base.r, g: base.g, b: base.b, a: base.a * m });

  // Persistent touch point.
  const dot = size * 0.22;
  ctx.setFillColor(tinted(0.4));
  ctx.fillEllipse({ x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot });

  const progress = tapRippleProgress(currentTime - a.startTime);
  if (progress !== null) {
    const outerScale = 0.2 + progress * 0.8;
    const outerOpacity = 1.0 - progress;
    const outerD = size * outerScale;
    ctx.setStrokeColor(tinted(outerOpacity * 0.7));
    ctx.setLineWidth(2 * scale);
    ctx.strokeEllipse({ x: center.x - outerD / 2, y: center.y - outerD / 2, width: outerD, height: outerD });

    const innerProgress = smax(0, progress - 0.1) / 0.9;
    const innerScale = 0.15 + innerProgress * 0.5;
    const innerOpacity = smax(0, 1.0 - innerProgress * 1.5);
    const innerD = size * 0.6 * innerScale;
    ctx.setStrokeColor(tinted(innerOpacity * 0.5));
    ctx.setLineWidth(1.5 * scale);
    ctx.strokeEllipse({ x: center.x - innerD / 2, y: center.y - innerD / 2, width: innerD, height: innerD });

    // Soft radial glow (Oklab ramp, only alpha travels).
    const glow = { x: center.x - outerD / 2, y: center.y - outerD / 2, width: outerD, height: outerD };
    if (outerD > 0) {
      const from = { r: base.r, g: base.g, b: base.b, a: base.a * outerOpacity * 0.12 };
      const to = { r: base.r, g: base.g, b: base.b, a: 0 };
      ctx.saveGState();
      ctx.addEllipse(glow);
      ctx.clip();
      ctx.drawRadialGradient({ kind: "oklab", from, to }, center, 0, center, outerD / 2, false, false);
      ctx.restoreGState();
    }
  }

  if (chrome && showsHandles(chrome)) {
    const lw = 1 * scale;
    const ring = insetBy({ x: center.x - size / 2, y: center.y - size / 2, width: size, height: size }, lw / 2, lw / 2);
    ctx.saveGState();
    ctx.setStrokeColor({ r: 1, g: 1, b: 1, a: isSelected(chrome, a) ? 0.8 : 0.3 });
    ctx.setLineWidth(lw);
    ctx.setLineDash(0, [3 * scale, 3 * scale]);
    ctx.strokeEllipse(ring);
    ctx.restoreGState();
  }
}

/** Keynote-style grab handle (chrome). Raw CG shadow: offset (0, 1) base
 * space, blur 3 device px, black 0.35. */
function handle(ctx: RecordingContext, p: Point, diameter: number, alpha = 1): void {
  const rect = { x: p.x - diameter / 2, y: p.y - diameter / 2, width: diameter, height: diameter };
  ctx.saveGState();
  ctx.setAlpha(alpha);
  ctx.setShadow(0, 1, 3, { r: 0, g: 0, b: 0, a: 0.35 });
  ctx.setFillColor({ r: 1, g: 1, b: 1, a: 1 });
  ctx.fillEllipse(rect);
  ctx.setShadow(0, 0, 0, null);
  ctx.setStrokeColor({ r: 0, g: 0, b: 0, a: 0.2 });
  ctx.setLineWidth(1);
  ctx.strokeEllipse(insetBy(rect, 0.5, 0.5));
  ctx.restoreGState();
}
