/**
 * Port of Services/KeystrokeOverlay.swift — `KeystrokeOverlayMath` (timing,
 * repeat-collapsing, scope filter, pill placement) and the NUMBERS of
 * `KeystrokeOverlayRenderer` (pill size from measured text, the draw recipe
 * of `draw` / `drawPill` / `image`). Shared by the Mac preview and exporter
 * (CLAUDE.md §2): pure functions of the timeline clock.
 *
 * Locked to Swift by the golden-vector units `keystrokeOverlayDisplayEvents`,
 * `keystrokeOverlayActivePill`, `keystrokeOverlayPillGeometry`,
 * `keystrokeOverlayPillMetrics` and `keystrokeOverlayDrawRecipe` (the last
 * proves, on the Swift side, that replaying the recorded ops reproduces the
 * REAL `KeystrokeOverlayRenderer.image` byte for byte).
 *
 * # Text (CoreText) — what the web must measure/draw itself
 *
 * `makeLine`: `NSFont.systemFont(ofSize: 17 · size · scale, weight: .semibold)`
 * (SF Pro — `.AppleSystemUIFontDemi`, CSS `font: 600 <px> system-ui` / "SF
 * Pro Text|Display" on Apple platforms), white, `kern = 1.2 · size · scale`
 * added after EVERY glyph (the trailing kern is part of the width — CSS
 * `letter-spacing` behaves the same in Chrome/Safari). Metrics needed per
 * string: `width` = CTLineGetTypographicBounds width (advance incl. kern),
 * `ascent`, `descent` (positive). The `keystrokeOverlayPillMetrics` vectors
 * record Swift's values for a representative set of shortcut strings ×
 * sizes × scales — the web renderer validates its own measurement against
 * them.
 *
 * # Pixels (drawPill), in the y-DOWN canvas space
 *
 * - Pill path: `CGPath(roundedRect: rect, cornerWidth: h/2, cornerHeight:
 *   h/2)` (CIRCULAR corners, CG clamps each radius to half its side).
 * - Fill sRGB (0.07, 0.07, 0.08, 0.82); stroke sRGB (1, 1, 1, 0.14),
 *   line width `1 · scale`, CENTRED on the path (half inside, half outside).
 * - Text: baseline origin `(rect.midX − width/2, rect.midY + (ascent −
 *   descent)/2)` in the y-down space, glyphs drawn upright (CT's local y-up
 *   flip), white.
 * - `draw`: whole pill at `alpha`, `.pop` scales about the rect centre, and
 *   the pill is composited as ONE transparency layer (fill+stroke+text
 *   never double-blend).
 * - `image`: raster `round(canvas · rasterScale)` px; CTM = scale(rasterScale)
 *   · translate(0, canvasH) · scale(1, −1) (the y-down flip); the exporter
 *   uses rasterScale 1, scale = canvasScale, and composites the raster over
 *   the frame (CI Y-up — the raster's rows are already in image order).
 */
import type { KeystrokeEvent, Point, Project, ProjectSettings, Rect, Size } from "../model/types";
import type { KeystrokeOverlayAnimation, KeystrokeOverlayPosition, RecordingSourceKind } from "../model/enums";
import { cgRoundedRectPath, RecordingContext, rgba, type DrawOp } from "./overlaySupport";
import { midX, midY } from "./geometry";
import { smax, smin, srounded } from "./swift";

export const fadeIn = 0.12;
export const hold = 1.1;
export const fadeOut = 0.3;
/** A same-combo re-press inside this window collapses into "⌘Z ×2". */
export const repeatWindow = 0.8;

export interface DisplayEvent {
  time: number;
  text: string;
}

export interface Pill {
  text: string;
  alpha: number;
  entry: number;
}

/** `KeystrokeOverlayMath.scopedEvents(_:recordedAppBundleID:scopeToRecordedApp:sourceKind:)` */
export function scopedEvents(
  events: readonly KeystrokeEvent[],
  recordedAppBundleID: string | null | undefined,
  scopeToRecordedApp: boolean,
  sourceKind: RecordingSourceKind,
): KeystrokeEvent[] {
  if (!(scopeToRecordedApp && sourceKind === "window") || recordedAppBundleID == null) return events.slice();
  const target = recordedAppBundleID;
  return events.filter((e) => e.frontmostBundleID == null || e.frontmostBundleID === target);
}

/** `KeystrokeOverlayMath.displayEvents(from:)` — collapses rapid repeats. */
export function displayEvents(events: readonly KeystrokeEvent[]): DisplayEvent[] {
  const out: DisplayEvent[] = [];
  let lastBase: string | null = null;
  let lastTime = Number.NEGATIVE_INFINITY;
  let count = 0;
  // Swift `sorted(by: <)` (stable in practice; JS sort is stable).
  const sorted = events.slice().sort((a, b) => (a.timestamp < b.timestamp ? -1 : b.timestamp < a.timestamp ? 1 : 0));
  for (const event of sorted) {
    const shortcut = event.shortcut;
    if (shortcut == null) continue;
    if (shortcut === lastBase && event.timestamp - lastTime <= repeatWindow) {
      count += 1;
      out.push({ time: event.timestamp, text: `${shortcut} ×${count}` });
    } else {
      count = 1;
      out.push({ time: event.timestamp, text: shortcut });
    }
    lastBase = shortcut;
    lastTime = event.timestamp;
  }
  return out;
}

export type KeystrokeScopeProject = Pick<Project, "recordedAppBundleID" | "recordingSourceKind"> & {
  settings: Pick<ProjectSettings, "keystrokeOverlayScopeToRecordedApp">;
};

/** `KeystrokeOverlayMath.displayEvents(from:scopedTo:)` — THE derivation
 * both renderers use (scope filter, then collapse). */
export function displayEventsScoped(events: readonly KeystrokeEvent[], project: KeystrokeScopeProject): DisplayEvent[] {
  return displayEvents(
    scopedEvents(
      events,
      project.recordedAppBundleID ?? null,
      project.settings.keystrokeOverlayScopeToRecordedApp,
      project.recordingSourceKind,
    ),
  );
}

/** `KeystrokeOverlayMath.activePill(displayEvents:currentTime:)` */
export function activePill(events: readonly DisplayEvent[], currentTime: number): Pill | null {
  let latest: DisplayEvent | null = null;
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i].time <= currentTime) {
      latest = events[i];
      break;
    }
  }
  if (!latest) return null;
  const elapsed = currentTime - latest.time;
  const total = fadeIn + hold + fadeOut;
  if (!(elapsed >= 0 && elapsed < total)) return null;
  let alpha: number;
  if (elapsed < fadeIn) alpha = elapsed / fadeIn;
  else if (elapsed < fadeIn + hold) alpha = 1;
  else alpha = 1 - (elapsed - fadeIn - hold) / fadeOut;
  const entry = smin(1, elapsed / (fadeIn * 2));
  return { text: latest.text, alpha: smax(0, smin(1, alpha)), entry };
}

/** `KeystrokeOverlayMath.slideOffset(animation:entry:scale:)` */
export function slideOffset(animation: KeystrokeOverlayAnimation, entry: number, scale: number): number {
  if (animation !== "slideUp") return 0;
  return (1 - entry) * 8 * scale;
}

/** `KeystrokeOverlayMath.popScale(animation:entry:)` */
export function popScale(animation: KeystrokeOverlayAnimation, entry: number): number {
  if (!(animation === "pop" && entry < 1)) return 1;
  const c1 = 1.70158;
  const c3 = c1 + 1;
  const t = entry - 1;
  const eased = 1 + c3 * t * t * t + c1 * t * t;
  return 0.85 + 0.15 * eased;
}

/** `KeystrokeOverlayMath.pillCenter(...)` — Y-DOWN canvas. */
export function pillCenter(
  position: KeystrokeOverlayPosition,
  canvasSize: Size,
  pillSize: Size,
  entry: number,
  scale: number,
  animation: KeystrokeOverlayAnimation = "slideUp",
): Point {
  const edge = 28 * scale;
  let x: number;
  switch (position) {
    case "bottomCenter":
    case "topCenter":
      x = canvasSize.width / 2;
      break;
    case "bottomLeft":
      x = edge + pillSize.width / 2;
      break;
    case "bottomRight":
      x = canvasSize.width - edge - pillSize.width / 2;
      break;
  }
  const slide = slideOffset(animation, entry, scale);
  let y: number;
  if (position === "topCenter") y = edge + pillSize.height / 2 - slide;
  else y = canvasSize.height - 72 * scale - pillSize.height / 2 + slide;
  return { x, y };
}

/** `KeystrokeOverlayMath.pillRect(...)` — origin snapped with Swift `.rounded()`. */
export function pillRect(
  position: KeystrokeOverlayPosition,
  canvasSize: Size,
  pillSize: Size,
  entry: number,
  scale: number,
  animation: KeystrokeOverlayAnimation = "slideUp",
): Rect {
  const c = pillCenter(position, canvasSize, pillSize, entry, scale, animation);
  return {
    x: srounded(c.x - pillSize.width / 2),
    y: srounded(c.y - pillSize.height / 2),
    width: pillSize.width,
    height: pillSize.height,
  };
}

// ── KeystrokeOverlayRenderer numbers ────────────────────────────────────────

/** CoreText typographic bounds of the pill's line (see module doc). */
export interface KeystrokeTextMetrics {
  width: number;
  ascent: number;
  descent: number;
}

/** Measures `text` in the pill font for (size, scale). */
export type KeystrokeMeasure = (text: string, size: number, scale: number) => KeystrokeTextMetrics;

/** Font point size of the pill text: `17 · size · scale`. */
export function pillFontSize(size: number, scale: number): number {
  return 17 * size * scale;
}

/** CoreText kern of the pill text: `1.2 · size · scale`. */
export function pillKern(size: number, scale: number): number {
  return 1.2 * size * scale;
}

/** `KeystrokeOverlayRenderer.pillSize(text:size:scale:)` from measured metrics. */
export function pillSizeFromMetrics(m: KeystrokeTextMetrics, size: number, scale: number): Size {
  const padH = 14 * size * scale;
  const padV = 8 * size * scale;
  return { width: Math.ceil(m.width) + padH * 2, height: Math.ceil(m.ascent + m.descent) + padV * 2 };
}

export const PILL_FILL = rgba(0.07, 0.07, 0.08, 0.82);
export const PILL_STROKE = rgba(1, 1, 1, 0.14);

/** `KeystrokeOverlayRenderer.drawPill` into a recorder (y-down). */
export function drawPill(
  ctx: RecordingContext,
  text: string,
  rect: Rect,
  size: number,
  scale: number,
  metrics: KeystrokeTextMetrics,
): void {
  const path = cgRoundedRectPath(rect, rect.height / 2, rect.height / 2);
  ctx.addPath(path);
  ctx.setFillColor(PILL_FILL);
  ctx.fillPath();
  ctx.addPath(path);
  ctx.setStrokeColor(PILL_STROKE);
  ctx.setLineWidth(1 * scale);
  ctx.strokePath();
  const { width, ascent, descent } = metrics;
  ctx.record({
    op: "ctText",
    text,
    fontSize: pillFontSize(size, scale),
    weight: "semibold",
    kern: pillKern(size, scale),
    color: rgba(1, 1, 1, 1),
    x: midX(rect) - width / 2,
    y: midY(rect) + (ascent - descent) / 2,
    width,
    ascent,
    descent,
    size,
    scale,
  });
}

/** `KeystrokeOverlayRenderer.draw(in:pill:...)` into a recorder. */
export function drawKeystrokePill(
  ctx: RecordingContext,
  pill: Pill,
  canvasSize: Size,
  position: KeystrokeOverlayPosition,
  size: number,
  scale: number,
  animation: KeystrokeOverlayAnimation,
  measure: KeystrokeMeasure,
): void {
  const metrics = measure(pill.text, size, scale);
  const box = pillSizeFromMetrics(metrics, size, scale);
  const rect = pillRect(position, canvasSize, box, pill.entry, scale, animation);
  ctx.saveGState();
  ctx.setAlpha(pill.alpha);
  const pop = popScale(animation, pill.entry);
  if (pop !== 1) {
    ctx.translateBy(midX(rect), midY(rect));
    ctx.scaleBy(pop, pop);
    ctx.translateBy(-midX(rect), -midY(rect));
  }
  ctx.beginTransparencyLayer();
  drawPill(ctx, pill.text, rect, size, scale, metrics);
  ctx.endTransparencyLayer();
  ctx.restoreGState();
}

export interface KeystrokeImageRecipe {
  pixelWidth: number;
  pixelHeight: number;
  /** Starts with the raster base transform (scale · flip). */
  ops: DrawOp[];
}

/** `KeystrokeOverlayRenderer.image(...)` as a recipe; null when no pill is
 * active or the raster would be empty (both renderers skip work). */
export function keystrokeImageRecipe(
  canvasSize: Size,
  events: readonly DisplayEvent[],
  currentTime: number,
  position: KeystrokeOverlayPosition,
  size: number,
  scale: number,
  rasterScale: number,
  animation: KeystrokeOverlayAnimation,
  measure: KeystrokeMeasure,
): KeystrokeImageRecipe | null {
  const pill = activePill(events, currentTime);
  if (!pill) return null;
  const w = Math.trunc(srounded(canvasSize.width * rasterScale));
  const h = Math.trunc(srounded(canvasSize.height * rasterScale));
  if (!(w > 0 && h > 0)) return null;
  const ctx = new RecordingContext();
  ctx.scaleBy(rasterScale, rasterScale);
  ctx.translateBy(0, canvasSize.height);
  ctx.scaleBy(1, -1);
  drawKeystrokePill(ctx, pill, canvasSize, position, size, scale, animation, measure);
  return { pixelWidth: w, pixelHeight: h, ops: ctx.ops };
}
