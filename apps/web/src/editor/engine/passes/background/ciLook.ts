/**
 * Measured CoreImage semantics of the background LOOK filters — the numbers
 * the GPU bake (backgroundBake.ts + shaders.ts) and its CPU reference
 * (testing/backgroundLookReference.ts) share, so the two cannot drift.
 *
 * Measured with a scratch CoreImage oracle (real CIFilters on synthetic
 * images) and asserted end-to-end against real Mac bitmaps by the
 * `backgroundLookStyledPixels` vectors (testing/backgroundLook.test.ts).
 */

/** CI's luma weights (CIColorControls saturation, CIDotScreen). */
export const CI_LUMA = [0.2125, 0.7154, 0.0721] as const;

/** CIDotScreen pattern gain at sharpness 0.7 (fitted: pattern slope = 0.9932 · s / (4(1 − s))). */
export const DOT_SCREEN_GAIN = 0.9932;

/** The only sharpness BackgroundLook uses. */
export const DOT_SCREEN_SHARPNESS = 0.7;

/** CIVignetteEffect falloff BackgroundLook uses; the ramp half-width is ½ + falloff. */
export const VIGNETTE_FALLOFF = 0.5;

/** sRGB EOTF / OETF (CI's working space is linear sRGB). */
export const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
export const enc = (c: number) => {
  const v = Math.max(0, Math.min(1, c));
  return v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
};

/**
 * CIGaussianBlur's effective sigma: an exact Gaussian for σ ≥ 2 (≤ 1/255);
 * below that CI's kernel is measurably wider — √(σ² + 0.09·clamp(2 − σ, 0, 1)).
 */
export function ciBlurSigma(sigma: number): number {
  const extra = 0.09 * Math.max(0, Math.min(1, 2 - sigma));
  return Math.sqrt(sigma * sigma + extra);
}

/** CIHueAdjust = the SVG/feColorMatrix hueRotate matrix (row-major), in linear light. */
export function hueMatrix(a: number): number[] {
  const c = Math.cos(a);
  const s = Math.sin(a);
  return [
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.14, 0.072 - c * 0.072 - s * 0.283,
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072,
  ];
}

/** CIVignetteEffect's radial ramp (fitted: smootherstep). */
export function smootherstep01(x: number): number {
  const t = Math.max(0, Math.min(1, x));
  return t * t * t * (t * (t * 6 - 15) + 10);
}

/** Round half to even (WGSL `round`, Metal `rint` — CIPixellate's block index). */
export function roundEven(v: number): number {
  const f = Math.floor(v);
  const d = v - f;
  if (d > 0.5) return f + 1;
  if (d < 0.5) return f;
  return f % 2 === 0 ? f : f + 1;
}
