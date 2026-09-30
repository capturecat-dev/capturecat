/**
 * Port of Services/TiltMath.swift (`enum TiltMath` + the
 * `CATransform3D.init(_ p: TiltMath.Homography)` extension) — ALL of it:
 * perspectiveDistance, introAmount, springStep, deviceSideOffset,
 * tiltStyleParams, tiltReturnParams, rampOutLead, rampOutScale,
 * coverZoomMultiplier, effectiveCoverZoom, Homography (identity,
 * init(CGAffineTransform), applied(to:), inverted(), concatenating(_:)),
 * projectionTransform, projectedPoint, and the CATransform3D 4×4 mapping.
 *
 * Locked to Swift by the golden-vector units `tiltMathScalars`,
 * `tiltMathStyleParams`, `tiltMathHomography` and `tiltMathProjection`
 * (WebVectors+CameraMotion.swift).
 *
 * `inout` translation: `tiltStyleParams` / `tiltReturnParams` MUTATE the
 * passed `TiltStyleMemory` object in place (Swift `inout (omega, damping)`).
 *
 * Sign conventions (Swift doc, preview Y-DOWN space): positive pitch tips the
 * TOP edge away from the viewer, positive yaw tips the RIGHT edge toward the
 * viewer, positive roll rotates clockwise.
 *
 * GPU note: the Homography is ROW-VECTOR (`(x, y, 1) · M`, perspective in the
 * third column). `caTransform3D(h)` is CoreAnimation's 4×4 (also row-vector);
 * `caTransform3DArray(h)` flattens it row-major, which is exactly WGSL's
 * column-major `mat4x4<f32>` layout for the equivalent column-vector matrix
 * (`clip = M * vec4(x, y, 0, 1)` — transpose(M_ca) stored column-major ==
 * M_ca stored row-major). The export's CI path instead maps the image corners
 * through `projectedPoint(..., yUp: true)` into CIPerspectiveTransform.
 */
import type { Point, Size, TiltRegion } from "../model/types";
import { zoomStyleDamping, zoomStyleOmegaMultiplier } from "../model/enums";
import { rotationTransform, translationTransform, type AffineTransform } from "./geometry";
import { smax, smin } from "./swift";
import { returnOmega } from "./zoomFocalMath";

/** `TiltMath.perspectiveDistance(for:)` — camera distance vs card size. */
export function perspectiveDistance(size: Size): number {
  return 2.0 * smax(size.width, size.height, 1);
}

/** `TiltMath.introAmount(at:animationDuration:)` — analytic damped-spring
 * intro envelope (1 at t ≤ 0 → 0). */
export function introAmount(time: number, animationDuration: number): number {
  if (!(time > 0)) return 1;
  const omega = 2.5 / smax(0.2, animationDuration);
  const zeta = 0.88;
  const dampedOmega = omega * Math.sqrt(1 - zeta * zeta);
  const amount =
    Math.exp(-zeta * omega * time) *
    (Math.cos(dampedOmega * time) + ((zeta * omega) / dampedOmega) * Math.sin(dampedOmega * time));
  return smax(0, smin(1, amount));
}

/** `TiltMath.springStep(_:response:damping:)` — analytic step response of
 * SwiftUI's `.spring(response:dampingFraction:)`. */
export function springStep(t: number, response: number, damping: number): number {
  if (!(t > 0)) return 0;
  const omega0 = (2 * Math.PI) / smax(0.05, response);
  const zeta = smin(0.999, smax(0.01, damping));
  const omegaD = omega0 * Math.sqrt(1 - zeta * zeta);
  const s =
    1 -
    Math.exp(-zeta * omega0 * t) *
      (Math.cos(omegaD * t) + ((zeta * omega0) / omegaD) * Math.sin(omegaD * t));
  return smin(1, smax(0, s));
}

/** `TiltMath.deviceSideOffset(pitchDegrees:yawDegrees:videoWidth:)` — Y-DOWN
 * preview space (the exporter negates height for CI's Y-up space). */
export function deviceSideOffset(pitchDegrees: number, yawDegrees: number, videoWidth: number): Size {
  const thickness = smax(6, videoWidth * 0.11);
  return {
    width: thickness * Math.sin((yawDegrees * Math.PI) / 180),
    height: thickness * Math.sin((pitchDegrees * Math.PI) / 180),
  };
}

/** Swift `inout (omega: Double, damping: Double)` spring-style memory. */
export interface TiltStyleMemory {
  omega: number;
  damping: number;
}

/** The initial memory both Swift consumers use: `(1, 0.88)`. */
export function makeTiltStyleMemory(): TiltStyleMemory {
  return { omega: 1, damping: 0.88 };
}

/** `TiltMath.tiltStyleParams(tiltRegions:at:memory:)` — MUTATES `memory`. */
export function tiltStyleParams(
  tiltRegions: readonly TiltRegion[],
  time: number,
  memory: TiltStyleMemory,
): TiltStyleMemory {
  for (const region of tiltRegions) {
    if (!(time >= region.startTime && time <= region.endTime)) continue;
    const style = region.animationStyle;
    memory.omega = style != null ? zoomStyleOmegaMultiplier(style) : 1;
    memory.damping = style != null ? zoomStyleDamping(style) : 0.88;
    return { omega: memory.omega, damping: memory.damping };
  }
  return { omega: memory.omega, damping: memory.damping };
}

export interface TiltReturnParams {
  omega: number;
  damping: number;
  returning: boolean;
}

/** `TiltMath.tiltReturnParams(tiltRegions:at:animationDuration:memory:)` —
 * MUTATES `memory`. */
export function tiltReturnParams(
  tiltRegions: readonly TiltRegion[],
  time: number,
  animationDuration: number,
  memory: TiltStyleMemory,
): TiltReturnParams {
  const style = tiltStyleParams(tiltRegions, time, memory);
  const region = tiltRegions.find((r) => time >= r.startTime && time <= r.endTime);
  if (region !== undefined) {
    const lead = rampOutLead(region.startTime, region.endTime, animationDuration);
    const rampStart = region.endTime - lead;
    if (!(time >= rampStart)) {
      return { omega: style.omega, damping: style.damping, returning: false };
    }
    return {
      omega: returnOmega(time, rampStart, lead, style.omega),
      damping: smin(style.damping, 0.95),
      returning: true,
    };
  }
  return { omega: smax(1.25, style.omega), damping: smin(style.damping, 0.95), returning: true };
}

/** `TiltMath.rampOutLead(blockStart:blockEnd:animationDuration:)` */
export function rampOutLead(blockStart: number, blockEnd: number, animationDuration: number): number {
  return smin(0.5 * smax(0, blockEnd - blockStart), smax(0.4, 1.8 * animationDuration));
}

/** `TiltMath.rampOutScale(time:blockStart:blockEnd:animationDuration:)` —
 * 1 → 0 smoothstep through the ramp-out window. */
export function rampOutScale(
  time: number,
  blockStart: number,
  blockEnd: number,
  animationDuration: number,
): number {
  const lead = rampOutLead(blockStart, blockEnd, animationDuration);
  const rampStart = blockEnd - lead;
  if (!(time > rampStart)) return 1;
  const p = smin(1, smax(0, (time - rampStart) / smax(0.0001, lead)));
  const eased = p * p * (3 - 2 * p);
  return 1 - eased;
}

/** `TiltMath.coverZoomMultiplier(pitchDegrees:yawDegrees:rollDegrees:aspect:)` */
export function coverZoomMultiplier(
  pitchDegrees: number,
  yawDegrees: number,
  rollDegrees: number,
  aspect: number,
): number {
  if (!(smax(Math.abs(pitchDegrees), Math.abs(yawDegrees), Math.abs(rollDegrees)) > 0.01)) return 1;
  const r = (Math.abs(rollDegrees) * Math.PI) / 180;
  const c = Math.cos(r);
  const s = Math.sin(r);
  const a = smax(0.1, aspect);
  const fx = c + s / a;
  const fy = c + s * a;
  let multiplier = smax(fx, fy);
  const pitchMargin = Math.cos(smin(1.0, (Math.abs(pitchDegrees) * Math.PI) / 180));
  const yawMargin = Math.cos(smin(1.0, (Math.abs(yawDegrees) * Math.PI) / 180));
  multiplier /= smax(0.5, pitchMargin);
  multiplier /= smax(0.5, yawMargin);
  return smin(2.5, multiplier);
}

/** `TiltMath.effectiveCoverZoom(zoom:pitchDegrees:yawDegrees:rollDegrees:aspect:)` */
export function effectiveCoverZoom(
  zoom: number,
  pitchDegrees: number,
  yawDegrees: number,
  rollDegrees: number,
  aspect: number,
): number {
  if (!(zoom > 1.001)) return zoom;
  const multiplier = coverZoomMultiplier(pitchDegrees, yawDegrees, rollDegrees, aspect);
  const progress = smin(1, (zoom - 1) / 0.6);
  const smooth = progress * progress * (3 - 2 * progress);
  return zoom * (1 + (multiplier - 1) * smooth);
}

// ── Homography ──────────────────────────────────────────────────────────────

/** `TiltMath.Homography` — 3×3 row-vector homography `(x, y, 1) · M`. */
export interface Homography {
  m11: number;
  m12: number;
  m13: number;
  m21: number;
  m22: number;
  m23: number;
  m31: number;
  m32: number;
  m33: number;
}

function identityHomography(): Homography {
  return { m11: 1, m12: 0, m13: 0, m21: 0, m22: 1, m23: 0, m31: 0, m32: 0, m33: 1 };
}

/** `Homography.init(_ t: CGAffineTransform)` */
function homographyFromAffine(t: AffineTransform): Homography {
  return { m11: t.a, m12: t.b, m13: 0, m21: t.c, m22: t.d, m23: 0, m31: t.tx, m32: t.ty, m33: 1 };
}

/** `Homography.applied(to:)` — with the perspective divide; returns `p`
 * unchanged when |w| ≤ 1e-6. */
function homographyApplied(h: Homography, p: Point): Point {
  const w = p.x * h.m13 + p.y * h.m23 + h.m33;
  if (!(Math.abs(w) > 0.000001)) return p;
  return {
    x: (p.x * h.m11 + p.y * h.m21 + h.m31) / w,
    y: (p.x * h.m12 + p.y * h.m22 + h.m32) / w,
  };
}

/** `Homography.inverted()` — adjugate / determinant; null when singular
 * (|det| ≤ 1e-9). */
function homographyInverted(h: Homography): Homography | null {
  const a = h.m11,
    b = h.m12,
    c = h.m13;
  const d = h.m21,
    e = h.m22,
    f = h.m23;
  const g = h.m31,
    hh = h.m32,
    i = h.m33;
  const det = a * (e * i - f * hh) - b * (d * i - f * g) + c * (d * hh - e * g);
  if (!(Math.abs(det) > 0.000000001)) return null;
  return {
    m11: (e * i - f * hh) / det,
    m12: (c * hh - b * i) / det,
    m13: (b * f - c * e) / det,
    m21: (f * g - d * i) / det,
    m22: (a * i - c * g) / det,
    m23: (c * d - a * f) / det,
    m31: (d * hh - e * g) / det,
    m32: (b * g - a * hh) / det,
    m33: (a * e - b * d) / det,
  };
}

/** `self.concatenating(o)` — `self` first, then `o` (row-vector `self · o`). */
function homographyConcatenating(s: Homography, o: Homography): Homography {
  return {
    m11: s.m11 * o.m11 + s.m12 * o.m21 + s.m13 * o.m31,
    m12: s.m11 * o.m12 + s.m12 * o.m22 + s.m13 * o.m32,
    m13: s.m11 * o.m13 + s.m12 * o.m23 + s.m13 * o.m33,
    m21: s.m21 * o.m11 + s.m22 * o.m21 + s.m23 * o.m31,
    m22: s.m21 * o.m12 + s.m22 * o.m22 + s.m23 * o.m32,
    m23: s.m21 * o.m13 + s.m22 * o.m23 + s.m23 * o.m33,
    m31: s.m31 * o.m11 + s.m32 * o.m21 + s.m33 * o.m31,
    m32: s.m31 * o.m12 + s.m32 * o.m22 + s.m33 * o.m32,
    m33: s.m31 * o.m13 + s.m32 * o.m23 + s.m33 * o.m33,
  };
}

/** `TiltMath.Homography` value-side API (mirrors the Swift struct's members). */
export const Homography = {
  /** `Homography.identity` (a fresh copy). */
  identity: identityHomography,
  /** `Homography.init(_ t: CGAffineTransform)` */
  fromAffine: homographyFromAffine,
  /** `h.applied(to: p)` */
  applied: homographyApplied,
  /** `h.inverted()` */
  inverted: homographyInverted,
  /** `h.concatenating(o)` */
  concatenating: homographyConcatenating,
} as const;

/** `TiltMath.projectionTransform(pitchDegrees:yawDegrees:rollDegrees:center:distance:)`
 * — roll → pitch/yaw about `center`, Y-DOWN space. */
export function projectionTransform(
  pitchDegrees: number,
  yawDegrees: number,
  rollDegrees: number,
  center: Point,
  distance: number,
): Homography {
  if (!(smax(Math.abs(pitchDegrees), Math.abs(yawDegrees), Math.abs(rollDegrees)) > 0.01)) {
    return identityHomography();
  }
  const sa = Math.sin((pitchDegrees * Math.PI) / 180);
  const ca = Math.cos((pitchDegrees * Math.PI) / 180);
  const sb = Math.sin((yawDegrees * Math.PI) / 180);
  const cb = Math.cos((yawDegrees * Math.PI) / 180);

  const m = identityHomography();
  m.m11 = cb;
  m.m21 = -sa * sb;
  m.m12 = 0;
  m.m22 = ca;
  m.m13 = -sb / distance;
  m.m23 = (-sa * cb) / distance;

  const roll = homographyFromAffine(rotationTransform((rollDegrees * Math.PI) / 180));
  const toCenter = homographyFromAffine(translationTransform(-center.x, -center.y));
  const fromCenter = homographyFromAffine(translationTransform(center.x, center.y));
  return homographyConcatenating(
    homographyConcatenating(homographyConcatenating(toCenter, roll), m),
    fromCenter,
  );
}

/** `TiltMath.projectedPoint(_:center:pitchDegrees:yawDegrees:rollDegrees:distance:yUp:)`
 * — `yUp: true` for Core Image (export) coordinates, false for Y-down. */
export function projectedPoint(
  point: Point,
  center: Point,
  pitchDegrees: number,
  yawDegrees: number,
  rollDegrees: number,
  distance: number,
  yUp: boolean,
): Point {
  const sa = Math.sin((pitchDegrees * Math.PI) / 180);
  const ca = Math.cos((pitchDegrees * Math.PI) / 180);
  const sb = Math.sin((yawDegrees * Math.PI) / 180);
  const cb = Math.cos((yawDegrees * Math.PI) / 180);
  const sg = Math.sin((rollDegrees * Math.PI) / 180);
  const cg = Math.cos((rollDegrees * Math.PI) / 180);

  const dx = point.x - center.x;
  const dy0 = point.y - center.y;
  const dy = yUp ? -dy0 : dy0;

  const x1 = dx * cg - dy * sg;
  const y1 = dx * sg + dy * cg;
  const w = 1 - (sb * x1) / distance - (sa * cb * y1) / distance;
  if (!(w > 0.01)) return point;
  const xOut = (x1 * cb - y1 * sa * sb) / w;
  const yOut = (y1 * ca) / w;

  return { x: center.x + xOut, y: center.y + (yUp ? -yOut : yOut) };
}

/** CoreAnimation `CATransform3D` field layout (row-vector, m41..m43 = translation). */
export interface CATransform3D {
  m11: number;
  m12: number;
  m13: number;
  m14: number;
  m21: number;
  m22: number;
  m23: number;
  m24: number;
  m31: number;
  m32: number;
  m33: number;
  m34: number;
  m41: number;
  m42: number;
  m43: number;
  m44: number;
}

/** `CATransform3D.init(_ p: TiltMath.Homography)` — identity, then
 * m13/m23 → m14/m24 (perspective), translation → m41/m42, m33 → m44. */
export function caTransform3D(p: Homography): CATransform3D {
  return {
    m11: p.m11,
    m12: p.m12,
    m13: 0,
    m14: p.m13,
    m21: p.m21,
    m22: p.m22,
    m23: 0,
    m24: p.m23,
    m31: 0,
    m32: 0,
    m33: 1,
    m34: 0,
    m41: p.m31,
    m42: p.m32,
    m43: 0,
    m44: p.m33,
  };
}

/** `caTransform3D(p)` flattened ROW-MAJOR (m11, m12, m13, m14, m21, …, m44) —
 * upload as-is for a WGSL `mat4x4<f32>` used as `M * vec4(x, y, z, 1)`. */
export function caTransform3DArray(p: Homography): number[] {
  const t = caTransform3D(p);
  return [
    t.m11, t.m12, t.m13, t.m14,
    t.m21, t.m22, t.m23, t.m24,
    t.m31, t.m32, t.m33, t.m34,
    t.m41, t.m42, t.m43, t.m44,
  ];
}
