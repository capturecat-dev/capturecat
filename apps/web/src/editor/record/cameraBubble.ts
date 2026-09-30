/**
 * The floating camera bubble — the web twin of the Mac's recording-time
 * camera preview (Views/AppKitSurfaces/CameraFloatPreview.swift:
 * CameraFloatMetrics + CameraFloatSquircleView). Pure geometry, persistence
 * and show/hide policy; the view is components/dashboard/camera-bubble.tsx.
 *
 *   shape     the true squircle, `CameraStyleMath.superellipsePath` — the SAME
 *             path the editor preview and exporter clip the camera with
 *   size      square content at the saved diameter (default 200 — Small 150,
 *             Medium 200, Large 270), plus 24 px of slack on every side for
 *             the shadow to paint into (`panelSize`)
 *   position  free — no snapping. Persisted, and restored only while the
 *             saved rect inset by 40 still meets the viewport; else the
 *             default: bottom-right, 12 px margin, clear of the recording dock
 *
 * Web additions (a browser window resizes; a Mac screen rarely does): the
 * position is kept relative to the NEAREST viewport corner (`BubbleAnchor`),
 * so a bubble parked bottom-right stays bottom-right as the window changes,
 * and a size change grows out of that corner. The rendered rect is clamped so
 * the squircle itself never leaves the viewport.
 */
import type { Rect, Size } from "../core/model/types";
import { squircleExponent, superellipsePath } from "../core/math/cameraStyleMath";
import type { SurfaceKind } from "./capture";

// ── metrics (CameraFloatMetrics) ────────────────────────────────────────────

export const BUBBLE_SIZES = [
  { label: "Small", diameter: 150 },
  { label: "Medium", diameter: 200 },
  { label: "Large", diameter: 270 },
] as const;

/** `savedDiameter`'s fallback — ~200 pt like Screen Studio's. */
export const DEFAULT_DIAMETER = 200;
/** Slack around the content for the drop shadow (`shadowPadding`). */
export const SHADOW_PADDING = 24;
/** Default placement margin from the viewport edges (`restoredOrigin`). */
export const EDGE_MARGIN = 12;
/** A restored rect must still meet the viewport after this inset. */
export const RESTORE_INSET = 40;
/** How long the bubble's exit (fade + 0.97 scale) runs — app.css `.rec-bubble-out`. */
export const BUBBLE_EXIT_MS = 200;
/** The tooltip, word for word the Mac's. */
export const BUBBLE_TOOLTIP = "Drag to move — right-click for size.";

export const DIAMETER_KEY = "cc.cameraBubble.diameter";
export const POSITION_KEY = "cc.cameraBubble.position";

/** Panel (content + shadow slack) edge length for a content diameter. */
export function panelSize(diameter: number): number {
  return diameter + SHADOW_PADDING * 2;
}

/** The size menu's checkmark rule: `abs(savedDiameter - value) < 1`. */
export function isCurrentSize(saved: number, value: number): boolean {
  return Math.abs(saved - value) < 1;
}

// ── placement ───────────────────────────────────────────────────────────────

/**
 * Where the panel sits: its distance from the nearest vertical and
 * horizontal viewport edges (panel frame, shadow slack included).
 */
export interface BubbleAnchor {
  h: "left" | "right";
  dx: number;
  v: "top" | "bottom";
  dy: number;
}

/** Top-left panel rect (viewport px, Y-down) for an anchor. Unclamped. */
export function rectFromAnchor(anchor: BubbleAnchor, panel: number, viewport: Size): Rect {
  return {
    x: anchor.h === "left" ? anchor.dx : viewport.width - anchor.dx - panel,
    y: anchor.v === "top" ? anchor.dy : viewport.height - anchor.dy - panel,
    width: panel,
    height: panel,
  };
}

/** The anchor that reproduces `rect`, measured from its nearest corner. */
export function anchorFromRect(rect: Rect, viewport: Size): BubbleAnchor {
  const left = rect.x + rect.width / 2 < viewport.width / 2;
  const top = rect.y + rect.height / 2 < viewport.height / 2;
  return {
    h: left ? "left" : "right",
    dx: left ? rect.x : viewport.width - rect.x - rect.width,
    v: top ? "top" : "bottom",
    dy: top ? rect.y : viewport.height - rect.y - rect.height,
  };
}

/**
 * Keep the squircle (the panel minus its shadow slack) inside the viewport —
 * the shadow may spill past an edge. A viewport smaller than the content pins
 * it to the top-left.
 */
export function clampRect(rect: Rect, viewport: Size): Rect {
  const pad = SHADOW_PADDING;
  const clampAxis = (pos: number, size: number, extent: number) => {
    const lo = -pad;
    const hi = extent - size + pad;
    return hi < lo ? lo : Math.min(hi, Math.max(lo, pos));
  };
  return {
    x: clampAxis(rect.x, rect.width, viewport.width),
    y: clampAxis(rect.y, rect.height, viewport.height),
    width: rect.width,
    height: rect.height,
  };
}

/** NSRect.intersects: a shared area of positive size (touching edges don't count). */
export function rectsIntersect(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

/** NSRect.insetBy(dx:dy:). */
export function insetRect(r: Rect, dx: number, dy: number): Rect {
  return { x: r.x + dx, y: r.y + dy, width: r.width - 2 * dx, height: r.height - 2 * dy };
}

/**
 * Default: bottom-right with a 12 px margin — `visible.maxX − panel − 12`,
 * `visible.minY + 12` — lifted to sit 12 px above the recording dock when it
 * would overlap it (the dock is this page's "visible frame" bottom).
 */
export function defaultAnchor(panel: number, viewport: Size, dock: Rect | null): BubbleAnchor {
  const anchor: BubbleAnchor = { h: "right", dx: EDGE_MARGIN, v: "bottom", dy: EDGE_MARGIN };
  if (dock && dock.width > 0 && dock.height > 0 && rectsIntersect(rectFromAnchor(anchor, panel, viewport), dock)) {
    anchor.dy = Math.max(EDGE_MARGIN, viewport.height - dock.y + EDGE_MARGIN);
  }
  return anchor;
}

/**
 * `restoredOrigin(panelSize:)`: the saved placement, kept only while it is
 * still mostly on screen (inset by 40, it must meet the viewport) — else the
 * default.
 */
export function restoreAnchor(saved: BubbleAnchor | null, panel: number, viewport: Size, dock: Rect | null): BubbleAnchor {
  if (saved) {
    const frame = rectFromAnchor(saved, panel, viewport);
    const screen: Rect = { x: 0, y: 0, width: viewport.width, height: viewport.height };
    if (rectsIntersect(insetRect(frame, RESTORE_INSET, RESTORE_INSET), screen)) return saved;
  }
  return defaultAnchor(panel, viewport, dock);
}

/**
 * The rendered frame for an anchor (clamped on-screen), and its CSS offsets
 * expressed from the anchored edges — so a width/height transition grows the
 * panel out of the anchored corner while those edges stay pinned.
 */
export function placeBubble(
  anchor: BubbleAnchor,
  diameter: number,
  viewport: Size,
): { rect: Rect; css: { left?: number; right?: number; top?: number; bottom?: number } } {
  const panel = panelSize(diameter);
  const rect = clampRect(rectFromAnchor(anchor, panel, viewport), viewport);
  return {
    rect,
    css: {
      ...(anchor.h === "left" ? { left: rect.x } : { right: viewport.width - rect.x - rect.width }),
      ...(anchor.v === "top" ? { top: rect.y } : { bottom: viewport.height - rect.y - rect.height }),
    },
  };
}

// ── persistence (UserDefaults → localStorage) ───────────────────────────────

export interface KeyValueStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

/** localStorage, or null where touching it throws (sandboxed frames, some private modes). */
function browserStore(): KeyValueStore | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null;
  }
}

function read(key: string, store: KeyValueStore | null): string | null {
  try {
    return store?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function write(key: string, value: string, store: KeyValueStore | null): void {
  try {
    store?.setItem(key, value);
  } catch {
    // private mode / quota: the bubble just doesn't remember
  }
}

/** `savedDiameter`: the stored value when positive, else 200. */
export function loadDiameter(store: KeyValueStore | null = browserStore()): number {
  const stored = Number(read(DIAMETER_KEY, store));
  return Number.isFinite(stored) && stored > 0 ? stored : DEFAULT_DIAMETER;
}

export function saveDiameter(value: number, store: KeyValueStore | null = browserStore()): void {
  write(DIAMETER_KEY, String(value), store);
}

export function loadAnchor(store: KeyValueStore | null = browserStore()): BubbleAnchor | null {
  const raw = read(POSITION_KEY, store);
  if (!raw) return null;
  try {
    const a = JSON.parse(raw) as Partial<BubbleAnchor>;
    if ((a.h !== "left" && a.h !== "right") || (a.v !== "top" && a.v !== "bottom")) return null;
    if (typeof a.dx !== "number" || typeof a.dy !== "number" || !Number.isFinite(a.dx) || !Number.isFinite(a.dy)) return null;
    return { h: a.h, dx: a.dx, v: a.v, dy: a.dy };
  } catch {
    return null;
  }
}

export function saveAnchor(anchor: BubbleAnchor, store: KeyValueStore | null = browserStore()): void {
  const round = (n: number) => Math.round(n * 100) / 100;
  write(POSITION_KEY, JSON.stringify({ h: anchor.h, dx: round(anchor.dx), v: anchor.v, dy: round(anchor.dy) }), store);
}

// ── shape (CameraStyleMath.superellipsePath) ────────────────────────────────

const num = (n: number) => String(Math.round(n * 1e5) / 1e5);

/** The superellipse polyline as an SVG path `d` (same 256 points, same start). */
export function squirclePathD(rect: Rect): string {
  let d = "";
  for (const el of superellipsePath(rect)) {
    if (el.op === "close") d += "Z";
    else d += `${el.op === "move" ? "M" : "L"}${num(el.pts[0].x)} ${num(el.pts[0].y)}`;
  }
  return d;
}

/** The squircle in a unit box — scaled to any size by viewBox 0 0 1 1 (the curve is affine in a, b). */
export const UNIT_SQUIRCLE_D = squirclePathD({ x: 0, y: 0, width: 1, height: 1 });

/**
 * CSS mask for the squircle at whatever size the box is (`mask-size: 100%
 * 100%`) — so the mask follows a size animation frame by frame. No
 * width/height on the <svg>: it rasterises at the box's size, not 1 px.
 */
export const SQUIRCLE_MASK_IMAGE = `url("data:image/svg+xml,${encodeURIComponent(
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1" preserveAspectRatio="none"><path d="${UNIT_SQUIRCLE_D}"/></svg>`,
)}")`;

/** Point-in-squircle for `rect` (|x/a|ⁿ + |y/b|ⁿ ≤ 1, n = 4.5) — the analytic curve the polyline samples. */
export function squircleLevel(px: number, py: number, rect: Rect): number {
  const a = rect.width / 2;
  const b = rect.height / 2;
  const dx = Math.abs(px - (rect.x + a)) / a;
  const dy = Math.abs(py - (rect.y + b)) / b;
  return Math.pow(dx, squircleExponent) + Math.pow(dy, squircleExponent);
}

// ── when and where it shows ─────────────────────────────────────────────────

export interface BubblePolicyInput {
  /** Armed with a camera chosen (the stream may still be opening). */
  cameraOn: boolean;
  phase: "setup" | "countdown" | "recording" | "saving" | "failed";
  /** The chosen share's surface (null = nothing chosen yet). */
  surface: SurfaceKind | null;
  /** Record was pressed and the take isn't live yet. */
  starting: boolean;
  /** The floating controls window (Document Picture-in-Picture) is open. */
  floatingOpen: boolean;
}

export interface BubblePolicy {
  /** page: floating over the dashboard · floating: inside the floating controls window · none. */
  host: "page" | "floating" | "none";
  /** Hidden only because a whole-screen take would record it (the dock says so). */
  hiddenForScreen: boolean;
}

/**
 * The Mac excludes its bubble from capture (`sharingType = .none`); a page
 * can't keep an element out of getDisplayMedia. A window or tab share of
 * something else never contains this page, so the bubble stays. A
 * whole-screen take WOULD record it — on top of camera.mov, which the editor
 * composites anyway — so it steps aside from Record until the take ends.
 * While the floating controls window is up (window/tab takes) the bubble
 * rides in it, above everything like the Mac's panel — one camera preview at
 * a time. After Stop the camera is released for the upload: nothing to show.
 */
export function bubblePolicy(s: BubblePolicyInput): BubblePolicy {
  if (!s.cameraOn || s.phase === "saving" || s.phase === "failed") return { host: "none", hiddenForScreen: false };
  const takeLive = s.starting || s.phase === "countdown" || s.phase === "recording";
  if (takeLive && s.surface === "monitor") return { host: "none", hiddenForScreen: true };
  if (takeLive && s.floatingOpen) return { host: "floating", hiddenForScreen: false };
  return { host: "page", hiddenForScreen: false };
}
