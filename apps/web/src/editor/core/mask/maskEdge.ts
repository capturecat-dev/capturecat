/**
 * Edge inset (erosion) and softness (feather) for a decoded person-mask
 * frame — docs/camera-cutout.md §12.4, the twin of
 * apps/macos/CaptureCat/Services/CameraMaskEdge.swift. Pure integer
 * arithmetic, so both sides produce the SAME bytes (locked by the
 * `cameraMaskEdge` golden-vector unit). The renderer runs every decoded mask
 * frame (frame 0 under the poster too) through `processMaskEdge` before it
 * becomes alpha, for both looks.
 *
 *   k = height / 192                                 (mask rows → radius scale)
 *   i = round(clamp(inset, 0, 1) × 6 × k)            (round half up; inputs ≥ 0)
 *   s = round(clamp(softness, 0, 1) × 6 × k)
 *   i = 0 and s = 0 → the frame unchanged
 *   erode (i > 0):  rows then columns, out[x] = min(in[clamp(x + d)]), d ∈ [−i, i]
 *   soften (s > 0): box blur rows, columns, rows, columns,
 *                   out[x] = (Σ in[clamp(x + d)], d ∈ [−s, s], + s) ÷ (2s + 1)
 *   clamp(j) = min(max(j, 0), n − 1); erode first, then soften.
 */
import { smax, smin } from "../math/swift";

/** Radius at 1.0, in mask pixels at the producer's 192 rows. */
export const maskEdgeMaxRadius = 6;
export const maskEdgeReferenceRows = 192;

/** `radii(height:softness:inset:)` — (inset, softness) radii in mask pixels for a mask `height` rows tall. */
export function maskEdgeRadii(height: number, softness: number, inset: number): { inset: number; softness: number } {
  const k = height / maskEdgeReferenceRows;
  // Swift `Double.rounded()` (ties away from zero) = Math.round for inputs ≥ 0.
  const r = (v: number) => Math.round(smin(1, smax(0, v)) * maskEdgeMaxRadius * k);
  return { inset: r(inset), softness: r(softness) };
}

/**
 * `process(_:width:height:softness:inset:)` — erode by the inset radius, then
 * box-blur twice each way by the softness radius. Returns `alpha` itself
 * when both radii are 0 (or the frame is malformed); otherwise a new array.
 */
export function processMaskEdge(alpha: Uint8Array, width: number, height: number, softness: number, inset: number): Uint8Array {
  if (!(width > 0 && height > 0) || alpha.length !== width * height) return alpha;
  const { inset: i, softness: s } = maskEdgeRadii(height, softness, inset);
  if (!(i > 0 || s > 0)) return alpha;
  let a = alpha;
  const lineIn = new Uint8Array(Math.max(width, height));
  const lineOut = new Uint8Array(Math.max(width, height));
  if (i > 0) {
    a = pass(a, width, height, true, lineIn, lineOut, (src, dst, n) => minimum(src, dst, n, i));
    a = pass(a, width, height, false, lineIn, lineOut, (src, dst, n) => minimum(src, dst, n, i));
  }
  if (s > 0) {
    for (let k = 0; k < 2; k++) {
      a = pass(a, width, height, true, lineIn, lineOut, (src, dst, n) => box(src, dst, n, s));
      a = pass(a, width, height, false, lineIn, lineOut, (src, dst, n) => box(src, dst, n, s));
    }
  }
  return a;
}

type Line = (src: Uint8Array, dst: Uint8Array, n: number) => void;

/** Runs `line` over every row (horizontal) or column of the frame into a new array. */
function pass(a: Uint8Array, width: number, height: number, horizontal: boolean, src: Uint8Array, dst: Uint8Array, line: Line): Uint8Array {
  const out = new Uint8Array(a.length);
  if (horizontal) {
    for (let y = 0; y < height; y++) {
      const o = y * width;
      for (let x = 0; x < width; x++) src[x] = a[o + x]!;
      line(src, dst, width);
      for (let x = 0; x < width; x++) out[o + x] = dst[x]!;
    }
  } else {
    for (let x = 0; x < width; x++) {
      for (let y = 0; y < height; y++) src[y] = a[y * width + x]!;
      line(src, dst, height);
      for (let y = 0; y < height; y++) out[y * width + x] = dst[y]!;
    }
  }
  return out;
}

/** out[x] = min(in[clamp(x + d)]) for d ∈ [−r, r] (clamp-to-edge). */
function minimum(line: Uint8Array, out: Uint8Array, n: number, r: number): void {
  for (let x = 0; x < n; x++) {
    let m = 255;
    for (let d = -r; d <= r; d++) {
      const v = line[Math.min(Math.max(x + d, 0), n - 1)]!;
      if (v < m) m = v;
    }
    out[x] = m;
  }
}

/** out[x] = (Σ in[clamp(x + d)] for d ∈ [−r, r] + r) ÷ (2r + 1) — a running sum over the clamped window. */
function box(line: Uint8Array, out: Uint8Array, n: number, r: number): void {
  const window = 2 * r + 1;
  let sum = 0;
  for (let d = -r; d <= r; d++) sum += line[Math.min(Math.max(d, 0), n - 1)]!;
  for (let x = 0; x < n; x++) {
    out[x] = Math.trunc((sum + r) / window);
    sum += line[Math.min(x + r + 1, n - 1)]! - line[Math.max(x - r, 0)]!;
  }
}
