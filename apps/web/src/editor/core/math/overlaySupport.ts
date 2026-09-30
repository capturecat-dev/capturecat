/**
 * Shared support for the OVERLAY cluster ports (keystroke pill, curtain,
 * annotations, subtitles): CoreGraphics path primitives as element lists,
 * the draw-op vocabulary + a CGContext-shaped recorder, Services/
 * ContinuousRoundedRect.swift, Services/OklabGradient.swift (+ SRGBA),
 * Services/SwiftUIShadow.swift and Views/Editor/ClickRippleOverlay.swift
 * `TapRippleMath`.
 *
 * Locked to Swift by the golden-vector units `overlayPathPrimitives`,
 * `oklabGradientStops`, `annotationTapRipple`, and — through the recorder —
 * `keystrokeOverlayDrawRecipe` / `annotationDrawRecipe` (whose Swift side
 * proves real renderer pixels == replay(ops) pixels byte for byte).
 *
 * HOIST candidates (other clusters need them too): ContinuousRoundedRect,
 * cgRoundedRectPath / cgEllipsePath / cgRectPath, OklabGradient, TapRippleMath.
 *
 * # Path elements
 *
 * `["M",x,y]`, `["L",x,y]`, `["Q",cx,cy,x,y]`, `["C",c1x,c1y,c2x,c2y,x,y]`,
 * `["Z"]` — exactly the elements `CGPath.applyWithBlock` reports, in user
 * space. A renderer builds a Path2D / tessellates from these; fills use the
 * op's rule (non-zero unless `evenOdd`).
 *
 * # Draw ops (the recorder vocabulary)
 *
 * Ops replay a CGContext session in order. Semantics the GPU side must honour:
 * - `save`/`restore`: CG graphics-state stack (CTM, alpha, shadow, clip).
 * - `translate`/`scale`: CTM ← T · CTM (CGContext.translateBy/scaleBy).
 * - `alpha`: CGContext.setAlpha — multiplies every subsequent paint (and a
 *   transparency layer's composite) until restored.
 * - `beginLayer`/`endLayer`: CG transparency layer — draw into an offscreen,
 *   then composite it ONCE with the alpha + shadow that were current at
 *   `beginLayer` (so the shadow is cast by the finished group).
 * - `shadow`: CGContext.setShadow(offset:blur:color:). CG semantics
 *   (probe-verified): the offset is in the bitmap BASE space — device
 *   pixels, Y-UP, NOT transformed by the CTM (neither its flip nor its
 *   scale). In every raster of this cluster the CTM is a y-down flip, so a
 *   positive `offsetY` moves the shadow visually UP by `offsetY` device px
 *   (the SwiftUI-style annotation shadow, dy = +1·scale, therefore sits
 *   1·scale px ABOVE the shape on the Mac, preview and export alike).
 *   `blur` is in device pixels too (CG's blur ≈ a Gaussian with σ ≈
 *   blur/2); color null = no shadow.
 * - `fill` / `stroke` / `clip`: path + resolved state. Strokes carry
 *   width/cap/join/miterLimit/dash.
 * - `radialGradient`: CGContext.drawRadialGradient; `gradient.kind: "oklab"`
 *   is an OklabGradient two-colour ramp (sample it with `oklabSample`),
 *   `"stops"` interpolates in gamma-encoded sRGB (CGGradient default).
 * - `text` / `ctText`: CoreText draws (see the owning module's docs).
 */
// CG path primitives + continuous corners: single sources in styleSupport.ts /
// continuousRoundedRect.ts; this module only re-encodes them as tuples.
import { cgPathEllipse, cgPathRect, cgPathRoundedRect } from "./styleSupport";
import * as CRR from "./continuousRoundedRect";
import { toTuples } from "./pathElements";
import type { Point, Rect } from "../model/types";
import {
  concatTransform,
  identityTransform,
  maxX,
  maxY,
  midX,
  midY,
  minX,
  minY,
  rectHeight,
  rectWidth,
  scaleTransform,
  translationTransform,
  type AffineTransform,
} from "./geometry";
import { smax, smin } from "./swift";

// ── Path elements ────────────────────────────────────────────────────────────

export type PathEl =
  | ["M", number, number]
  | ["L", number, number]
  | ["Q", number, number, number, number]
  | ["C", number, number, number, number, number, number]
  | ["Z"];
export type PathElements = PathEl[];

/** Straight-alpha sRGB colour (CGColor(srgbRed:…) components). */
export interface RGBA {
  r: number;
  g: number;
  b: number;
  a: number;
}

export function rgba(r: number, g: number, b: number, a: number): RGBA {
  return { r, g, b, a };
}

/** CG's quarter-arc cubic constant (read back out of CGPath(roundedRect:) /
 * CGPath(ellipseIn:) elements). */
export const CG_ARC_KAPPA = 0.5522847498;

/** `CGPath(rect:)` — standardized rect, M → L → L → L → Z. */
export function cgRectPath(r: Rect): PathElements {
  return toTuples(cgPathRect(r));
}

/**
 * `CGPath(roundedRect:cornerWidth:cornerHeight:)` — circular corners (CG
 * arcs as cubics with CG_ARC_KAPPA). CG clamps each radius to half the
 * corresponding side; a zero radius is a plain rect. Element order (Y-up
 * reading): start mid-right, corner at (maxX,maxY), (minX,maxY),
 * (minX,minY), (maxX,minY). Negative radii trap in CG — callers never pass
 * them.
 */
export function cgRoundedRectPath(r: Rect, cornerWidth: number, cornerHeight: number): PathElements {
  return toTuples(cgPathRoundedRect(r, cornerWidth, cornerHeight));
}

/** `CGPath(ellipseIn:)` — four cubics from mid-right, Y-up counter-clockwise. */
export function cgEllipsePath(r: Rect): PathElements {
  return toTuples(cgPathEllipse(r));
}

/** `CGMutablePath.addLines(between:)` + `closeSubpath()`. */
export function closedPolygonPath(points: readonly Point[]): PathElements {
  const out: PathElements = [];
  points.forEach((p, i) => out.push(i === 0 ? ["M", p.x, p.y] : ["L", p.x, p.y]));
  out.push(["Z"]);
  return out;
}

// ── ContinuousRoundedRect (Services/ContinuousRoundedRect.swift) ────────────

export const ContinuousRoundedRect = {
  fullReach: 1.528665,
  aFull: 1.08849,
  bFull: 0.868407,
  aMin: 0.96,
  bMin: 0.82,
  endLong: 0.631494,
  endShort: 0.074911,
  midLong: 0.372824,
  midShort: 0.16906,
} as const;


/** `ContinuousRoundedRect.path(rect:cornerRadius:)` — Apple's continuous
 * ("squircle") corners, element-for-element SwiftUI's emission. */
export function continuousRoundedRectPath(rect: Rect, cornerRadius: number): PathElements {
  return toTuples(CRR.path(rect, cornerRadius));
}

/** `ContinuousRoundedRect.circularPath(rect:cornerRadius:)`. */
export function continuousCircularPath(rect: Rect, cornerRadius: number): PathElements {
  return toTuples(CRR.circularPath(rect, cornerRadius));
}

// ── SRGBA + OklabGradient (Services/OklabGradient.swift) ────────────────────

/** `OklabGradient.resolution` — stops per CGGradient ramp. */
// Single source: oklabGradient.ts (locked by oklabGradient / oklabGradientStops).
// These adapters only translate this module's RGBA {r,g,b,a} shape.
import * as Oklab from "./oklabGradient";

const toS = (c: RGBA): Oklab.SRGBA => ({ red: c.r, green: c.g, blue: c.b, alpha: c.a });
const fromS = (c: Oklab.SRGBA): RGBA => ({ r: c.red, g: c.green, b: c.blue, a: c.alpha });

export const OKLAB_RESOLUTION = Oklab.resolution;
export const oklabLinearize = Oklab.linearize;
export const oklabEncode = Oklab.encode;

/** sRGB → Oklab. */
export function oklab(c: RGBA): [number, number, number] {
  return Oklab.oklab(toS(c));
}

/** Oklab → sRGB (alpha 1 — the caller sets it). */
export function oklabToSRGB(lab: [number, number, number]): RGBA {
  return fromS(Oklab.srgb(lab));
}

/** OklabGradient.mix — premultiplied-in-Oklab blend, linear alpha. */
export function oklabMix(a: RGBA, b: RGBA, t: number): RGBA {
  return fromS(Oklab.mix(toS(a), toS(b), t));
}

export interface GradientStop {
  location: number;
  color: RGBA;
}

/** OklabGradient.sample(_:at:) */
export function oklabSample(stops: readonly GradientStop[], t: number): RGBA {
  return fromS(Oklab.sample(stops.map((s) => ({ location: s.location, color: toS(s.color) })), t));
}

/** OklabGradient.gradient(stops:) as the CGGradient stop table it builds. */
export function oklabGradientTable(stops: readonly GradientStop[]): { colors: RGBA[]; locations: number[] } | null {
  const table = Oklab.gradientTable(stops.map((s) => ({ location: s.location, color: toS(s.color) })));
  if (!table) return null;
  return { colors: table.map((e) => fromS(e.color)), locations: table.map((e) => e.location) };
}

// ── SwiftUIShadow (Services/SwiftUIShadow.swift) ────────────────────────────

/** SwiftUIShadow.blurFactor — single source: swiftUIShadow.ts. */
import { blurFactor as swiftUIShadowBlurFactor } from "./swiftUIShadow";
export const SWIFTUI_SHADOW_BLUR_FACTOR = swiftUIShadowBlurFactor;

/** `sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))` — the device scale both
 * SwiftUIShadow and TextLine's pixel snapping read off the CTM. */
export function deviceScale(ctm: AffineTransform): number {
  return Math.sqrt(Math.abs(ctm.a * ctm.d - ctm.b * ctm.c));
}

// ── TapRippleMath (Views/Editor/ClickRippleOverlay.swift) ───────────────────
// Single source: tapRippleMath.ts (locked by tapRippleProgress).
import { period as tapPeriod, progress as tapProgress, rippleDuration as tapRippleDuration } from "./tapRippleMath";

export const TapRippleMath = { period: tapPeriod, rippleDuration: tapRippleDuration } as const;

/** TapRippleMath.progress(elapsed:) — ripple progress 0…1, or null while resting. */
export function tapRippleProgress(elapsed: number): number | null {
  return tapProgress(elapsed);
}

// ── Draw ops + recorder ─────────────────────────────────────────────────────

export type LineCap = "butt" | "round" | "square";
export type LineJoin = "miter" | "round" | "bevel";

export type GradientSpec =
  | { kind: "stops"; colors: RGBA[]; locations: number[] }
  | { kind: "oklab"; from: RGBA; to: RGBA };

export type DrawOp =
  | { op: "save" }
  | { op: "restore" }
  | { op: "translate"; x: number; y: number }
  | { op: "scale"; x: number; y: number }
  | { op: "alpha"; alpha: number }
  | { op: "beginLayer" }
  | { op: "endLayer" }
  | { op: "shadow"; offsetX: number; offsetY: number; blur: number; color: RGBA | null }
  | { op: "fill"; path: PathElements; color: RGBA; evenOdd: boolean }
  | {
      op: "stroke";
      path: PathElements;
      color: RGBA;
      lineWidth: number;
      cap: LineCap;
      join: LineJoin;
      miterLimit: number;
      dash: number[] | null;
      dashPhase: number;
    }
  | { op: "clip"; path: PathElements; evenOdd: boolean }
  | {
      op: "radialGradient";
      gradient: GradientSpec;
      startCenter: Point;
      startRadius: number;
      endCenter: Point;
      endRadius: number;
      before: boolean;
      after: boolean;
    }
  | ({ op: "text" } & Record<string, unknown>)
  | ({ op: "ctText" } & Record<string, unknown>);

interface GState {
  fill: RGBA;
  stroke: RGBA;
  lineWidth: number;
  cap: LineCap;
  join: LineJoin;
  miterLimit: number;
  dash: number[] | null;
  dashPhase: number;
  ctm: AffineTransform;
}

/**
 * CGContext-shaped recorder: the TS twin of the Swift harness's `WVRecCtx`.
 * Ports call it exactly like the Swift renderers call CGContext; it tracks
 * the CG state (CTM, colours, line state) and emits self-contained `DrawOp`s.
 * The initial CTM is identity (a fresh CG bitmap context).
 */
export class RecordingContext {
  readonly ops: DrawOp[] = [];
  private gs: GState;
  private stack: GState[] = [];
  private path: PathElements = [];

  constructor(initialCTM: AffineTransform = identityTransform) {
    this.gs = {
      fill: rgba(0, 0, 0, 1),
      stroke: rgba(0, 0, 0, 1),
      lineWidth: 1,
      cap: "butt",
      join: "miter",
      miterLimit: 10,
      dash: null,
      dashPhase: 0,
      ctm: initialCTM,
    };
  }

  get ctm(): AffineTransform {
    return this.gs.ctm;
  }

  record(op: DrawOp): void {
    this.ops.push(op);
  }

  saveGState(): void {
    this.stack.push({ ...this.gs });
    this.ops.push({ op: "save" });
  }
  restoreGState(): void {
    const g = this.stack.pop();
    if (g) this.gs = g;
    this.ops.push({ op: "restore" });
  }
  translateBy(x: number, y: number): void {
    this.gs.ctm = concatTransform(translationTransform(x, y), this.gs.ctm);
    this.ops.push({ op: "translate", x, y });
  }
  scaleBy(x: number, y: number): void {
    this.gs.ctm = concatTransform(scaleTransform(x, y), this.gs.ctm);
    this.ops.push({ op: "scale", x, y });
  }
  setAlpha(alpha: number): void {
    this.ops.push({ op: "alpha", alpha });
  }
  beginTransparencyLayer(): void {
    this.ops.push({ op: "beginLayer" });
  }
  endTransparencyLayer(): void {
    this.ops.push({ op: "endLayer" });
  }
  setShadow(offsetX: number, offsetY: number, blur: number, color: RGBA | null): void {
    this.ops.push({ op: "shadow", offsetX, offsetY, blur, color });
  }
  setFillColor(c: RGBA): void {
    this.gs.fill = c;
  }
  setStrokeColor(c: RGBA): void {
    this.gs.stroke = c;
  }
  setLineWidth(w: number): void {
    this.gs.lineWidth = w;
  }
  setLineCap(cap: LineCap): void {
    this.gs.cap = cap;
  }
  setLineJoin(join: LineJoin): void {
    this.gs.join = join;
  }
  setLineDash(phase: number, lengths: number[]): void {
    this.gs.dash = lengths.length === 0 ? null : lengths.slice();
    this.gs.dashPhase = phase;
  }

  beginPath(): void {
    this.path = [];
  }
  move(p: Point): void {
    this.path.push(["M", p.x, p.y]);
  }
  addLine(p: Point): void {
    this.path.push(["L", p.x, p.y]);
  }
  closePath(): void {
    this.path.push(["Z"]);
  }
  addPath(els: PathElements): void {
    for (const e of els) this.path.push(e.slice() as PathEl);
  }
  addEllipse(r: Rect): void {
    this.addPath(cgEllipsePath(r));
  }

  private strokeOp(path: PathElements): DrawOp {
    const g = this.gs;
    return {
      op: "stroke",
      path,
      color: g.stroke,
      lineWidth: g.lineWidth,
      cap: g.cap,
      join: g.join,
      miterLimit: g.miterLimit,
      dash: g.dash,
      dashPhase: g.dashPhase,
    };
  }

  fillPath(evenOdd = false): void {
    this.ops.push({ op: "fill", path: this.path, color: this.gs.fill, evenOdd });
    this.path = [];
  }
  strokePath(): void {
    this.ops.push(this.strokeOp(this.path));
    this.path = [];
  }
  fillEllipse(r: Rect): void {
    this.ops.push({ op: "fill", path: cgEllipsePath(r), color: this.gs.fill, evenOdd: false });
    this.path = [];
  }
  strokeEllipse(r: Rect): void {
    this.ops.push(this.strokeOp(cgEllipsePath(r)));
    this.path = [];
  }
  clip(evenOdd = false): void {
    this.ops.push({ op: "clip", path: this.path, evenOdd });
    this.path = [];
  }
  drawRadialGradient(
    gradient: GradientSpec,
    startCenter: Point,
    startRadius: number,
    endCenter: Point,
    endRadius: number,
    before: boolean,
    after: boolean,
  ): void {
    this.ops.push({ op: "radialGradient", gradient, startCenter, startRadius, endCenter, endRadius, before, after });
  }
}
