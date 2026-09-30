/**
 * Port of Services/OklabGradient.swift — `SRGBA` plus the Oklab ramp every
 * native gradient in the app uses (SwiftUI-compatible: stops interpolate in
 * Oklab, alpha-weighted, alpha itself linear).
 *
 * Functions: `linearize`, `encode`, `oklab`, `srgb`, `mix`, `sample`, and
 * `gradientTable` (the 257-entry sRGB stop table `gradient(stops:)` feeds to
 * `CGGradient` — CoreGraphics then interpolates LINEARLY in gamma-encoded
 * sRGB between those dense stops). Constant `resolution`.
 *
 * Locked by the golden-vector units `oklabGradient` and `styleConstants`.
 *
 * GPU note: to reproduce a CG gradient drawn from this table, compute the
 * gradient parameter t (see backgroundGradientRenderer.ts), clamp to 0…1,
 * find the stop pair around t among locations k/256, and lerp the two stop
 * colours component-wise in sRGB (NOT in linear light, NOT in Oklab — the
 * Oklab curve is already baked into the table). Then quantise to 8 bits.
 * A 257×1 rgba texture with linear filtering (texel centres at k/256) does
 * exactly that.
 */
import type { CodableColor } from "../model/types";
import { smax, smin } from "./swift";

/** `SRGBA` — straight (un-premultiplied) sRGB + alpha. */
export interface SRGBA {
  red: number;
  green: number;
  blue: number;
  alpha: number;
}

/** `SRGBA(white:alpha:)` */
export function srgbaWhite(white: number, alpha = 1): SRGBA {
  return { red: white, green: white, blue: white, alpha };
}

/** `SRGBA(_ c: CodableColor)` — opacity → alpha. */
export function srgbaFromCodable(c: Pick<CodableColor, "red" | "green" | "blue" | "opacity">): SRGBA {
  return { red: c.red, green: c.green, blue: c.blue, alpha: c.opacity };
}

/** Stops per gradient table (the table has `resolution + 1` entries). */
export const resolution = 256;

export interface GradientStop {
  location: number;
  color: SRGBA;
}

/** `sample(_:at:)` — the colour SwiftUI would show at `t` along the ramp. */
export function sample(stops: readonly GradientStop[], t: number): SRGBA {
  if (stops.length === 0) return srgbaWhite(0, 0);
  const first = stops[0];
  const last = stops[stops.length - 1];
  if (t <= first.location) return first.color;
  if (t >= last.location) return last.color;
  for (let i = 0; i < stops.length - 1; i++) {
    const a = stops[i];
    const b = stops[i + 1];
    if (!(t >= a.location && t <= b.location)) continue;
    const span = b.location - a.location;
    const local = span > 0 ? (t - a.location) / span : 0;
    return mix(a.color, b.color, local);
  }
  return last.color;
}

/**
 * The stop table `gradient(stops:)` hands to CGGradient: locations `i/256`
 * for i in 0…256, colours `sample(stops, at:)`. null when `stops.length < 2`
 * (the Swift guard returns a nil CGGradient).
 */
export function gradientTable(stops: readonly GradientStop[]): GradientStop[] | null {
  if (!(stops.length >= 2)) return null;
  const out: GradientStop[] = [];
  for (let i = 0; i <= resolution; i++) {
    const t = i / resolution;
    out.push({ location: t, color: sample(stops, t) });
  }
  return out;
}

/** `gradient(from:to:)` table. */
export function gradientTableFromTo(from: SRGBA, to: SRGBA): GradientStop[] {
  return gradientTable([
    { location: 0, color: from },
    { location: 1, color: to },
  ])!;
}

/** `mix(_:_:_:)` — alpha-weighted (premultiplied) Oklab blend; alpha lerps. */
export function mix(a: SRGBA, b: SRGBA, t: number): SRGBA {
  const alpha = a.alpha + (b.alpha - a.alpha) * t;
  const wa = a.alpha * (1 - t);
  const wb = b.alpha * t;
  const sum = wa + wb;
  if (!(sum > 0)) return srgbaWhite(0, 0);
  const la = oklab(a);
  const lb = oklab(b);
  const lab: [number, number, number] = [
    (la[0] * wa + lb[0] * wb) / sum,
    (la[1] * wa + lb[1] * wb) / sum,
    (la[2] * wa + lb[2] * wb) / sum,
  ];
  const out = srgb(lab);
  out.alpha = alpha;
  return out;
}

/** sRGB EOTF (gamma-encoded → linear). */
export function linearize(c: number): number {
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

/** sRGB OETF (linear → gamma-encoded), clamped to 0…1 first. */
export function encode(c: number): number {
  const v = smax(0, smin(1, c));
  return v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
}

/** private `cbrt` — sign-preserving `pow(x, 1/3)` (NOT Math.cbrt: different ulps). */
function cbrt(x: number): number {
  return x < 0 ? -Math.pow(-x, 1.0 / 3.0) : Math.pow(x, 1.0 / 3.0);
}

/** sRGB → Oklab (Björn Ottosson's matrices). */
export function oklab(c: SRGBA): [number, number, number] {
  const r = linearize(c.red);
  const g = linearize(c.green);
  const b = linearize(c.blue);
  const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
  const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
  const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
  const l_ = cbrt(l);
  const m_ = cbrt(m);
  const s_ = cbrt(s);
  return [
    0.2104542553 * l_ + 0.793617785 * m_ - 0.0040720468 * s_,
    1.9779984951 * l_ - 2.428592205 * m_ + 0.4505937099 * s_,
    0.0259040371 * l_ + 0.7827717662 * m_ - 0.808675766 * s_,
  ];
}

/** Oklab → sRGB (alpha = 1; the caller sets it). */
export function srgb(lab: readonly [number, number, number]): SRGBA {
  const l_ = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2];
  const m_ = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2];
  const s_ = lab[0] - 0.0894841775 * lab[1] - 1.291485548 * lab[2];
  const l = l_ * l_ * l_;
  const m = m_ * m_ * m_;
  const s = s_ * s_ * s_;
  return {
    red: encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    green: encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    blue: encode(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
    alpha: 1,
  };
}
