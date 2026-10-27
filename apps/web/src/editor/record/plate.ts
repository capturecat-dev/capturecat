/**
 * The clean plate: how a whole-display take keeps the floating controls out
 * of its frames while they stay on screen for the person recording.
 *
 * The controls float in a Document Picture-in-Picture window (pip.ts), a
 * real window on the shared display, so a display capture contains it. Just
 * before that window opens, the take grabs one frame of the display with
 * none of the recorder UI on it: the plate. Every frame after that is drawn
 * again with the plate's pixels over the window's on-screen rect (plus its
 * shadow), which goes where the window goes. Content that changes under the
 * window shows stale there, so the UI tells people to park the controls over
 * a quiet corner.
 *
 *   display   which display the frames show, in the coordinates the window
 *             reports. Only knowable for sure with ONE display: with several,
 *             nothing says which one was shared or where it sits (that takes
 *             the Window Management permission), so the take falls back to
 *             hiding the bar and cutting (barHidden.ts "reveal").
 *   rect      window.screenX/screenY/outerWidth/outerHeight, polled, padded
 *             for the shadow, in 0…1 of the display, then in frame pixels:
 *             rounded outward to even coordinates (4:2:0 chroma), clamped.
 *   hold      every rect reported in the last RECT_HOLD_MS is painted (their
 *             bounding box). A frame shows the screen as it was a capture
 *             latency ago, so just after a move both places are covered.
 *   beacon    the window's content starts with a recording-red stripe over a
 *             near-black band (recorder-bar.tsx). Raw frames are checked for
 *             it: the window must be found inside the painted rect. A take
 *             floats its controls only once the first check passes (proof
 *             the mapping is right on this machine), and every failed check
 *             afterwards (a drag the reported position didn't follow, a
 *             window covered or off the display) is cut from the project like
 *             a reveal of the bar, from the last frame that passed.
 *
 * Pure: geometry, the composite as draw calls, the beacon search. The worker
 * (plateWorker.ts) runs them on frames; platePipeline.ts drives it.
 */

// ── the captured display ────────────────────────────────────────────────────

export interface Sized {
  width: number;
  height: number;
}

/** A display in the screen coordinate space window.screenX / screenY use (CSS px). */
export interface Display {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** What `window.screen` says about the display(s). */
export interface ScreenFacts {
  width: number;
  height: number;
  /** More than one display (Window Management API; Chrome, Edge). Undefined = the browser doesn't say. */
  isExtended?: boolean;
}

/** How far a frame's shape may drift from the display's and still be that display (scaling rounds). */
export const ASPECT_TOLERANCE = 0.02;

export function aspectMatches(a: Sized, b: Sized): boolean {
  if (!(a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0)) return false;
  return Math.abs(a.width / a.height / (b.width / b.height) - 1) <= ASPECT_TOLERANCE;
}

/**
 * The display a whole-screen share shows, in window coordinates, or null when
 * that isn't certain: more than one display (or a browser that doesn't say),
 * or frames that aren't that display's shape (cropped, letterboxed).
 */
export function capturedDisplay(screen: ScreenFacts, frame: Sized): Display | null {
  if (screen.isExtended !== false) return null;
  if (!aspectMatches(frame, screen)) return null;
  return { left: 0, top: 0, width: screen.width, height: screen.height };
}

// ── where the floating window is ────────────────────────────────────────────

/** The floating window as the browser reports it (CSS px, screen space). */
export interface WindowGeometry {
  /** screenX / screenY: the outer frame's top-left. */
  x: number;
  y: number;
  /** outerWidth / outerHeight. */
  width: number;
  height: number;
  /** innerWidth / innerHeight: the page inside the frame. */
  innerWidth: number;
  innerHeight: number;
}

export interface Insets {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/** Painted beyond the window's frame for its drop shadow (macOS casts it further down). CSS px. */
export const SHADOW_PAD: Insets = { left: 12, top: 10, right: 12, bottom: 20 };

/** How long a reported rect stays painted after the window has moved on (ms). */
export const RECT_HOLD_MS = 300;

/** A rect in 0…1 of the captured display (x right, y down). */
export interface UnitRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** A rect in whole frame pixels. */
export interface PixelRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export type PlateTarget =
  /** On the captured display: paint `rect`. */
  | { kind: "paint"; rect: UnitRect }
  /** Not on it (padded rect and display don't meet). */
  | { kind: "outside" }
  /** Geometry that can't be placed (zero size, NaN). */
  | { kind: "unknown" };

const finite = (...v: number[]) => v.every(Number.isFinite);

export function plateTarget(win: WindowGeometry, display: Display, pad: Insets = SHADOW_PAD): PlateTarget {
  if (!finite(win.x, win.y, win.width, win.height) || !(win.width > 0 && win.height > 0)) return { kind: "unknown" };
  if (!finite(display.left, display.top) || !(display.width > 0 && display.height > 0)) return { kind: "unknown" };
  const l = Math.max(win.x - pad.left, display.left);
  const t = Math.max(win.y - pad.top, display.top);
  const r = Math.min(win.x + win.width + pad.right, display.left + display.width);
  const b = Math.min(win.y + win.height + pad.bottom, display.top + display.height);
  if (!(r > l && b > t)) return { kind: "outside" };
  return {
    kind: "paint",
    rect: { x: (l - display.left) / display.width, y: (t - display.top) / display.height, w: (r - l) / display.width, h: (b - t) / display.height },
  };
}

const floorEven = (v: number) => 2 * Math.floor(v / 2);
const ceilEven = (v: number) => 2 * Math.ceil(v / 2);

/**
 * A unit rect in whole pixels of a `width`×`height` frame: outward to even
 * coordinates (a 4:2:0 chroma sample covers 2×2 pixels — an odd edge leaves a
 * half-tinted column), clamped to the frame. Null when nothing is left.
 */
export function toFramePixels(r: UnitRect, width: number, height: number): PixelRect | null {
  if (!finite(r.x, r.y, r.w, r.h) || !(width > 0 && height > 0)) return null;
  const x0 = Math.max(0, floorEven(r.x * width));
  const y0 = Math.max(0, floorEven(r.y * height));
  const x1 = Math.min(width, ceilEven((r.x + r.w) * width));
  const y1 = Math.min(height, ceilEven((r.y + r.h) * height));
  return x1 > x0 && y1 > y0 ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : null;
}

export function unionRect(a: UnitRect, b: UnitRect): UnitRect {
  const x = Math.min(a.x, b.x);
  const y = Math.min(a.y, b.y);
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
}

/** `r` grown by `by` on every side, in whole pixels, even-aligned and clamped to the frame. */
export function growPixels(r: PixelRect, by: number, frame: Sized): PixelRect | null {
  return toFramePixels(
    { x: (r.x - by) / frame.width, y: (r.y - by) / frame.height, w: (r.w + 2 * by) / frame.width, h: (r.h + 2 * by) / frame.height },
    frame.width,
    frame.height,
  );
}

/**
 * Rects reported over time (`set`, each current until the next); `at(t)` is
 * the bounding box of every rect that was current at some moment in
 * [t − holdMs, t] — null when none was.
 */
export class RectHold {
  private entries: Array<{ rect: UnitRect | null; from: number }> = [];

  constructor(readonly holdMs = RECT_HOLD_MS) {}

  set(rect: UnitRect | null, at: number): void {
    const last = this.entries.at(-1);
    if (last && sameRect(last.rect, rect)) return;
    this.entries.push({ rect, from: at });
  }

  at(t: number): UnitRect | null {
    const lo = t - this.holdMs;
    // Drop entries that ended before the window (keep the current one).
    while (this.entries.length > 1 && this.entries[1].from <= lo) this.entries.shift();
    let out: UnitRect | null = null;
    for (let i = 0; i < this.entries.length; i++) {
      const e = this.entries[i];
      if (e.from > t) break;
      const end = this.entries[i + 1]?.from ?? Infinity;
      if (end <= lo || !e.rect) continue;
      out = out ? unionRect(out, e.rect) : e.rect;
    }
    return out;
  }
}

function sameRect(a: UnitRect | null, b: UnitRect | null): boolean {
  if (!a || !b) return a === b;
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;
}

// ── the composite ───────────────────────────────────────────────────────────

/** What compositing needs of a 2D context (an OffscreenCanvasRenderingContext2D). */
export interface PlateCanvas<I> {
  drawImage(image: I, dx: number, dy: number, dw: number, dh: number): void;
  drawImage(image: I, sx: number, sy: number, sw: number, sh: number, dx: number, dy: number, dw: number, dh: number): void;
}

/**
 * One output frame: the live frame at `size`, then the plate's pixels over
 * `rect` (frame px). A plate of another size (the display changed resolution
 * mid-take) is scaled to the frame — stale either way, never the bar.
 */
export function composite<I>(ctx: PlateCanvas<I>, frame: I, size: Sized, plate: { image: I; width: number; height: number } | null, rect: PixelRect | null): void {
  ctx.drawImage(frame, 0, 0, size.width, size.height);
  if (!plate || !rect) return;
  const sx = plate.width / size.width;
  const sy = plate.height / size.height;
  ctx.drawImage(plate.image, rect.x * sx, rect.y * sy, rect.w * sx, rect.h * sy, rect.x, rect.y, rect.w, rect.h);
}

// ── the beacon ──────────────────────────────────────────────────────────────

/**
 * The top of the floating window's content (recorder-bar.tsx `PlateBeacon`):
 * `stripe` CSS px of recording red, then `band` CSS px of near-black.
 */
export const BEACON = { stripe: 4, band: 4, red: "#ff3b30", dark: "#050505" } as const;

/** Beacon red after a capture's colour handling (#ff3b30 arrives as roughly 230–255, 40–75, 30–60). */
export function isBeaconRed(r: number, g: number, b: number): boolean {
  return r >= 150 && r - Math.max(g, b) >= 80;
}

export function isBeaconDark(r: number, g: number, b: number): boolean {
  return Math.max(r, g, b) <= 64;
}

/** A found stripe, region pixels; `right` / `bottom` exclusive. */
export interface Stripe {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

/**
 * The topmost beacon in an RGBA region: a row with a run of red at least
 * `minRun` px long, the rows below it red across most of that run, then dark
 * across most of it. Null when there is none.
 */
export function findBeacon(px: ArrayLike<number>, width: number, height: number, minRun: number): Stripe | null {
  const run = Math.max(4, Math.ceil(minRun));
  const red = (x: number, y: number) => {
    const i = (y * width + x) * 4;
    return isBeaconRed(px[i], px[i + 1], px[i + 2]);
  };
  const dark = (x: number, y: number) => {
    const i = (y * width + x) * 4;
    return isBeaconDark(px[i], px[i + 1], px[i + 2]);
  };
  const share = (y: number, a: number, b: number, test: (x: number, y: number) => boolean) => {
    if (y < 0 || y >= height) return 0;
    let n = 0;
    let k = 0;
    const step = Math.max(1, Math.floor((b - a) / 48));
    for (let x = a; x < b; x += step, k++) if (test(x, y)) n++;
    return k ? n / k : 0;
  };
  for (let y = 0; y < height; y++) {
    // Longest red run in this row.
    let best = 0;
    let bestStart = 0;
    let start = -1;
    for (let x = 0; x <= width; x++) {
      if (x < width && red(x, y)) {
        if (start < 0) start = x;
      } else if (start >= 0) {
        if (x - start > best) {
          best = x - start;
          bestStart = start;
        }
        start = -1;
      }
    }
    if (best < run) continue;
    const left = bestStart;
    const right = bestStart + best;
    let bottom = y + 1;
    while (bottom < height && share(bottom, left, right, red) >= 0.8) bottom++;
    // Dark right under it (one row of anti-aliasing allowed).
    if (Math.max(share(bottom, left, right, dark), share(bottom + 1, left, right, dark)) >= 0.7) {
      return { left, right, top: y, bottom };
    }
  }
  return null;
}

export type PlacementVerdict = "ok" | "missing" | "outside";

/**
 * Is the floating window inside what this frame had painted over it? `px` is
 * the RAW frame's RGBA over `region` (frame px). The beacon must be there,
 * about as wide as the window's content, and the window it implies — the
 * stripe widened by the frame's side borders, raised by its title bar,
 * `outerHeight` tall — must lie inside `painted`. Ends of the stripe at a
 * frame edge are the window running off the display (only its visible part
 * has to be inside).
 */
export function verifyPlacement(a: {
  px: ArrayLike<number>;
  region: PixelRect;
  painted: PixelRect;
  frame: Sized;
  /** Frame px per CSS px. */
  scale: number;
  geom: WindowGeometry;
}): PlacementVerdict {
  const { region, painted, frame, scale, geom } = a;
  const side = Math.max(0, (geom.width - geom.innerWidth) / 2);
  const top = Math.max(0, geom.height - geom.innerHeight - side);
  const stripeW = geom.innerWidth * scale;
  const visible = Math.min(stripeW, painted.w);
  const found = findBeacon(a.px, region.w, region.h, visible * 0.5);
  if (!found) return "missing";
  const fl = region.x + found.left;
  const fr = region.x + found.right;
  const atLeftEdge = fl <= 1;
  const atRightEdge = fr >= frame.width - 1;
  const width = fr - fl;
  // Only a window running off the display may show a shorter stripe; never a longer one.
  if (width > stripeW * 1.08 + 4) return "missing";
  if (!atLeftEdge && !atRightEdge && width < stripeW * 0.9 - 4) return "missing";
  const winTop = region.y + found.top - top * scale;
  const win = {
    l: atLeftEdge ? 0 : fl - side * scale,
    r: atRightEdge ? frame.width : fr + side * scale,
    t: Math.max(0, winTop),
    b: Math.min(frame.height, winTop + geom.height * scale),
  };
  const tol = 2;
  const inside =
    win.l >= painted.x - tol &&
    win.r <= painted.x + painted.w + tol &&
    win.t >= painted.y - tol &&
    win.b <= painted.y + painted.h + tol;
  return inside ? "ok" : "outside";
}

/**
 * The raw-frame region a check reads: the rows of the painted rect where the
 * beacon of a window inside it can be (its top band; taller while a move
 * stretches the painted rect), grown by `margin` frame px — even-aligned and
 * clamped. A window that left the rect leaves its beacon outside.
 */
export function checkRegion(painted: PixelRect, geom: WindowGeometry, scale: number, margin: number, frame: Sized): PixelRect | null {
  const side = Math.max(0, (geom.width - geom.innerWidth) / 2);
  const titleBar = Math.max(0, geom.height - geom.innerHeight - side);
  const beaconRows = (titleBar + BEACON.stripe + BEACON.band + 4) * scale;
  const h = Math.min(painted.h, Math.max(painted.h - geom.height * scale, 0) + beaconRows);
  return growPixels({ x: painted.x, y: painted.y, w: painted.w, h }, margin, frame);
}

// ── the worker's protocol ───────────────────────────────────────────────────

export type PlateToWorker =
  | {
      type: "start";
      readable: ReadableStream<VideoFrame>;
      writable: WritableStream<VideoFrame>;
      plate: ImageBitmap;
      display: Display;
      /** DEV-only gate defects: "off" = no plate painted; "no-hold" = only the latest rect. */
      defect: string | null;
    }
  /** The latest window geometry (null: no window on screen), `at` epoch ms. `extended`: the display layout changed to several. */
  | { type: "geom"; geom: WindowGeometry | null; at: number; display: Display; extended: boolean }
  | { type: "settle"; id: number }
  | { type: "stop" };

export type PlateFromWorker =
  | { type: "tick" }
  /** The window was not where it was painted from the frame that arrived at `at` (epoch ms, exclusive of good frames before it). */
  | { type: "lost"; at: number; verdict: PlacementVerdict | "unplaceable" }
  /** …and is again, from the frame at `at`. */
  | { type: "found"; at: number }
  | { type: "settled"; id: number }
  | { type: "stats"; frames: number; painted: number; checks: number; failed: number; maxMs: number; meanMs: number }
  | { type: "error"; message: string };
