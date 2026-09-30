/**
 * Hit geometry + drag math of the stage's editing surface — a literal port of
 * `Views/Editor/PreviewCompositor/PreviewInteractionView.swift` (hit zones,
 * drag deltas, clamps, magnetism) plus the shared chrome metrics of
 * `Views/Editor/RegionHandleChrome.swift` (`RegionHandleChrome`,
 * `RegionPillPlacement`) and `Services/SelectionChromeKit.swift` (pill
 * layout). Pure — the DOM/state machine lives in StageInteraction.ts.
 *
 * Units: everything is in CARD px (the engine's pre-camera canvas px,
 * `FrameInfo.videoRect`'s space). The Mac's hit metrics are content-space
 * POINTS; one point is `u` card px (`FrameInfo.canvasScale` — card px per
 * reference-canvas point, the exporter's canvasScale). So the Mac's "12pt
 * corner radius" is `12 * u` here. Normalized region/annotation coordinates
 * are 0–1 of the video rect, Y-down (unchanged).
 */
import type { Annotation, CodablePoint, Rect } from "../../core/model";
import { smax, smin } from "../../core/math/swift";
import type { Pt } from "./stageMapping";

export interface HitGeometry {
  /** Card px. */
  videoRect: Rect;
  /** Card px per Mac point. */
  u: number;
}

/** `PreviewInteractionView.minNormSize`. */
export const MIN_NORM_SIZE = 0.04;

/** `RegionHandleChrome`. */
export const RegionHandleChrome = {
  dotSize: 8,
  dotHoverSize: 10,
  pillGap: 8,
  pillHeight: 26,
} as const;

/** CGRect.contains — half-open on the max edges. */
export function rectContains(r: Rect, p: Pt): boolean {
  const x0 = Math.min(r.x, r.x + r.width);
  const y0 = Math.min(r.y, r.y + r.height);
  const w = Math.abs(r.width);
  const h = Math.abs(r.height);
  return p.x >= x0 && p.x < x0 + w && p.y >= y0 && p.y < y0 + h;
}

export function insetRect(r: Rect, dx: number, dy: number): Rect {
  return { x: r.x + dx, y: r.y + dy, width: r.width - 2 * dx, height: r.height - 2 * dy };
}

const hypot = (x: number, y: number) => Math.sqrt(x * x + y * y);

/** Region "shown" at the playhead (SOURCE seconds), both ends inclusive —
 * the Mac's `time >= region.startTime && time <= region.endTime`. */
export function isActiveAt(item: { startTime: number; endTime: number }, time: number): boolean {
  return time >= item.startTime && time <= item.endTime;
}

// ── Coordinates ─────────────────────────────────────────────────────────────

/** `normalizedVideoPoint(_:_:)` — card px → clamped unit video point. */
export function normalizedVideoPoint(cp: Pt, g: HitGeometry): Pt {
  const vr = g.videoRect;
  return {
    x: smin(1, smax(0, (cp.x - vr.x) / smax(1, vr.width))),
    y: smin(1, smax(0, (cp.y - vr.y) / smax(1, vr.height))),
  };
}

/** Unit video point → card px (`AnnotationRenderer.point(_:_:in:)`). */
export function videoPoint(nx: number, ny: number, vr: Rect): Pt {
  return { x: vr.x + nx * vr.width, y: vr.y + ny * vr.height };
}

// ── Regions (blur / highlight / depth focus) ────────────────────────────────

/** `regionPixelRect(_:_:)` — min 30×20 pt so tiny regions stay grabbable. */
export function regionPixelRect(norm: Rect, g: HitGeometry): Rect {
  const vr = g.videoRect;
  return {
    x: vr.x + norm.x * vr.width,
    y: vr.y + norm.y * vr.height,
    width: smax(30 * g.u, norm.width * vr.width),
    height: smax(20 * g.u, norm.height * vr.height),
  };
}

/** `sliderWidth` of the value pill (SelectionChromeKit / pillRect). */
export function pillSliderWidth(r: Rect, u: number): number {
  return smin(smax(90 * u, r.width - 60 * u), 150 * u);
}

/**
 * `PreviewInteractionView.pillRect(for:_:)` — the value pill's HIT rect
 * (RegionPillPlacement port: below the region when it fits, else tucked
 * inside the bottom edge, clamped horizontally to the video).
 */
export function regionPillHitRect(r: Rect, g: HitGeometry): Rect {
  const u = g.u;
  const sliderWidth = pillSliderWidth(r, u);
  const pillWidth = sliderWidth + 54 * u;
  const pillHeight = RegionHandleChrome.pillHeight * u;
  const gap = RegionHandleChrome.pillGap * u;
  const container = g.videoRect;
  const fitsBelow = r.y + r.height + gap + pillHeight <= container.y + container.height;
  const y = fitsBelow ? r.y + r.height + gap : r.y + r.height - gap - pillHeight;
  const lower = container.x + pillWidth / 2;
  const upper = container.x + container.width - pillWidth / 2;
  const centreX = upper >= lower ? smin(smax(r.x + r.width / 2, lower), upper) : container.x + container.width / 2;
  return { x: centreX - pillWidth / 2, y, width: pillWidth, height: pillHeight };
}

/** `RegionPillPlacement.offset(regionRect:containerRect:pillWidth:)`. */
export function regionPillPlacementOffset(regionRect: Rect, containerRect: Rect, pillWidth: number, u: number): Pt {
  const half = (RegionHandleChrome.pillHeight * u) / 2;
  const gap = RegionHandleChrome.pillGap * u;
  const below = half + gap;
  const inside = -(half + gap);
  const fitsBelow = regionRect.y + regionRect.height + gap + RegionHandleChrome.pillHeight * u <= containerRect.y + containerRect.height;
  const y = fitsBelow ? below : inside;
  const centreX = regionRect.x + regionRect.width / 2;
  const lower = containerRect.x + pillWidth / 2;
  const upper = containerRect.x + containerRect.width - pillWidth / 2;
  const clamped = upper >= lower ? smin(smax(centreX, lower), upper) : containerRect.x + containerRect.width / 2;
  return { x: clamped - centreX, y };
}

/** Idle pill metrics — `SelectionChromeKit` (points). */
export const PillMetrics = {
  railHeight: 3,
  knobIdle: 12,
  iconSize: 9,
  spacing: 8,
  padding: 8,
} as const;

/**
 * SF Symbol frames at 9pt regular (`symbolSize`), in points. AppKit reports
 * the configured image size; these are the measured frames (the Mac notes a
 * blur pill drew 210.5pt wide where pillWidth said 204 → eye + eye.slash.fill
 * ≈ 28.5pt together).
 */
export const PILL_ICON_SIZES: Record<string, { width: number; height: number }> = {
  eye: { width: 14, height: 9 },
  "eye.slash.fill": { width: 14.5, height: 11 },
  "circle.dashed": { width: 11, height: 11 },
  "camera.aperture": { width: 11, height: 11 },
  "circle.lefthalf.filled": { width: 11, height: 11 },
  "circle.fill": { width: 11, height: 11 },
};

export function pillIconSize(name: string): { width: number; height: number } {
  return PILL_ICON_SIZES[name] ?? { width: PillMetrics.iconSize, height: PillMetrics.iconSize };
}

export interface PillLayout {
  /** The drawn capsule (card px). */
  pill: Rect;
  leadingCenter: Pt;
  trailingCenter: Pt;
  /** The slider rect `drawSliderTrack` gets (knobIdle + 2 tall). */
  slider: Rect;
}

/** `SelectionChromeKit.drawPill` geometry for region rect `r` (card px). */
export function regionPillLayout(r: Rect, g: HitGeometry, leadingIcon: string, trailingIcon: string): PillLayout {
  const u = g.u;
  const sliderWidth = pillSliderWidth(r, u);
  const pillWidth = sliderWidth + 54 * u;
  const lead = pillIconSize(leadingIcon);
  const trail = pillIconSize(trailingIcon);
  const pad = PillMetrics.padding * u;
  const sp = PillMetrics.spacing * u;
  const drawnWidth = pad + lead.width * u + sp + sliderWidth + sp + trail.width * u + pad;
  const pillHeight = RegionHandleChrome.pillHeight * u;
  const offset = regionPillPlacementOffset(r, g.videoRect, pillWidth, u);
  // `.overlay(alignment: .bottom)`: the unoffset centre is half a pill up.
  const center = { x: r.x + r.width / 2 + offset.x, y: r.y + r.height - pillHeight / 2 + offset.y };
  const pill = { x: center.x - drawnWidth / 2, y: center.y - pillHeight / 2, width: drawnWidth, height: pillHeight };
  const contentLeft = pill.x + pad;
  const trackX = contentLeft + lead.width * u + sp;
  const knob = (PillMetrics.knobIdle + 2) * u;
  return {
    pill,
    leadingCenter: { x: contentLeft + (lead.width * u) / 2, y: center.y },
    trailingCenter: { x: trackX + sliderWidth + sp + (trail.width * u) / 2, y: center.y },
    slider: { x: trackX, y: center.y - knob / 2, width: sliderWidth, height: knob },
  };
}

export type RegionHit =
  /** Value pill: X over `track` → 0…1. */
  | { kind: "slider"; track: { minX: number; width: number } }
  | { kind: "resize"; left: boolean; right: boolean; top: boolean; bottom: boolean }
  | { kind: "move" };

/**
 * `regionDragMode(_:rect:ref:isSelected:ctx:select:)` — pill, then 24pt
 * corner zones, then 18pt edge strips (selected only), then the body.
 *
 * One deliberate extension: the Mac's pill HIT rect (`pillRect(for:)`) sits
 * half a pill BELOW the pill it draws (`.overlay(alignment: .bottom)` offsets
 * the drawn one up), so the drawn pill's upper half falls through to the
 * edge strips / body. After the Mac's zones miss, a press inside the DRAWN
 * pill also starts the slider — every point the Mac handles is unchanged.
 */
export function regionHit(cp: Pt, norm: Rect, isSelected: boolean, g: HitGeometry, icons?: { leading: string; trailing: string }): RegionHit | null {
  const u = g.u;
  const r = regionPixelRect(norm, g);
  if (isSelected) {
    const pill = regionPillHitRect(r, g);
    const track = { minX: pill.x + 27 * u, width: pill.width - 54 * u };
    if (rectContains(pill, cp)) return { kind: "slider", track };
    const z = 12 * u;
    const corners: Array<[Rect, [boolean, boolean, boolean, boolean]]> = [
      [{ x: r.x - z, y: r.y - z, width: 2 * z, height: 2 * z }, [true, false, true, false]],
      [{ x: r.x + r.width - z, y: r.y - z, width: 2 * z, height: 2 * z }, [false, true, true, false]],
      [{ x: r.x - z, y: r.y + r.height - z, width: 2 * z, height: 2 * z }, [true, false, false, true]],
      [{ x: r.x + r.width - z, y: r.y + r.height - z, width: 2 * z, height: 2 * z }, [false, true, false, true]],
    ];
    for (const [zone, m] of corners) {
      if (rectContains(zone, cp)) return { kind: "resize", left: m[0], right: m[1], top: m[2], bottom: m[3] };
    }
    const edges: Array<[Rect, [boolean, boolean, boolean, boolean]]> = [
      [{ x: r.x + 16 * u, y: r.y - 9 * u, width: smax(30 * u, r.width - 32 * u), height: 18 * u }, [false, false, true, false]],
      [{ x: r.x + 16 * u, y: r.y + r.height - 9 * u, width: smax(30 * u, r.width - 32 * u), height: 18 * u }, [false, false, false, true]],
      [{ x: r.x - 9 * u, y: r.y + 14 * u, width: 18 * u, height: smax(24 * u, r.height - 28 * u) }, [true, false, false, false]],
      [{ x: r.x + r.width - 9 * u, y: r.y + 14 * u, width: 18 * u, height: smax(24 * u, r.height - 28 * u) }, [false, true, false, false]],
    ];
    for (const [zone, m] of edges) {
      if (rectContains(zone, cp)) return { kind: "resize", left: m[0], right: m[1], top: m[2], bottom: m[3] };
    }
    if (icons && rectContains(regionPillLayout(r, g, icons.leading, icons.trailing).pill, cp)) return { kind: "slider", track };
  }
  if (rectContains(r, cp)) return { kind: "move" };
  return null;
}

/** Slider X → 0…1 over the track (the `.regionSlider` drag). */
export function sliderFraction(x: number, track: { minX: number; width: number }): number {
  return smin(1, smax(0, (x - track.minX) / smax(1, track.width)));
}

/** Blur intensity / highlight opacity / depth-focus intensity from the pill. */
export function sliderValue(kind: "blur" | "highlight" | "focus", f: number): number {
  return kind === "highlight" ? 0.1 + f * 0.8 : 0.1 + f * 0.9;
}

/** `adjust(_:_:p:left:right:top:bottom:move:)` with the deltas already in
 * normalized video units. */
export function adjustRegionRect(
  initial: Rect,
  dx: number,
  dy: number,
  edges: { left: boolean; right: boolean; top: boolean; bottom: boolean },
  move: boolean,
): Rect {
  const clamped = (v: number, lo: number, hi: number) => (hi >= lo ? smin(smax(v, lo), hi) : lo);
  const w = Math.abs(initial.width);
  const h = Math.abs(initial.height);
  if (move) {
    return {
      x: clamped(initial.x + dx, 0, smax(0, 1 - w)),
      y: clamped(initial.y + dy, 0, smax(0, 1 - h)),
      width: w,
      height: h,
    };
  }
  const iMinX = Math.min(initial.x, initial.x + initial.width);
  const iMinY = Math.min(initial.y, initial.y + initial.height);
  const iMaxX = iMinX + w;
  const iMaxY = iMinY + h;
  let minX = iMinX;
  let maxX = iMaxX;
  let minY = iMinY;
  let maxY = iMaxY;
  if (edges.left) minX = clamped(iMinX + dx, 0, smax(0, iMaxX - MIN_NORM_SIZE));
  if (edges.right) maxX = clamped(iMaxX + dx, smin(1, iMinX + MIN_NORM_SIZE), 1);
  if (edges.top) minY = clamped(iMinY + dy, 0, smax(0, iMaxY - MIN_NORM_SIZE));
  if (edges.bottom) maxY = clamped(iMaxY + dy, smin(1, iMinY + MIN_NORM_SIZE), 1);
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

// ── Annotations ─────────────────────────────────────────────────────────────

export interface AnnotationHandleHit {
  xIsStart: boolean;
  yIsStart: boolean;
}

/** `annotationHandleHit(_:at:_:)` — arrow endpoints and shape corners, with
 * the radius shrinking on small shapes so corner targets never swallow the body. */
export function annotationHandleHit(a: Annotation, cp: Pt, g: HitGeometry): AnnotationHandleHit | null {
  const vr = g.videoRect;
  const u = g.u;
  const pt = (nx: number, ny: number) => videoPoint(nx, ny, vr);
  const shapeW = Math.abs(a.arrowEndX - a.x) * vr.width;
  const shapeH = Math.abs(a.arrowEndY - a.y) * vr.height;
  const radius = smin(12 * u, smax(5 * u, smin(shapeW, shapeH) / 4));
  const near = (p: Pt) => hypot(cp.x - p.x, cp.y - p.y) <= radius;
  switch (a.type) {
    case "arrow":
      if (near(pt(a.arrowEndX, a.arrowEndY))) return { xIsStart: false, yIsStart: false }; // head
      if (near(pt(a.x, a.y))) return { xIsStart: true, yIsStart: true }; // tail
      return null;
    case "rectangle":
    case "ellipse":
      if (near(pt(a.x, a.y))) return { xIsStart: true, yIsStart: true }; // TL
      if (near(pt(a.arrowEndX, a.y))) return { xIsStart: false, yIsStart: true }; // TR
      if (near(pt(a.x, a.arrowEndY))) return { xIsStart: true, yIsStart: false }; // BL
      if (near(pt(a.arrowEndX, a.arrowEndY))) return { xIsStart: false, yIsStart: false }; // BR
      return null;
    default:
      return null;
  }
}

/** The renderer's label pill/box for a text/callout (card px) — injected so
 * this module stays DOM-free (see annotationLabel.ts). */
export type LabelRectFn = (a: Annotation) => Rect | null;

/** `annotationHitRect(_:_:)`. */
export function annotationHitRect(a: Annotation, g: HitGeometry, labelRect: LabelRectFn): Rect {
  const vr = g.videoRect;
  const u = g.u;
  const p = videoPoint(a.x, a.y, vr);
  const span = (inset: number): Rect => {
    const q = videoPoint(a.arrowEndX, a.arrowEndY, vr);
    return insetRect({ x: Math.min(p.x, q.x), y: Math.min(p.y, q.y), width: Math.abs(q.x - p.x), height: Math.abs(q.y - p.y) }, -inset, -inset);
  };
  switch (a.type) {
    case "rectangle":
    case "ellipse":
      return span(10 * u);
    case "arrow":
    case "callout":
      return span(16 * u);
    case "tap": {
      const r = smax(24, a.fontSize) * u;
      return { x: p.x - r, y: p.y - r, width: r * 2, height: r * 2 };
    }
    case "drawing": {
      let minX = Infinity;
      let minY = Infinity;
      let maxX = -Infinity;
      let maxY = -Infinity;
      for (const stroke of a.drawingStrokes) {
        for (const q of stroke) {
          minX = smin(minX, q.x);
          maxX = smax(maxX, q.x);
          minY = smin(minY, q.y);
          maxY = smax(maxY, q.y);
        }
      }
      // No strokes yet (fresh drawing) — the whole video, so pen-down anywhere starts one.
      if (!Number.isFinite(minX)) return { ...vr };
      return insetRect(
        { x: vr.x + minX * vr.width, y: vr.y + minY * vr.height, width: (maxX - minX) * vr.width, height: (maxY - minY) * vr.height },
        -12 * u,
        -12 * u,
      );
    }
    case "text": {
      const pill = labelRect(a);
      if (pill) return insetRect(pill, -8 * u, -8 * u);
      return defaultBox(a, p, u);
    }
    default:
      return defaultBox(a, p, u);
  }
}

function defaultBox(a: Annotation, p: Pt, u: number): Rect {
  const w = smax(60, a.fontSize * smax(3, [...a.text].length) * 0.6) * u;
  const h = smax(28, a.fontSize * 1.8) * u;
  return { x: p.x - w / 2, y: p.y - h / 2, width: w, height: h };
}

/** Two-point shapes move as a unit (`.annotation` drag): the DELTA is clamped
 * so the whole shape stays on the video and its size never changes. Other
 * types move their anchor, clamped to 0…1. */
export function movedAnnotation(
  type: Annotation["type"],
  initial: Pt,
  initialEnd: Pt,
  dx: number,
  dy: number,
): Pick<Annotation, "x" | "y"> & Partial<Pick<Annotation, "arrowEndX" | "arrowEndY">> {
  switch (type) {
    case "rectangle":
    case "ellipse":
    case "arrow":
    case "callout": {
      const minX = smin(initial.x, initialEnd.x);
      const maxX = smax(initial.x, initialEnd.x);
      const minY = smin(initial.y, initialEnd.y);
      const maxY = smax(initial.y, initialEnd.y);
      const cx = smax(-minX, smin(1 - maxX, dx));
      const cy = smax(-minY, smin(1 - maxY, dy));
      return { x: initial.x + cx, y: initial.y + cy, arrowEndX: initialEnd.x + cx, arrowEndY: initialEnd.y + cy };
    }
    default:
      return { x: smax(0, smin(1, initial.x + dx)), y: smax(0, smin(1, initial.y + dy)) };
  }
}

/** `.annotationHandle` drag — the handle rides the cursor (position, not delta). */
export function handleDragPatch(cp: Pt, g: HitGeometry, h: AnnotationHandleHit): Partial<Pick<Annotation, "x" | "y" | "arrowEndX" | "arrowEndY">> {
  const vr = g.videoRect;
  const nx = smax(0, smin(1, (cp.x - vr.x) / smax(1, vr.width)));
  const ny = smax(0, smin(1, (cp.y - vr.y) / smax(1, vr.height)));
  const patch: Partial<Pick<Annotation, "x" | "y" | "arrowEndX" | "arrowEndY">> = {};
  if (h.xIsStart) patch.x = nx;
  else patch.arrowEndX = nx;
  if (h.yIsStart) patch.y = ny;
  else patch.arrowEndY = ny;
  return patch;
}

/** Appends a pen point to the last stroke (`.draw` drag). */
export function appendStrokePoint(strokes: readonly CodablePoint[][], p: Pt): CodablePoint[][] {
  if (strokes.length === 0) return [[{ x: p.x, y: p.y }]];
  const out = strokes.slice();
  out[out.length - 1] = [...out[out.length - 1], { x: p.x, y: p.y }];
  return out;
}

// ── Armed blur draw ─────────────────────────────────────────────────────────

/** `.blurDraw` mouse-up: the dragged unit rect; a click (or sliver) grows to
 * the minimum around the pointer; clipped to the unit square. Null when the
 * result is too small to create (≤ 0.005). */
export function blurDrawRect(a: Pt, b: Pt): Rect | null {
  let rect: Rect = { x: smin(a.x, b.x), y: smin(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) };
  if (rect.width < MIN_NORM_SIZE || rect.height < MIN_NORM_SIZE) {
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    const w = smax(rect.width, MIN_NORM_SIZE * 2);
    const h = smax(rect.height, MIN_NORM_SIZE * 2);
    rect = { x: cx - w / 2, y: cy - h / 2, width: w, height: h };
  }
  const x0 = smax(rect.x, 0);
  const y0 = smax(rect.y, 0);
  const x1 = smin(rect.x + rect.width, 1);
  const y1 = smin(rect.y + rect.height, 1);
  if (!(x1 > x0 && y1 > y0)) return null;
  const out = { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
  return out.width > 0.005 && out.height > 0.005 ? out : null;
}

// ── Zoom focal target ───────────────────────────────────────────────────────

/** On-canvas focal reticle radius (content pt): `16 / max(1, zoom)`. */
export function focalReticleRadius(zoom: number): number {
  return 16 / smax(1, zoom);
}

/** The focal target's grab radius (content pt): `22 / max(1, zoom)`. */
export function focalGrabRadius(zoom: number): number {
  return 22 / smax(1, zoom);
}

export function focalHit(cp: Pt, focal: Pt, g: HitGeometry, zoom: number): boolean {
  const c = videoPoint(focal.x, focal.y, g.videoRect);
  return hypot(cp.x - c.x, cp.y - c.y) <= focalGrabRadius(zoom) * g.u;
}

// ── Card drags ──────────────────────────────────────────────────────────────

/** Placement / blockOffset only start moving past 8pt (SwiftUI's threshold). */
export const CARD_DRAG_THRESHOLD = 8;
