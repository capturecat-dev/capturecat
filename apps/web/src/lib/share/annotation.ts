/**
 * On-frame comment annotations for the public share page: the v1 model, the
 * geometry that maps it onto a player, its canonical serialization, and the
 * ONE canvas renderer that both the composer and the viewer overlay call —
 * so what a commenter draws is pixel-for-pixel what everyone else sees.
 *
 * Every coordinate is normalized 0–1 to the VIDEO FRAME (the picture inside
 * the object-fit: contain box, not the box), so a drawing made on a phone
 * lands on the same spot on a 5K display. Stroke widths and font sizes are
 * fractions of the frame too — nothing here is in CSS pixels until render.
 *
 * The API (apps/api/src/lib/comments.ts) re-validates everything; the caps
 * here mirror its limits so the composer never builds what it would refuse.
 */

export type Point = [number, number];
export type ShapeSize = 1 | 2 | 3;
export type ShapeKind = "pen" | "highlight" | "arrow" | "rect" | "ellipse" | "text";

export type StrokeShape = { kind: "pen" | "highlight"; color: string; size: ShapeSize; points: Point[] };
export type BoxShape = { kind: "arrow" | "rect" | "ellipse"; color: string; size: ShapeSize; from: Point; to: Point };
export type TextShape = { kind: "text"; color: string; size: ShapeSize; at: Point; text: string };
export type AnnotationShape = StrokeShape | BoxShape | TextShape;

export interface CommentAnnotation {
  v: 1;
  shapes: AnnotationShape[];
}

export const ANNOTATION_LIMITS = {
  maxShapes: 100,
  maxTotalPoints: 5000,
  maxPointsPerStroke: 2000,
  maxTextLength: 140,
  maxBytes: 32 * 1024,
} as const;

/** A rectangle in CSS pixels, relative to the overlay box. */
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

const COLOR_RE = /^#[0-9a-f]{6}$/i;

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

/**
 * Where the picture sits inside an object-fit: contain box. Without the
 * media's intrinsic size (metadata not loaded, or the video failed) the box
 * itself is the frame — the share player's box is already 16:9.
 */
export function containRect(boxW: number, boxH: number, mediaW?: number, mediaH?: number): Rect {
  if (!mediaW || !mediaH || boxW <= 0 || boxH <= 0) return { x: 0, y: 0, w: Math.max(0, boxW), h: Math.max(0, boxH) };
  const scale = Math.min(boxW / mediaW, boxH / mediaH);
  const w = mediaW * scale;
  const h = mediaH * scale;
  return { x: (boxW - w) / 2, y: (boxH - h) / 2, w, h };
}

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));

/** 4 decimals — 1/10 000 of the frame, the precision the API stores. */
export function roundCoord(v: number): number {
  return Math.round(clamp01(v) * 10_000) / 10_000;
}

/** A point in box pixels → normalized frame coordinates (clamped to the frame). */
export function toFrame(px: number, py: number, rect: Rect): Point {
  if (rect.w <= 0 || rect.h <= 0) return [0, 0];
  return [clamp01((px - rect.x) / rect.w), clamp01((py - rect.y) / rect.h)];
}

/** Normalized frame coordinates → box pixels. */
export function toBox(p: Point, rect: Rect): [number, number] {
  return [rect.x + p[0] * rect.w, rect.y + p[1] * rect.h];
}

/** The length every size is a fraction of: the frame's shorter side, so a
 *  vertical video gets the same visual weight as a landscape one. */
export function frameUnit(rect: Rect): number {
  return Math.max(0, Math.min(rect.w, rect.h));
}

const STROKE_FRACTION: Record<ShapeSize, number> = { 1: 0.0055, 2: 0.0095, 3: 0.016 };
const FONT_FRACTION: Record<ShapeSize, number> = { 1: 0.036, 2: 0.05, 3: 0.07 };
/** Highlighter: a wide translucent marker. */
const HIGHLIGHT_WIDTH = 3.4;
const HIGHLIGHT_ALPHA = 0.42;

export function strokeWidth(kind: ShapeKind, size: ShapeSize, rect: Rect): number {
  const base = STROKE_FRACTION[size] * frameUnit(rect);
  return kind === "highlight" ? base * HIGHLIGHT_WIDTH : base;
}

export function fontSize(size: ShapeSize, rect: Rect): number {
  return FONT_FRACTION[size] * frameUnit(rect);
}

/** Font stack for labels — the site's own, so the composer's text input and
 *  the canvas agree on the same machine. */
export const LABEL_FONT_FAMILY = '"SF Pro Text", Inter, system-ui, -apple-system, "Segoe UI", sans-serif';

function dist(a: Point, b: Point): number {
  return Math.hypot(a[0] - b[0], a[1] - b[1]);
}

// ---------------------------------------------------------------------------
// Stroke simplification
// ---------------------------------------------------------------------------

/** Perpendicular distance of p from segment a–b. */
function segmentDistance(p: Point, a: Point, b: Point): number {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  if (len2 === 0) return dist(p, a);
  const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2));
  return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

/**
 * Ramer–Douglas–Peucker, iterative. `epsilon` is in normalized frame units
 * (0.0007 ≈ half a pixel on a 720p frame), so a freehand stroke loses
 * hundreds of redundant samples without visibly changing shape.
 */
export function simplifyStroke(points: Point[], epsilon = 0.0007): Point[] {
  if (points.length <= 2) return points.slice();
  const keep = new Uint8Array(points.length);
  keep[0] = 1;
  keep[points.length - 1] = 1;
  const stack: Array<[number, number]> = [[0, points.length - 1]];
  while (stack.length > 0) {
    const [start, end] = stack.pop()!;
    let maxD = -1;
    let index = -1;
    for (let i = start + 1; i < end; i++) {
      const d = segmentDistance(points[i], points[start], points[end]);
      if (d > maxD) {
        maxD = d;
        index = i;
      }
    }
    if (index !== -1 && maxD > epsilon) {
      keep[index] = 1;
      stack.push([start, index], [index, end]);
    }
  }
  return points.filter((_, i) => keep[i] === 1);
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/** Label text as the API stores it: controls stripped, whitespace collapsed. */
export function cleanLabel(raw: string): string {
  // eslint-disable-next-line no-control-regex
  return raw.replace(/[\u0000-\u001F\u007F-\u009F‪-‮⁦-⁩]/g, " ").replace(/\s+/g, " ").trim();
}

/** Shorter than this (normalized) and an arrow/box is an accidental click. */
const MIN_BOX_SPAN = 0.004;

function roundPoint(p: Point): Point {
  return [roundCoord(p[0]), roundCoord(p[1])];
}

/** One shape in canonical form, or null when it has nothing to draw. */
export function canonicalShape(shape: AnnotationShape): AnnotationShape | null {
  const color = COLOR_RE.test(shape.color) ? shape.color.toLowerCase() : "#ffffff";
  const size: ShapeSize = shape.size === 1 || shape.size === 3 ? shape.size : 2;
  switch (shape.kind) {
    case "pen":
    case "highlight": {
      let points = simplifyStroke(shape.points.map(roundPoint));
      // Over the per-stroke cap: simplify harder until it fits.
      let epsilon = 0.0015;
      while (points.length > ANNOTATION_LIMITS.maxPointsPerStroke && epsilon < 0.05) {
        points = simplifyStroke(points, epsilon);
        epsilon *= 2;
      }
      // Rounding can merge neighbours; drop exact repeats.
      points = points.filter((p, i) => i === 0 || p[0] !== points[i - 1][0] || p[1] !== points[i - 1][1]);
      if (points.length === 0) return null;
      return { kind: shape.kind, color, size, points: points.slice(0, ANNOTATION_LIMITS.maxPointsPerStroke) };
    }
    case "arrow":
    case "rect":
    case "ellipse": {
      const from = roundPoint(shape.from);
      const to = roundPoint(shape.to);
      if (shape.kind === "arrow" ? dist(from, to) < MIN_BOX_SPAN : Math.abs(from[0] - to[0]) < MIN_BOX_SPAN || Math.abs(from[1] - to[1]) < MIN_BOX_SPAN) {
        return null;
      }
      return { kind: shape.kind, color, size, from, to };
    }
    case "text": {
      const text = [...cleanLabel(shape.text)].slice(0, ANNOTATION_LIMITS.maxTextLength).join("");
      if (!text) return null;
      return { kind: "text", color, size, at: roundPoint(shape.at), text };
    }
  }
}

function pointCount(shape: AnnotationShape): number {
  if (shape.kind === "pen" || shape.kind === "highlight") return shape.points.length;
  return shape.kind === "text" ? 1 : 2;
}

export interface SerializedAnnotation {
  /** null = nothing worth sending. */
  annotation: CommentAnnotation | null;
  json: string | null;
  bytes: number;
  /** True when the drawing exceeds a cap even after simplification — the
   *  composer refuses to post rather than letting the API 400. */
  tooLarge: boolean;
}

/** Shapes → the exact payload the API accepts (and stores). */
export function serializeAnnotation(shapes: AnnotationShape[]): SerializedAnnotation {
  const clean = shapes.map(canonicalShape).filter((s): s is AnnotationShape => s !== null);
  if (clean.length === 0) return { annotation: null, json: null, bytes: 0, tooLarge: false };
  const annotation: CommentAnnotation = { v: 1, shapes: clean };
  const json = JSON.stringify(annotation);
  const bytes = new TextEncoder().encode(json).length;
  const totalPoints = clean.reduce((n, s) => n + pointCount(s), 0);
  const tooLarge =
    clean.length > ANNOTATION_LIMITS.maxShapes ||
    totalPoints > ANNOTATION_LIMITS.maxTotalPoints ||
    bytes > ANNOTATION_LIMITS.maxBytes;
  return { annotation, json, bytes, tooLarge };
}

function readPoint(raw: unknown): Point | null {
  if (!Array.isArray(raw) || raw.length !== 2) return null;
  const [x, y] = raw;
  return typeof x === "number" && typeof y === "number" && Number.isFinite(x) && Number.isFinite(y)
    ? [clamp01(x), clamp01(y)]
    : null;
}

/**
 * The API's annotation JSON → a model the renderer can trust. The server
 * already validated it; this is the second fence, so a malformed payload is
 * dropped (shape by shape) instead of throwing inside a canvas draw.
 */
export function readAnnotation(raw: unknown): CommentAnnotation | null {
  if (!raw || typeof raw !== "object") return null;
  const { v, shapes } = raw as { v?: unknown; shapes?: unknown };
  if (v !== 1 || !Array.isArray(shapes)) return null;
  const out: AnnotationShape[] = [];
  for (const s of shapes.slice(0, ANNOTATION_LIMITS.maxShapes)) {
    if (!s || typeof s !== "object") continue;
    const shape = s as Record<string, unknown>;
    const color = typeof shape.color === "string" && COLOR_RE.test(shape.color) ? shape.color : null;
    const size = shape.size === 1 || shape.size === 2 || shape.size === 3 ? shape.size : null;
    if (!color || !size) continue;
    if ((shape.kind === "pen" || shape.kind === "highlight") && Array.isArray(shape.points)) {
      const points = shape.points.map(readPoint).filter((p): p is Point => p !== null);
      if (points.length > 0) out.push({ kind: shape.kind, color, size, points });
    } else if (shape.kind === "arrow" || shape.kind === "rect" || shape.kind === "ellipse") {
      const from = readPoint(shape.from);
      const to = readPoint(shape.to);
      if (from && to) out.push({ kind: shape.kind, color, size, from, to });
    } else if (shape.kind === "text" && typeof shape.text === "string") {
      const at = readPoint(shape.at);
      const text = cleanLabel(shape.text).slice(0, ANNOTATION_LIMITS.maxTextLength * 2);
      if (at && text) out.push({ kind: "text", color, size, at, text });
    }
  }
  return out.length > 0 ? { v: 1, shapes: out } : null;
}

// ---------------------------------------------------------------------------
// Rendering — the single renderer for composer, overlay and thumbnails
// ---------------------------------------------------------------------------

/** Perceived luminance 0–1 of "#rrggbb". */
export function luminance(hex: string): number {
  const n = parseInt(hex.slice(1), 16);
  const r = (n >> 16) & 255;
  const g = (n >> 8) & 255;
  const b = n & 255;
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

/** The subset of CanvasRenderingContext2D the renderer uses (keeps it
 *  testable with a recording stub). */
export type Ctx2D = Pick<
  CanvasRenderingContext2D,
  | "save" | "restore" | "beginPath" | "closePath" | "moveTo" | "lineTo" | "quadraticCurveTo"
  | "arc" | "ellipse" | "rect" | "stroke" | "fill" | "fillText" | "measureText" | "roundRect"
  | "lineWidth" | "lineCap" | "lineJoin" | "strokeStyle" | "fillStyle" | "globalAlpha"
  | "font" | "textBaseline" | "textAlign" | "shadowColor" | "shadowBlur" | "shadowOffsetY"
>;

export interface RenderOptions {
  /** Device pixels per CSS pixel — shadow blur is not scaled by the
   *  transform, so it is applied by hand. */
  pixelRatio?: number;
  /** Floor for stroke widths in CSS px (thumbnails stay visible). */
  minStrokePx?: number;
  /** Thumbnails skip shadows — at 64 px they only blur the marks. */
  shadows?: boolean;
}

/** Split a label into lines that fit `maxWidth` (words first, then chars). */
export function wrapLabel(text: string, maxWidth: number, measure: (s: string) => number): string[] {
  const words = text.split(" ");
  const lines: string[] = [];
  let line = "";
  const pushLong = (word: string) => {
    let chunk = "";
    for (const ch of word) {
      if (chunk && measure(chunk + ch) > maxWidth) {
        lines.push(chunk);
        chunk = ch;
      } else {
        chunk += ch;
      }
    }
    return chunk;
  };
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (measure(candidate) <= maxWidth) {
      line = candidate;
    } else if (!line) {
      line = pushLong(word);
    } else {
      lines.push(line);
      line = measure(word) > maxWidth ? pushLong(word) : word;
    }
  }
  if (line) lines.push(line);
  return lines;
}

/** Text label box geometry (also used by the composer to place its input). */
export function labelMetrics(size: ShapeSize, rect: Rect) {
  const px = fontSize(size, rect);
  return {
    px,
    padX: px * 0.42,
    padY: px * 0.24,
    lineHeight: px * 1.22,
    radius: px * 0.34,
    font: `600 ${px}px ${LABEL_FONT_FAMILY}`,
  };
}

function drawStroke(ctx: Ctx2D, shape: StrokeShape, rect: Rect, lw: number) {
  const pts = shape.points.map((p) => toBox(p, rect));
  if (pts.length === 1) {
    ctx.beginPath();
    ctx.arc(pts[0][0], pts[0][1], lw / 2, 0, Math.PI * 2);
    ctx.fillStyle = shape.color;
    ctx.fill();
    return;
  }
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  // Quadratic through midpoints: smooth without overshooting the samples.
  for (let i = 1; i < pts.length - 1; i++) {
    const mx = (pts[i][0] + pts[i + 1][0]) / 2;
    const my = (pts[i][1] + pts[i + 1][1]) / 2;
    ctx.quadraticCurveTo(pts[i][0], pts[i][1], mx, my);
  }
  const last = pts[pts.length - 1];
  ctx.lineTo(last[0], last[1]);
  ctx.stroke();
}

function drawArrow(ctx: Ctx2D, shape: BoxShape, rect: Rect, lw: number) {
  const [x1, y1] = toBox(shape.from, rect);
  const [x2, y2] = toBox(shape.to, rect);
  const len = Math.hypot(x2 - x1, y2 - y1);
  if (len === 0) return;
  const angle = Math.atan2(y2 - y1, x2 - x1);
  const head = Math.min(Math.max(lw * 3.6, frameUnit(rect) * 0.024), len * 0.6);
  const spread = (27 * Math.PI) / 180;
  // The shaft stops inside the head so its round cap never pokes past the tip.
  const shaft = len - head * 0.7;
  ctx.beginPath();
  ctx.moveTo(x1, y1);
  ctx.lineTo(x1 + Math.cos(angle) * shaft, y1 + Math.sin(angle) * shaft);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(x2, y2);
  ctx.lineTo(x2 - head * Math.cos(angle - spread), y2 - head * Math.sin(angle - spread));
  ctx.lineTo(x2 - head * Math.cos(angle + spread), y2 - head * Math.sin(angle + spread));
  ctx.closePath();
  ctx.fillStyle = shape.color;
  ctx.fill();
  // A hairline of the same colour rounds the head's corners to match the shaft.
  ctx.lineWidth = Math.max(1, lw * 0.5);
  ctx.stroke();
}

function drawText(ctx: Ctx2D, shape: TextShape, rect: Rect) {
  const m = labelMetrics(shape.size, rect);
  ctx.font = m.font;
  ctx.textBaseline = "top";
  ctx.textAlign = "left";
  const [x, y] = toBox(shape.at, rect);
  // Wrap inside the frame; never narrower than a third of it.
  const room = Math.max(rect.w / 3, rect.x + rect.w - x - m.padX * 2 - rect.w * 0.01);
  const lines = wrapLabel(shape.text, room, (s) => ctx.measureText(s).width);
  const width = Math.max(...lines.map((l) => ctx.measureText(l).width)) + m.padX * 2;
  const height = lines.length * m.lineHeight + m.padY * 2;
  // Pinned inside the frame so a label placed near an edge stays readable.
  const bx = Math.min(Math.max(rect.x, x), rect.x + rect.w - width);
  const by = Math.min(Math.max(rect.y, y), rect.y + rect.h - height);
  // A sticker: dark plate for light ink, light plate for dark ink.
  ctx.beginPath();
  ctx.roundRect(bx, by, width, height, m.radius);
  ctx.fillStyle = luminance(shape.color) > 0.45 ? "rgba(10,11,16,0.72)" : "rgba(255,255,255,0.88)";
  ctx.fill();
  ctx.shadowColor = "transparent";
  ctx.fillStyle = shape.color;
  lines.forEach((line, i) => {
    ctx.fillText(line, bx + m.padX, by + m.padY + i * m.lineHeight + (m.lineHeight - m.px) / 2);
  });
}

/**
 * Draw shapes onto a context whose transform is already CSS-pixel space
 * (the caller applies devicePixelRatio). `rect` is the video frame inside
 * the box. Order matters: later shapes paint over earlier ones, exactly as
 * they were drawn.
 */
export function drawAnnotation(ctx: Ctx2D, shapes: AnnotationShape[], rect: Rect, options: RenderOptions = {}): void {
  if (rect.w <= 0 || rect.h <= 0) return;
  const ratio = options.pixelRatio ?? 1;
  const unit = frameUnit(rect);
  for (const shape of shapes) {
    ctx.save();
    const lw = Math.max(options.minStrokePx ?? 0, strokeWidth(shape.kind, shape.size, rect));
    ctx.lineWidth = lw;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.strokeStyle = shape.color;
    if (options.shadows !== false && shape.kind !== "highlight") {
      // Legibility on bright frames; blur is device pixels, hence × ratio.
      ctx.shadowColor = "rgba(0,0,0,0.38)";
      ctx.shadowBlur = unit * 0.008 * ratio;
      ctx.shadowOffsetY = unit * 0.0016 * ratio;
    }
    switch (shape.kind) {
      case "highlight":
        ctx.globalAlpha = HIGHLIGHT_ALPHA;
        drawStroke(ctx, shape, rect, lw);
        break;
      case "pen":
        drawStroke(ctx, shape, rect, lw);
        break;
      case "arrow":
        drawArrow(ctx, shape, rect, lw);
        break;
      case "rect": {
        const [x1, y1] = toBox(shape.from, rect);
        const [x2, y2] = toBox(shape.to, rect);
        ctx.beginPath();
        ctx.rect(Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1));
        ctx.stroke();
        break;
      }
      case "ellipse": {
        const [x1, y1] = toBox(shape.from, rect);
        const [x2, y2] = toBox(shape.to, rect);
        ctx.beginPath();
        ctx.ellipse((x1 + x2) / 2, (y1 + y2) / 2, Math.abs(x2 - x1) / 2, Math.abs(y2 - y1) / 2, 0, 0, Math.PI * 2);
        ctx.stroke();
        break;
      }
      case "text":
        drawText(ctx, shape, rect);
        break;
    }
    ctx.restore();
  }
}

/** Human summary of a drawing ("arrow, box and a note") for labels and
 *  the Markdown twin. */
export function describeAnnotation(annotation: CommentAnnotation | null): string {
  if (!annotation) return "";
  const n = annotation.shapes.length;
  return `${n} mark${n === 1 ? "" : "s"}`;
}
