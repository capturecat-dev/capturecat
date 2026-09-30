/**
 * Port of Services/SwiftUIShadow.swift — the `CGContext.setShadow` parameters
 * that reproduce SwiftUI's `.shadow(radius:y:)` (used by the device bezel,
 * annotation and selection-chrome renderers).
 *
 * `apply(to:radius:dy:color:)` calls
 *   ctx.setShadow(offset: (0, dy), blur: radius · blurFactor · deviceScale, color)
 * with deviceScale = sqrt(|a·d − b·c|) of the context CTM: CG's shadow blur is
 * in DEVICE pixels (not transformed by the CTM) while SwiftUI's radius is in
 * points, and SwiftUI's radius ≈ blur / 2.2 (measured in `--raster-golden`).
 *
 * Locked by the golden-vector unit `swiftUIShadow` (verbatim oracle of the
 * two lines — CGContext has no shadow getter — CROSS-CHECKED at generation by
 * rendering a shape with the real `apply` and with `setShadow(oracle params)`
 * byte-for-byte) and `styleConstants` (`blurFactor`).
 *
 * GPU note: a CG shadow is the shape's alpha, blurred, tinted with `color`,
 * offset by `offset` and drawn under the shape. CG's `blur` is a blur extent
 * in device px, NOT a Gaussian sigma (the CI convention used elsewhere is
 * sigma ≈ SwiftUI radius / 2). `offset.height` is the SwiftUI `y:` value; the
 * Swift doc says it is positive-DOWN in the (flipped) contexts it is used
 * with — the web should apply it as +dy in Y-down space.
 *
 * Oddity (not fixed): `blurFactor` is a `static var` in Swift (mutable at
 * runtime); nothing mutates it, so it is ported as the constant 2.2.
 */
import type { AffineTransform } from "./geometry";
import type { SRGBA } from "./oklabGradient";

export const blurFactor = 2.2;

export interface ShadowParameters {
  deviceScale: number;
  offset: { width: number; height: number };
  blur: number;
  color: SRGBA;
}

/** `apply(to:radius:dy:color:)` as the setShadow parameters for a context with `ctm`. */
export function shadowParameters(ctm: AffineTransform, radius: number, dy: number, color: SRGBA): ShadowParameters {
  const deviceScale = Math.sqrt(Math.abs(ctm.a * ctm.d - ctm.b * ctm.c));
  return {
    deviceScale,
    offset: { width: 0, height: dy },
    blur: radius * blurFactor * deviceScale,
    color,
  };
}
