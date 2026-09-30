/**
 * Colour math shared by the CPU reference and (as WGSL twins in
 * `gpu/shaders.ts`) the GPU passes.
 *
 * Ports:
 *  - `OklabGradient.mix / oklab / srgb / linearize / encode` (OklabGradient.swift)
 *  - `OklabGradient.resolution` = 256 stops: CoreGraphics interpolates the
 *    pre-sampled Oklab ramp LINEARLY in gamma sRGB between stops; the
 *    background pass does the same.
 *  - `BackgroundGradientRenderer.draw(in:rect:start:end:axis:)` — the
 *    gradient parameter `t` for `.diagonal` and `.angle(deg)` axes.
 *
 * Working space: the Mac export pipeline composites in the SOURCE's gamma-
 * encoded space (Display P3 for P3 recordings, sRGB otherwise — see
 * `VideoColorTags.renderColorSpace` and the `[Export Color]` logs). Synthetic
 * layers (background, shadow) are drawn in sRGB and converted into that
 * space; `srgbToWorking` is that conversion.
 */
import type { CodableColor } from "./contract";

export type WorkingSpace = "srgb" | "display-p3";

export interface SRGBA {
  r: number;
  g: number;
  b: number;
  a: number;
}

export function srgba(c: CodableColor): SRGBA {
  return { r: c.red, g: c.green, b: c.blue, a: c.opacity };
}

export const OKLAB_RESOLUTION = 256;

export function linearize(c: number): number {
  return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

export function encode(c: number): number {
  const v = Math.max(0, Math.min(1, c));
  return v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
}

function cbrt(x: number): number {
  return x < 0 ? -Math.pow(-x, 1 / 3) : Math.pow(x, 1 / 3);
}

export function oklab(c: SRGBA): [number, number, number] {
  const r = linearize(c.r);
  const g = linearize(c.g);
  const b = linearize(c.b);
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

export function oklabToSrgb(lab: [number, number, number]): [number, number, number] {
  const l_ = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2];
  const m_ = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2];
  const s_ = lab[0] - 0.0894841775 * lab[1] - 1.291485548 * lab[2];
  const l = l_ * l_ * l_;
  const m = m_ * m_ * m_;
  const s = s_ * s_ * s_;
  return [
    encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    encode(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
  ];
}

/** `OklabGradient.mix` — alpha-weighted Oklab blend, alpha travels linearly. */
export function oklabMix(a: SRGBA, b: SRGBA, t: number): SRGBA {
  const alpha = a.a + (b.a - a.a) * t;
  const wa = a.a * (1 - t);
  const wb = b.a * t;
  const sum = wa + wb;
  if (!(sum > 0)) return { r: 0, g: 0, b: 0, a: 0 };
  const la = oklab(a);
  const lb = oklab(b);
  const out = oklabToSrgb([
    (la[0] * wa + lb[0] * wb) / sum,
    (la[1] * wa + lb[1] * wb) / sum,
    (la[2] * wa + lb[2] * wb) / sum,
  ]);
  return { r: out[0], g: out[1], b: out[2], a: alpha };
}

/**
 * The colour CoreGraphics lays down at ramp parameter `t` for the 256-stop
 * `OklabGradient.gradient(from:to:)`: clamp (drawsBefore/AfterLocation), then
 * linear interpolation in straight-alpha gamma sRGB between the two
 * neighbouring pre-sampled Oklab stops.
 */
export function cgOklabRamp(a: SRGBA, b: SRGBA, t: number): SRGBA {
  const n = OKLAB_RESOLUTION;
  const tc = Math.max(0, Math.min(1, t));
  const i = Math.min(n - 1, Math.floor(tc * n));
  const f = tc * n - i;
  const c0 = oklabMix(a, b, i / n);
  const c1 = oklabMix(a, b, (i + 1) / n);
  return {
    r: c0.r + (c1.r - c0.r) * f,
    g: c0.g + (c1.g - c0.g) * f,
    b: c0.b + (c1.b - c0.b) * f,
    a: c0.a + (c1.a - c0.a) * f,
  };
}

/**
 * `BackgroundGradientRenderer` axis → linear-gradient parameter `t` at a
 * Y-DOWN point (pixel centre) in a `w × h` rect. Port notes:
 *  - `.diagonal`: p0 = top-left, p1 = bottom-right; CG's axial shading
 *    projects onto p0→p1, so t = dot(p, (w, h)) / (w² + h²).
 *  - `.angle(deg)`: Y-UP direction d = (sin θ, cos θ) (0° points up), the
 *    line spans |w·dx| + |h·dy| centred on the rect (CSS semantics). In
 *    Y-DOWN pixels d = (sin θ, −cos θ).
 */
export function gradientT(x: number, y: number, w: number, h: number, angleDeg: number | null): number {
  if (angleDeg === null) {
    return (x * w + y * h) / (w * w + h * h);
  }
  const theta = (angleDeg * Math.PI) / 180;
  const dx = Math.sin(theta);
  const dy = -Math.cos(theta);
  const length = Math.abs(w * dx) + Math.abs(h * dy);
  if (!(length > 0)) return 0;
  return ((x - w / 2) * dx + (y - h / 2) * dy) / length + 0.5;
}

/** Linear sRGB → linear Display P3 (both D65, no adaptation). */
export const SRGB_TO_P3: readonly number[] = [
  0.8224621, 0.177538, 0.0,
  0.0331941, 0.9668058, 0.0,
  0.0170827, 0.0723974, 0.9105199,
];

/** Straight-alpha encoded sRGB → straight-alpha encoded working space. */
export function srgbToWorking(c: [number, number, number], space: WorkingSpace): [number, number, number] {
  if (space === "srgb") return c;
  const r = linearize(c[0]);
  const g = linearize(c[1]);
  const b = linearize(c[2]);
  const m = SRGB_TO_P3;
  return [
    encode(m[0] * r + m[1] * g + m[2] * b),
    encode(m[3] * r + m[4] * g + m[5] * b),
    encode(m[6] * r + m[7] * g + m[8] * b),
  ];
}

/** 8-bit unorm storage (round-to-nearest, what an rgba8unorm write does). */
export function q8(v: number): number {
  return Math.round(Math.max(0, Math.min(1, v)) * 255) / 255;
}

/** `VideoColorPrimaries` from WebCodecs → working space (P3 only for smpte432). */
export function workingSpaceForPrimaries(primaries: string | null | undefined): WorkingSpace {
  return primaries === "smpte432" ? "display-p3" : "srgb";
}
