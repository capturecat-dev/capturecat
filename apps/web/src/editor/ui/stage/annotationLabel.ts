/**
 * Label metrics for the stage's annotation hit rects and the in-place label
 * editor — `AnnotationRenderer.TextLine` measured by the browser.
 *
 * Swift: font = `FontCatalog.font(named: a.fontName, size: a.fontSize ·
 * scale, weight: a.fontWeight)` (nil / "System" / unknown → the system face,
 * SF Pro); width/height = `NSAttributedString.size()` of `displayText` (one
 * line; height = the font's line height); baseline = round(ascender). The
 * geometry itself (pads, centring) is the core's `labelRect`, so the hit rect
 * and the editor sit on the same pill the renderer draws.
 *
 * Browser text only approximates CoreText (a few px of AA / advance drift) —
 * good enough for hit-testing and the editor field; the pixels on the stage
 * come from the engine's annotation pass.
 */
import type { Annotation, Rect } from "../../core/model";
import { labelRect, type AnnotationTextLine } from "../../core/math/annotationGeometry";
import { displayText } from "../../core/math/annotationEffectMath";

const WEIGHT: Record<string, number> = { Regular: 400, Medium: 500, Semibold: 600, Bold: 700, Heavy: 800 };

/** FontCatalog family → CSS font-family stack (system faces via the ui-* generics). */
export function annotationFontFamily(name: string | undefined | null): string {
  const system = `system-ui, -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif`;
  if (!name || name === "System" || name === "SF Pro") return system;
  if (name === "SF Pro Rounded") return `ui-rounded, ${system}`;
  if (name === "New York") return `ui-serif, "New York", Georgia, serif`;
  if (name === "SF Mono") return `ui-monospace, "SF Mono", Menlo, monospace`;
  return `"${name.replace(/"/g, "")}", ${system}`;
}

export function annotationFontWeight(a: Pick<Annotation, "fontWeight">): number {
  return WEIGHT[a.fontWeight] ?? 400;
}

/** CSS `font` shorthand for `a` at `sizePx`. */
export function annotationCssFont(a: Pick<Annotation, "fontWeight" | "fontName">, sizePx: number): string {
  return `${annotationFontWeight(a)} ${sizePx}px ${annotationFontFamily(a.fontName)}`;
}

type Ctx2D = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;
let ctx: Ctx2D | null | undefined;
function measureContext(): Ctx2D | null {
  if (ctx !== undefined) return ctx;
  try {
    if (typeof OffscreenCanvas !== "undefined") ctx = new OffscreenCanvas(1, 1).getContext("2d");
    else if (typeof document !== "undefined") ctx = document.createElement("canvas").getContext("2d");
    else ctx = null;
  } catch {
    ctx = null;
  }
  return ctx ?? null;
}

const cache = new Map<string, AnnotationTextLine>();

/** Measures `text` in `font` (CSS px): advance width + line height + baseline. */
export function measureLine(text: string, font: string, sizePx: number): AnnotationTextLine {
  const key = `${font}|${text}`;
  const hit = cache.get(key);
  if (hit) return hit;
  const c = measureContext();
  let line: AnnotationTextLine;
  if (!c) {
    // Headless fallback: SF Pro's hhea metrics (ascender .952, descender .241).
    line = { width: text.length * sizePx * 0.55, height: sizePx * 1.193, baselineFromTop: Math.round(sizePx * 0.952) };
  } else {
    c.font = font;
    const m = c.measureText(text);
    const ascent = m.fontBoundingBoxAscent ?? sizePx * 0.952;
    const descent = m.fontBoundingBoxDescent ?? sizePx * 0.241;
    line = { width: m.width, height: ascent + descent, baselineFromTop: Math.round(ascent) };
  }
  if (cache.size > 512) cache.clear();
  cache.set(key, line);
  return line;
}

/** `TextLine(a, scale)` — `displayText(a)` at font size `a.fontSize · scale`. */
export function annotationTextLine(a: Annotation, scale: number): AnnotationTextLine {
  const size = a.fontSize * scale;
  return measureLine(displayText(a), annotationCssFont(a, size), size);
}

/** `AnnotationRenderer.labelRect(a, videoRect:, scale:)` in card px. */
export function annotationLabelRect(a: Annotation, videoRect: Rect, scale: number): Rect | null {
  if (!(a.type === "text" || a.type === "callout")) return null;
  return labelRect(a, videoRect, scale, annotationTextLine(a, scale));
}
