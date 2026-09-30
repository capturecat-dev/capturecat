/**
 * Port of Services/CurtainUnveilMath.swift — the Curtain Unveil page peel:
 * `CurtainUnveilCorner.point`, motion curves (sweepEase, flapOverfoldRadians,
 * flapReleaseOffset, flapOpacityValue, shadowWidthFraction,
 * shadowStrengthValue), `state(corner:at:startTime:duration:)`, the
 * polygon helpers (reflect, polygonArea, clip, clipToUnitSquare and the
 * private reflect/foldEndpoints/centroid/revealedDirection/bandPolygon),
 * `cardClip` / `cardClipPath`, `coverStyle` / `coverStops`, and the draw
 * RECIPE of `renderImage` / `draw` as data.
 *
 * Locked to Swift by the golden-vector units `curtainUnveilCurves`,
 * `curtainUnveilState`, `curtainUnveilGeometry`, `curtainUnveilCardClip`,
 * `curtainUnveilCoverStyle` and `curtainUnveilDrawRecipe`. The recipe unit's
 * Swift side proves that replaying the recorded op list reproduces the REAL
 * `CurtainUnveilMath.renderImage` byte for byte.
 *
 * # Coordinate spaces — the ONE Y flip
 *
 * All State geometry and recipe polygons / gradient axes are in UNIT card
 * space (0…1, Y-DOWN, (0,0) = the card's visual top-left). Swift's `draw`
 * maps unit → its Y-UP CG raster with `(u.x · w, (1 − u.y) · h)` exactly
 * once; the CGImage it produces is placed on the card in CI (Y-up) space
 * as-is, i.e. its rows are in visual order. A Y-DOWN web raster therefore
 * maps unit → pixel as `(u.x · w, u.y · h)` with NO flip. The only non-unit
 * values in the recipe:
 * - `cardClip.path`: CGPath elements in the Y-UP raster (pixels); flip with
 *   `y ↦ h − y` for a Y-down raster.
 * - `radialGradient.endRadius`: pixels (`vignetteRadiusFraction · max(w,h)`).
 * - `logo.rect`: pixels, Y-UP raster (centred, so the flip only swaps which
 *   row is first; draw the logo upright in visual space).
 *
 * # Recipe ops (in order; each linear/radial op = clip to its polygon, then
 * draw the gradient; everything is inside the card clip)
 * - `cardClip {path}` — clip everything (rounded / squircle / device screen).
 * - `linearGradient {polygon, colors, locations, start, end, before, after}` —
 *   CGGradient in gamma-encoded sRGB (colours interpolate per channel in
 *   sRGB, straight alpha → premultiplied by CG); `before`/`after` = CG's
 *   drawsBefore/AfterStartLocation extension (else transparent outside
 *   [start, end]).
 * - `radialGradient {polygon, colors, locations, center, startRadius,
 *   endRadius, before, after}` — concentric radial (vignette).
 * - `logo {polygon, rect, alpha, tint}` — clip to polygon, setAlpha(alpha);
 *   tint → fill `rect` with `tint` through the logo's ALPHA mask; else draw
 *   the logo image into `rect`.
 * Target raster: `round(size)` pixels, premultiplied sRGB; the exporter
 * scales it back to the (fractional) video rect.
 */
import type { CodableColor, Point, ProjectSettings, Rect, Size } from "../model/types";
import type { CurtainUnveilCorner, FrameShape } from "../model/enums";
import { continuousRoundedRectPath, cgRoundedRectPath, type PathElements, type RGBA } from "./overlaySupport";
import { maxY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { smax, smin, srounded } from "./swift";

// ── Constants ────────────────────────────────────────────────────────────────

export const coverColorTop: RGBA = { r: 0x1c / 255, g: 0x1c / 255, b: 0x1e / 255, a: 1 };
export const coverColorBottom: RGBA = { r: 0x2c / 255, g: 0x2c / 255, b: 0x2e / 255, a: 1 };
export const flapColorNear: RGBA = { r: 0xf4 / 255, g: 0xf5 / 255, b: 0xf8 / 255, a: 1 };
export const flapColorFar: RGBA = { r: 0xd6 / 255, g: 0xd9 / 255, b: 0xe0 / 255, a: 1 };
export const foldShadowMaxOpacity = 0.35;
export const shadowBandFraction = 0.06;
export const coverDarkenFraction = 0.12;
export const sheenOpacity = 0.06;
export const sheenHalfWidth = 0.22;
export const vignetteOpacity = 0.1;
export const vignetteRadiusFraction = 0.95;
export const ambientShadowWidthFraction = 0.16;
export const ambientShadowMaxOpacity = 0.18;
export const foldSpecularOpacity = 0.45;
export const foldSpecularWidthFactor = 0.35;
export const flapSheenOpacity = 0.08;
export const flickStart = 0.6;
export const flickJoin = 0.3;
export const releaseSlope = 0.25;
export const releaseStart = 0.8;
export const releaseFadeWindow = 0.12;
export const baseOverfoldDegrees = 6;
export const whipOverfoldDegrees = 18;
export const releaseTravel = 0.18;
export const whipShadowBoost = 0.6;

const SQRT2 = Math.sqrt(2);

/** `RGBA.withAlpha(_:)` */
export function withAlpha(c: RGBA, alpha: number): RGBA {
  return { r: c.r, g: c.g, b: c.b, a: c.a * alpha };
}

/** `CurtainUnveilCorner.point` — starting corner in unit card space (Y-down). */
export function cornerPoint(corner: CurtainUnveilCorner): Point {
  switch (corner) {
    case "Off":
      return { x: 0, y: 0 };
    case "Top Left":
      return { x: 0, y: 0 };
    case "Top Right":
      return { x: 1, y: 0 };
    case "Bottom Left":
      return { x: 0, y: 1 };
    case "Bottom Right":
      return { x: 1, y: 1 };
  }
}

export const unitSquare: readonly Point[] = Object.freeze([
  { x: 0, y: 0 },
  { x: 1, y: 0 },
  { x: 1, y: 1 },
  { x: 0, y: 1 },
]);

// ── Motion curves ────────────────────────────────────────────────────────────

/** `CurtainUnveilMath.sweepEase(_:)` */
export function sweepEase(p0: number): number {
  const p = smax(0, smin(1, p0));
  const a = flickStart;
  const m = flickJoin;
  if (p <= a) {
    const q = p / a;
    return m * q * q * q;
  }
  const u = (p - a) / (1 - a);
  const d0 = ((3 * m) / a) * (1 - a) / (1 - m);
  const d1 = releaseSlope;
  const u2 = u * u;
  const u3 = u2 * u;
  const h = (u3 - 2 * u2 + u) * d0 + (-2 * u3 + 3 * u2) + (u3 - u2) * d1;
  return m + (1 - m) * h;
}

/** `CurtainUnveilMath.flapOverfoldRadians(_:)` */
export function flapOverfoldRadians(p0: number): number {
  const p = smax(0, smin(1, p0));
  const base = (baseOverfoldDegrees * Math.PI) / 180;
  if (p <= releaseStart) return base * Math.sin(((Math.PI / 2) * p) / releaseStart);
  const r = (p - releaseStart) / (1 - releaseStart);
  return base + ((whipOverfoldDegrees * Math.PI) / 180) * r * r;
}

/** `CurtainUnveilMath.flapReleaseOffset(_:)` */
export function flapReleaseOffset(p0: number): number {
  const p = smax(0, smin(1, p0));
  if (!(p > releaseStart)) return 0;
  const r = (p - releaseStart) / (1 - releaseStart);
  return releaseTravel * r * r;
}

/** `CurtainUnveilMath.flapOpacityValue(_:)` */
export function flapOpacityValue(p0: number): number {
  const p = smax(0, smin(1, p0));
  if (!(p > 1 - releaseFadeWindow)) return 1;
  return smax(0, (1 - p) / releaseFadeWindow);
}

/** `CurtainUnveilMath.shadowWidthFraction(_:)` */
export function shadowWidthFraction(p0: number): number {
  const p = smax(0, smin(1, p0));
  return shadowBandFraction * SQRT2 * (0.35 + 0.65 * Math.sin(Math.PI * p));
}

/** `CurtainUnveilMath.shadowStrengthValue(_:)` */
export function shadowStrengthValue(p0: number): number {
  const p = smax(0, smin(1, p0));
  const base = 1 - 0.4 * Math.sin(Math.PI * p);
  let whip = 1;
  if (p > releaseStart) {
    whip += whipShadowBoost * Math.sin((Math.PI * (p - releaseStart)) / (1 - releaseStart));
  }
  return base * whip * flapOpacityValue(p);
}

// ── Geometry helpers ─────────────────────────────────────────────────────────

function sub(a: Point, b: Point): Point {
  return { x: a.x - b.x, y: a.y - b.y };
}
function dot(a: Point, b: Point): number {
  return a.x * b.x + a.y * b.y;
}
function isZeroPoint(p: Point): boolean {
  return p.x === 0 && p.y === 0;
}

/** private `reflect(_:foldPoint:normal:)` */
function reflectAcrossFold(q: Point, f: Point, d: Point): Point {
  const s = dot(sub(q, f), d);
  return { x: q.x - 2 * s * d.x, y: q.y - 2 * s * d.y };
}

/** `CurtainUnveilMath.reflect(_:acrossLineThrough:_:)` */
export function reflect(p: Point, a: Point, b: Point): Point {
  const len = Math.hypot(b.x - a.x, b.y - a.y);
  if (!(len > 0.000001)) return p;
  const n = { x: -(b.y - a.y) / len, y: (b.x - a.x) / len };
  return reflectAcrossFold(p, a, n);
}

/** `CurtainUnveilMath.polygonArea(_:)` — absolute shoelace area. */
export function polygonArea(poly: readonly Point[]): number {
  if (poly.length < 3) return 0;
  let s = 0;
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i];
    const b = poly[(i + 1) % poly.length];
    s += a.x * b.y - b.x * a.y;
  }
  return Math.abs(s) / 2;
}

/** `CurtainUnveilMath.clip(_:keepWhere:)` — Sutherland–Hodgman against one
 * half-plane, keeping `signed(q) >= 0`. */
export function clip(poly: readonly Point[], signed: (q: Point) => number): Point[] {
  if (poly.length < 3) return [];
  const out: Point[] = [];
  for (let i = 0; i < poly.length; i++) {
    const a = poly[i];
    const b = poly[(i + 1) % poly.length];
    const sa = signed(a);
    const sb = signed(b);
    if (sa >= 0) out.push(a);
    if (sa >= 0 !== sb >= 0) {
      const t = sa / (sa - sb);
      out.push({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t });
    }
  }
  return out.length >= 3 ? out : [];
}

/** `CurtainUnveilMath.clipToUnitSquare(_:)` */
export function clipToUnitSquare(poly: readonly Point[]): Point[] {
  let out = poly.slice();
  out = clip(out, (q) => q.x);
  out = clip(out, (q) => 1 - q.x);
  out = clip(out, (q) => q.y);
  out = clip(out, (q) => 1 - q.y);
  return out;
}

/** private `foldEndpoints(foldPoint:normal:)` */
function foldEndpoints(f: Point, d: Point): [Point, Point] {
  const hits: Point[] = [];
  for (let i = 0; i < unitSquare.length; i++) {
    const a = unitSquare[i];
    const b = unitSquare[(i + 1) % unitSquare.length];
    const da = dot(sub(a, f), d);
    const db = dot(sub(b, f), d);
    if (Math.abs(da - db) < 0.0000001) continue;
    const t = da / (da - db);
    if (!(t >= -0.0000001 && t <= 1.0000001)) continue;
    const p = { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
    if (!hits.some((h) => Math.hypot(h.x - p.x, h.y - p.y) < 0.000001)) hits.push(p);
  }
  if (!(hits.length >= 2)) return [f, f];
  return [hits[0], hits[1]];
}

/** private `centroid(_:)` */
export function centroid(poly: readonly Point[]): Point {
  if (poly.length === 0) return { x: 0, y: 0 };
  let cx = 0;
  let cy = 0;
  for (const p of poly) {
    cx += p.x;
    cy += p.y;
  }
  return { x: cx / poly.length, y: cy / poly.length };
}

// ── State ────────────────────────────────────────────────────────────────────

/** `CurtainUnveilMath.State` */
export interface CurtainState {
  coverPolygon: Point[];
  flapPolygon: Point[];
  foldStart: Point;
  foldEnd: Point;
  shadowStrength: number;
  shadowWidth: number;
  flapOpacity: number;
  progress: number;
  active: boolean;
}

export function inactiveState(): CurtainState {
  return {
    coverPolygon: [],
    flapPolygon: [],
    foldStart: { x: 0, y: 0 },
    foldEnd: { x: 0, y: 0 },
    shadowStrength: 0,
    shadowWidth: 0,
    flapOpacity: 1,
    progress: 0,
    active: false,
  };
}

/** `CurtainUnveilMath.state(corner:at:startTime:duration:)` — OUTPUT time. */
export function state(corner: CurtainUnveilCorner, outputTime: number, startTime: number, duration: number): CurtainState {
  if (corner === "Off" || !(duration > 0.05)) return inactiveState();
  const rawP = (outputTime - startTime) / duration;
  if (!(rawP < 1)) return inactiveState();
  const p = smax(0, smin(1, rawP));
  const eased = sweepEase(p);

  const c = cornerPoint(corner);
  const opp = { x: 1 - c.x, y: 1 - c.y };
  const diagonal = SQRT2;
  const d = { x: (opp.x - c.x) / diagonal, y: (opp.y - c.y) / diagonal };
  const travel = eased * diagonal;
  const f = { x: c.x + d.x * travel, y: c.y + d.y * travel };

  const cover = clip(unitSquare, (q) => dot(sub(q, f), d));
  const revealed = clip(unitSquare, (q) => -dot(sub(q, f), d));
  let flap = revealed.map((q) => reflectAcrossFold(q, f, d));
  const overfold = flapOverfoldRadians(p);
  if (Math.abs(overfold) > 0.000001 && flap.length >= 3) {
    const cosA = Math.cos(overfold);
    const sinA = Math.sin(overfold);
    flap = flap.map((q) => {
      const dx = q.x - f.x;
      const dy = q.y - f.y;
      return { x: f.x + dx * cosA - dy * sinA, y: f.y + dx * sinA + dy * cosA };
    });
  }
  const slide = flapReleaseOffset(p);
  if (slide > 0.000001) flap = flap.map((q) => ({ x: q.x + d.x * slide, y: q.y + d.y * slide }));
  flap = clipToUnitSquare(flap);
  if (polygonArea(flap) < 0.000001) flap = [];

  const [fs, fe] = foldEndpoints(f, d);
  return {
    coverPolygon: cover,
    flapPolygon: flap,
    foldStart: fs,
    foldEnd: fe,
    shadowStrength: shadowStrengthValue(p),
    shadowWidth: shadowWidthFraction(p),
    flapOpacity: flapOpacityValue(p),
    progress: p,
    active: true,
  };
}

/** private `revealedDirection(state:)` — unit normal into the revealed half. */
export function revealedDirection(s: CurtainState): Point {
  const fd = { x: s.foldEnd.x - s.foldStart.x, y: s.foldEnd.y - s.foldStart.y };
  const len = Math.hypot(fd.x, fd.y);
  if (!(len > 0.000001)) return { x: 0, y: 0 };
  let n = { x: -fd.y / len, y: fd.x / len };
  if (!(s.coverPolygon.length >= 3)) return { x: 0, y: 0 };
  const mid = { x: (s.foldStart.x + s.foldEnd.x) / 2, y: (s.foldStart.y + s.foldEnd.y) / 2 };
  const toCover = sub(centroid(s.coverPolygon), mid);
  if (dot(toCover, n) > 0) n = { x: -n.x, y: -n.y };
  return n;
}

/** private `bandPolygon(state:width:)` */
function bandPolygon(s: CurtainState, width: number): Point[] {
  if (!(s.active && width > 0.000001)) return [];
  const dir = revealedDirection(s);
  if (isZeroPoint(dir)) return [];
  const poly = [
    s.foldStart,
    s.foldEnd,
    { x: s.foldEnd.x + dir.x * width, y: s.foldEnd.y + dir.y * width },
    { x: s.foldStart.x + dir.x * width, y: s.foldStart.y + dir.y * width },
  ];
  return clipToUnitSquare(poly);
}

/** `CurtainUnveilMath.shadowPolygon(state:)` — crease shadow band. */
export function shadowPolygon(s: CurtainState): Point[] {
  return bandPolygon(s, s.shadowWidth);
}

/** `CurtainUnveilMath.ambientShadowPolygon(state:)` — wide cast shadow. */
export function ambientShadowPolygon(s: CurtainState): Point[] {
  return bandPolygon(s, ambientShadowWidthFraction * SQRT2);
}

// ── Card clip ────────────────────────────────────────────────────────────────

/** `CurtainUnveilMath.CardClip` (fractions of the card). */
export interface CardClip {
  shape: "rectangle" | "rounded" | "squircle";
  cornerRadiusFraction: number;
  screenRectUnit: Rect | null;
  screenCornerRadiusFraction: number;
}

export function defaultCardClip(): CardClip {
  return { shape: "rectangle", cornerRadiusFraction: 0, screenRectUnit: null, screenCornerRadiusFraction: 0 };
}

/** `CurtainUnveilMath.cardClip(frameShape:cornerRadius:cardSize:deviceScreen:)`
 * — radius / device rect in the SAME units as `cardSize`. */
export function cardClip(
  frameShape: FrameShape,
  cornerRadius: number,
  cardSize: Size,
  deviceScreen: { rect: Rect; cornerRadius: number } | null,
): CardClip {
  const w = smax(1, cardSize.width);
  const h = smax(1, cardSize.height);
  const minDim = smin(w, h);
  if (deviceScreen) {
    return {
      shape: "squircle",
      cornerRadiusFraction: 0,
      screenRectUnit: {
        x: minX(deviceScreen.rect) / w,
        y: minY(deviceScreen.rect) / h,
        width: rectWidth(deviceScreen.rect) / w,
        height: rectHeight(deviceScreen.rect) / h,
      },
      screenCornerRadiusFraction: smax(0, deviceScreen.cornerRadius) / minDim,
    };
  }
  const r = smin(smax(0, cornerRadius), minDim / 2) / minDim;
  switch (frameShape) {
    case "Rectangle":
      return defaultCardClip();
    case "Rounded Rectangle":
      return { ...defaultCardClip(), shape: "rounded", cornerRadiusFraction: r };
    case "Squircle":
      return { ...defaultCardClip(), shape: "squircle", cornerRadiusFraction: r };
  }
}

/** `CurtainUnveilMath.cardClipPath(_:size:)` — CGPath elements in the Y-UP
 * raster (pixels); null = no clipping. */
export function cardClipPath(c: CardClip, size: Size): PathElements | null {
  const minDim = smin(size.width, size.height);
  const unit = c.screenRectUnit;
  if (unit) {
    const r: Rect = {
      x: minX(unit) * size.width,
      y: (1 - maxY(unit)) * size.height,
      width: rectWidth(unit) * size.width,
      height: rectHeight(unit) * size.height,
    };
    return continuousRoundedRectPath(r, c.screenCornerRadiusFraction * minDim);
  }
  const r = c.cornerRadiusFraction * minDim;
  if (!(r > 0.01)) return null;
  const rect: Rect = { x: 0, y: 0, width: size.width, height: size.height };
  switch (c.shape) {
    case "rectangle":
      return null;
    case "rounded":
      return cgRoundedRectPath(rect, r, r);
    case "squircle":
      return continuousRoundedRectPath(rect, r);
  }
}

// ── Cover style ──────────────────────────────────────────────────────────────

/** `CurtainUnveilMath.CoverStyle` — the logo is described by its pixel size. */
export interface CoverStyle {
  baseColor: RGBA | null;
  logoSize: Size | null;
  logoOpacity: number;
  logoScale: number;
  logoTint: RGBA | null;
  cardClip: CardClip | null;
}

export function defaultCoverStyle(): CoverStyle {
  return { baseColor: null, logoSize: null, logoOpacity: 1, logoScale: 0.25, logoTint: null, cardClip: null };
}

function colorRGBA(c: CodableColor): RGBA {
  return { r: c.red, g: c.green, b: c.blue, a: c.opacity };
}

/** `CurtainUnveilMath.coverStyle(settings:logo:cardClip:)` */
export function coverStyle(
  settings: Pick<ProjectSettings, "curtainColor" | "curtainLogoOpacity" | "curtainLogoScale" | "curtainLogoTint">,
  logoSize: Size | null,
  clip: CardClip | null = null,
): CoverStyle {
  return {
    baseColor: settings.curtainColor ? colorRGBA(settings.curtainColor) : null,
    logoSize,
    logoOpacity: settings.curtainLogoOpacity,
    logoScale: settings.curtainLogoScale,
    logoTint: settings.curtainLogoTint ? colorRGBA(settings.curtainLogoTint) : null,
    cardClip: clip,
  };
}

/** `CurtainUnveilMath.coverStops(base:)` */
export function coverStops(base: RGBA | null): { top: RGBA; bottom: RGBA } {
  if (!base) return { top: coverColorTop, bottom: coverColorBottom };
  const k = 1 - coverDarkenFraction;
  return { top: base, bottom: { r: base.r * k, g: base.g * k, b: base.b * k, a: base.a } };
}

// ── Draw recipe ──────────────────────────────────────────────────────────────

export type CurtainOp =
  | { op: "cardClip"; path: PathElements }
  | {
      op: "linearGradient";
      polygon: Point[];
      colors: RGBA[];
      locations: number[];
      start: Point;
      end: Point;
      before: boolean;
      after: boolean;
    }
  | {
      op: "radialGradient";
      polygon: Point[];
      colors: RGBA[];
      locations: number[];
      center: Point;
      startRadius: number;
      endRadius: number;
      before: boolean;
      after: boolean;
    }
  | { op: "logo"; polygon: Point[]; rect: Rect; alpha: number; tint: RGBA | null };

export interface CurtainRecipe {
  /** Raster size in pixels (`Int(size.rounded())`). */
  width: number;
  height: number;
  ops: CurtainOp[];
}

/** `CurtainUnveilMath.renderImage(state:size:style:)` + `draw` as data; null
 * when inactive or the raster would be empty. */
export function curtainRecipe(s: CurtainState, size: Size, style: CoverStyle = defaultCoverStyle()): CurtainRecipe | null {
  const w = Math.trunc(srounded(size.width));
  const h = Math.trunc(srounded(size.height));
  if (!(w > 0 && h > 0 && s.active)) return null;
  return { width: w, height: h, ops: curtainDrawOps(s, { width: w, height: h }, style) };
}

/** `CurtainUnveilMath.draw(state:in:size:style:)` as an ordered op list. */
export function curtainDrawOps(s: CurtainState, size: Size, style: CoverStyle = defaultCoverStyle()): CurtainOp[] {
  const ops: CurtainOp[] = [];
  if (!s.active) return ops;
  if (style.cardClip) {
    const clipPath = cardClipPath(style.cardClip, size);
    if (clipPath) ops.push({ op: "cardClip", path: clipPath });
  }
  const gradient = (colors: RGBA[], locations: number[]) => ({ colors, locations });
  const fill = (
    poly: Point[],
    g: { colors: RGBA[]; locations: number[] },
    from: Point,
    to: Point,
    extend = true,
  ) => {
    if (poly.length < 3) return;
    ops.push({
      op: "linearGradient",
      polygon: poly,
      colors: g.colors,
      locations: g.locations,
      start: from,
      end: to,
      before: extend,
      after: extend,
    });
  };

  const fade = s.flapOpacity;
  const mid = { x: (s.foldStart.x + s.foldEnd.x) / 2, y: (s.foldStart.y + s.foldEnd.y) / 2 };
  const revealDir = revealedDirection(s);
  const coverDir = ((): Point => {
    if (!isZeroPoint(revealDir)) return { x: -revealDir.x, y: -revealDir.y };
    if (!(s.coverPolygon.length >= 3)) return { x: 0, y: 0 };
    const c = centroid(s.coverPolygon);
    const v = { x: c.x - mid.x, y: c.y - mid.y };
    const len = Math.hypot(v.x, v.y);
    if (!(len > 0.000001)) return { x: 0, y: 0 };
    return { x: v.x / len, y: v.y / len };
  })();

  // Cover: base gradient, sheen band, vignette, logo.
  const stops = coverStops(style.baseColor);
  fill(s.coverPolygon, gradient([stops.top, stops.bottom], [0, 1]), { x: 0.5, y: 0 }, { x: 0.5, y: 1 });

  if (s.coverPolygon.length >= 3 && !isZeroPoint(coverDir)) {
    const clear = { r: 1, g: 1, b: 1, a: 0 };
    const lit = { r: 1, g: 1, b: 1, a: sheenOpacity };
    const drift = 0.3 + 0.4 * s.progress;
    const center = { x: mid.x + coverDir.x * drift, y: mid.y + coverDir.y * drift };
    fill(
      s.coverPolygon,
      gradient([clear, lit, clear], [0, 0.5, 1]),
      { x: center.x - coverDir.x * sheenHalfWidth, y: center.y - coverDir.y * sheenHalfWidth },
      { x: center.x + coverDir.x * sheenHalfWidth, y: center.y + coverDir.y * sheenHalfWidth },
      false,
    );

    // Swift `max(by:)` keeps the FIRST maximal element.
    let outer = s.coverPolygon[0];
    for (let i = 1; i < s.coverPolygon.length; i++) {
      const e = s.coverPolygon[i];
      if (dot(sub(outer, mid), coverDir) < dot(sub(e, mid), coverDir)) outer = e;
    }
    ops.push({
      op: "radialGradient",
      polygon: s.coverPolygon,
      colors: [
        { r: 0, g: 0, b: 0, a: vignetteOpacity },
        { r: 0, g: 0, b: 0, a: 0 },
      ],
      locations: [0, 1],
      center: outer,
      startRadius: 0,
      endRadius: vignetteRadiusFraction * smax(size.width, size.height),
      before: false,
      after: true,
    });
  }

  const logo = style.logoSize;
  if (
    logo &&
    style.logoOpacity > 0.001 &&
    style.logoScale > 0.001 &&
    logo.width > 0 &&
    logo.height > 0 &&
    s.coverPolygon.length >= 3
  ) {
    const lw = size.width * style.logoScale;
    const lh = (lw * logo.height) / logo.width;
    ops.push({
      op: "logo",
      polygon: s.coverPolygon,
      rect: { x: (size.width - lw) / 2, y: (size.height - lh) / 2, width: lw, height: lh },
      alpha: smax(0, smin(1, style.logoOpacity)),
      tint: style.logoTint,
    });
  }

  // Ambient cast shadow on the revealed content.
  const ambientPoly = ambientShadowPolygon(s);
  if (ambientPoly.length >= 3 && !isZeroPoint(revealDir) && s.shadowStrength > 0.001) {
    const a = ambientShadowMaxOpacity * smin(1, s.shadowStrength);
    fill(
      ambientPoly,
      gradient(
        [
          { r: 0, g: 0, b: 0, a },
          { r: 0, g: 0, b: 0, a: 0 },
        ],
        [0, 1],
      ),
      mid,
      {
        x: mid.x + revealDir.x * ambientShadowWidthFraction * SQRT2,
        y: mid.y + revealDir.y * ambientShadowWidthFraction * SQRT2,
      },
    );
  }

  // Page-back flap.
  if (s.flapPolygon.length >= 3 && fade > 0.001) {
    const c = centroid(s.flapPolygon);
    const dir = { x: c.x - mid.x, y: c.y - mid.y };
    const len = Math.hypot(dir.x, dir.y);
    if (len > 0.000001) {
      const n = { x: dir.x / len, y: dir.y / len };
      let far = 0.001;
      for (const p of s.flapPolygon) far = smax(far, (p.x - mid.x) * n.x + (p.y - mid.y) * n.y);
      fill(
        s.flapPolygon,
        gradient([withAlpha(flapColorNear, fade), withAlpha(flapColorFar, fade)], [0, 1]),
        mid,
        { x: mid.x + n.x * far, y: mid.y + n.y * far },
      );
      const foldDirLen = Math.hypot(s.foldEnd.x - s.foldStart.x, s.foldEnd.y - s.foldStart.y);
      if (foldDirLen > 0.000001) {
        const fdir = { x: (s.foldEnd.x - s.foldStart.x) / foldDirLen, y: (s.foldEnd.y - s.foldStart.y) / foldDirLen };
        const clear = { r: 1, g: 1, b: 1, a: 0 };
        const lit = { r: 1, g: 1, b: 1, a: flapSheenOpacity * fade };
        fill(
          s.flapPolygon,
          gradient([clear, lit, clear], [0, 0.5, 1]),
          { x: c.x - fdir.x * 0.25, y: c.y - fdir.y * 0.25 },
          { x: c.x + fdir.x * 0.25, y: c.y + fdir.y * 0.25 },
          false,
        );
      }
    }
  }

  // Crease shadow.
  const shadowPoly = shadowPolygon(s);
  if (shadowPoly.length >= 3 && !isZeroPoint(revealDir) && s.shadowStrength > 0.001) {
    const alpha = foldShadowMaxOpacity * s.shadowStrength;
    fill(
      shadowPoly,
      gradient(
        [
          { r: 0, g: 0, b: 0, a: alpha },
          { r: 0, g: 0, b: 0, a: 0 },
        ],
        [0, 1],
      ),
      mid,
      { x: mid.x + revealDir.x * s.shadowWidth, y: mid.y + revealDir.y * s.shadowWidth },
    );
  }

  // Fold specular on the flap side.
  if (s.flapPolygon.length >= 3 && !isZeroPoint(coverDir) && fade > 0.001 && s.shadowStrength > 0.001) {
    const w = s.shadowWidth * foldSpecularWidthFactor;
    const alpha = foldSpecularOpacity * smin(1, s.shadowStrength) * fade;
    ops.push({
      op: "linearGradient",
      polygon: s.flapPolygon,
      colors: [
        { r: 1, g: 1, b: 1, a: alpha },
        { r: 1, g: 1, b: 1, a: 0 },
      ],
      locations: [0, 1],
      start: mid,
      end: { x: mid.x + coverDir.x * w, y: mid.y + coverDir.y * w },
      before: false,
      after: true,
    });
  }
  return ops;
}
