/**
 * Area-average resampling of an 8-bit alpha plane — the segmentation path
 * shrinks the model's matte (shortest edge 512) to the mask track's
 * resolution (docs/camera-cutout.md §2). Each destination pixel is the
 * coverage-weighted mean of the source pixels its footprint overlaps, rounded
 * to the nearest byte; an enlargement degenerates to nearest-area sampling.
 * Pure — runs in the segmentation worker and in tests.
 */

interface Taps {
  start: Int32Array;
  count: Int32Array;
  weights: Float64Array;
  stride: number;
}

/** Per destination column/row: the source cells it overlaps and their overlap weights (normalized). */
function taps(src: number, dst: number): Taps {
  const scale = src / dst;
  const stride = Math.ceil(scale) + 2;
  const start = new Int32Array(dst);
  const count = new Int32Array(dst);
  const weights = new Float64Array(dst * stride);
  for (let d = 0; d < dst; d++) {
    const a = d * scale;
    const b = Math.min(src, (d + 1) * scale);
    const first = Math.floor(a);
    const last = Math.min(src - 1, Math.ceil(b) - 1);
    let total = 0;
    let n = 0;
    for (let s = first; s <= last && n < stride; s++, n++) {
      const w = Math.min(b, s + 1) - Math.max(a, s);
      weights[d * stride + n] = w > 0 ? w : 0;
      total += w > 0 ? w : 0;
    }
    start[d] = first;
    count[d] = n;
    if (total > 0) for (let k = 0; k < n; k++) weights[d * stride + k]! /= total;
  }
  return { start, count, weights, stride };
}

/** `src` (sw×sh) → a new dw×dh plane. */
export function resampleAlpha(src: Uint8Array, sw: number, sh: number, dw: number, dh: number, out?: Uint8Array): Uint8Array {
  if (src.length !== sw * sh) throw new Error(`resampleAlpha: ${src.length} bytes for ${sw}×${sh}`);
  const dst = out && out.length === dw * dh ? out : new Uint8Array(dw * dh);
  if (sw === dw && sh === dh) {
    dst.set(src);
    return dst;
  }
  const tx = taps(sw, dw);
  const ty = taps(sh, dh);
  // Horizontal pass into floats, then vertical.
  const mid = new Float64Array(dw * sh);
  for (let y = 0; y < sh; y++) {
    const row = y * sw;
    for (let x = 0; x < dw; x++) {
      let acc = 0;
      const s0 = tx.start[x]!;
      for (let k = 0; k < tx.count[x]!; k++) acc += src[row + s0 + k]! * tx.weights[x * tx.stride + k]!;
      mid[y * dw + x] = acc;
    }
  }
  for (let y = 0; y < dh; y++) {
    const s0 = ty.start[y]!;
    for (let x = 0; x < dw; x++) {
      let acc = 0;
      for (let k = 0; k < ty.count[y]!; k++) acc += mid[(s0 + k) * dw + x]! * ty.weights[y * ty.stride + k]!;
      dst[y * dw + x] = Math.max(0, Math.min(255, Math.round(acc)));
    }
  }
  return dst;
}
