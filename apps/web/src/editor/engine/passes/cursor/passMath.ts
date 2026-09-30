/**
 * Pure helpers shared by the cursor-layer passes (no GPU globals, so vitest
 * can load them): affine inverses for the WGSL uniforms, the card-quad
 * uniform block, and CoreImage's Gaussian kernel.
 */
import { invert, toRows, type Mat3 } from "../../mat3";
import type { AffineTransform } from "../../../core/math/geometry";

/** Rows of the inverse of a CG affine (x' = a·x + c·y + tx, y' = b·x + d·y + ty). */
export function inverseRows(t: AffineTransform): [number, number, number, number, number, number, number, number] {
  const det = t.a * t.d - t.b * t.c;
  if (!(Math.abs(det) > 1e-12)) return [0, 0, -1e9, 0, 0, 0, -1e9, 0];
  return [
    t.d / det, -t.c / det, (t.c * t.ty - t.d * t.tx) / det, 0,
    -t.b / det, t.a / det, (t.b * t.tx - t.a * t.ty) / det, 0,
  ];
}

/** Card-space quad uniform block (see shaders `Quad`). */
export function quadBlock(cardToTarget: Mat3, target: { width: number; height: number }, b: { x: number; y: number; w: number; h: number }): number[] {
  return [...toRows(cardToTarget), ...toRows(invert(cardToTarget)), target.width, target.height, 0, 0, b.x, b.y, b.w, b.h];
}

export function erf(x: number): number {
  // Abramowitz & Stegun 7.1.26 (|ε| ≤ 1.5e-7).
  const s = x < 0 ? -1 : 1;
  const a = Math.abs(x);
  const t = 1 / (1 + 0.3275911 * a);
  const y = 1 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-a * a);
  return s * y;
}

/**
 * CIGaussianBlur's discrete kernel for `sigma` (probed on macOS 26.2 with an
 * impulse: taps = the Gaussian integrated over each pixel, i.e.
 * ½[erf((k+½)/σ√2) − erf((k−½)/σ√2)], radius ceil(3σ); σ = 1 → 0.3828,
 * 0.2418, 0.0607, 0.0061). Returns weights for k = 0…radius.
 */
export function ciGaussianWeights(sigma: number): number[] {
  if (!(sigma > 0)) return [1];
  const r = Math.min(63, Math.ceil(3 * sigma));
  const k = 1 / (sigma * Math.SQRT2);
  const out: number[] = [];
  for (let i = 0; i <= r; i++) out.push(0.5 * (erf((i + 0.5) * k) - erf((i - 0.5) * k)));
  return out;
}


/**
 * CoreImage's pre-downsample for a strongly minified affine sample (probed on
 * macOS 26.2 with the exporter's own `transformed(by:)` chain and a Metal
 * CIContext): per SOURCE axis, while that axis' scale (the length of the
 * transform's column for it) is < 0.4375, CI first box-halves the image
 * along it — 2 px → 1, the odd pixel paired with transparent at the END of
 * the axis in CI's Y-up space — then samples bilinearly. One level matches CI
 * to ≤ 1/255 (scales 0.25…0.4375); a second level (< 0.21875, maxZoom ≳ 3)
 * is close but not exact (mean ≈ 0.15, max ≈ 80 on the sprite).
 */
export const CI_DOWNSAMPLE_BELOW = 0.4375;

export function ciDownsampleLevels(t: AffineTransform): { lx: number; ly: number } {
  let sx = Math.hypot(t.a, t.b);
  let sy = Math.hypot(t.c, t.d);
  let lx = 0;
  let ly = 0;
  while (sx > 0 && sx < CI_DOWNSAMPLE_BELOW && lx < 8) {
    sx *= 2;
    lx++;
  }
  while (sy > 0 && sy < CI_DOWNSAMPLE_BELOW && ly < 8) {
    sy *= 2;
    ly++;
  }
  return { lx, ly };
}

export interface SpriteLevel {
  /** Premultiplied RGBA in 0…255 floats, rows top-down. */
  data: Float32Array;
  width: number;
  height: number;
  /** Base texel (u, v from the top) → level texel: (u·sx, v·sy + oy). */
  sx: number;
  sy: number;
  oy: number;
}

/** `ciDownsampleLevels`' box-halvings of a premultiplied RGBA8 raster (top-down rows). */
export function spriteLevel(base: Uint8Array, width: number, height: number, lx: number, ly: number): SpriteLevel {
  let data = Float32Array.from(base);
  let w = width;
  let h = height;
  let sx = 1;
  let sy = 1;
  let oy = 0;
  for (let i = 0; i < lx; i++) {
    const w2 = Math.ceil(w / 2);
    const out = new Float32Array(w2 * h * 4);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w2; x++) {
        for (let k = 0; k < 4; k++) {
          const a = data[(y * w + 2 * x) * 4 + k];
          const b = 2 * x + 1 < w ? data[(y * w + 2 * x + 1) * 4 + k] : 0;
          out[(y * w2 + x) * 4 + k] = (a + b) / 2;
        }
      }
    }
    data = out;
    w = w2;
    sx /= 2;
  }
  for (let i = 0; i < ly; i++) {
    // CI Y-up: the odd row pairs with transparent above the TOP row.
    const h2 = Math.ceil(h / 2);
    const pad = 2 * h2 - h;
    const out = new Float32Array(w * h2 * 4);
    for (let y = 0; y < h2; y++) {
      const r0 = 2 * y - pad;
      const r1 = r0 + 1;
      for (let x = 0; x < w; x++) {
        for (let k = 0; k < 4; k++) {
          const a = r0 >= 0 ? data[(r0 * w + x) * 4 + k] : 0;
          const b = data[(r1 * w + x) * 4 + k];
          out[(y * w + x) * 4 + k] = (a + b) / 2;
        }
      }
    }
    data = out;
    h = h2;
    oy = (oy + pad) / 2;
    sy /= 2;
  }
  return { data, width: w, height: h, sx, sy, oy };
}
