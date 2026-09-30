/**
 * Darwin libm semantics the ports need (hoisted from the cursor cluster).
 *
 * Cursor-cluster support helpers that have no single Swift home.
 *
 * `chypot` — C `hypot(x, y)` exactly as Darwin's libm returns it (what Swift's
 * `hypot(CGFloat, CGFloat)` calls in ClickRippleOverlay's drag-run distance
 * and VideoExporter.shouldHideCursor). These distances feed `<=` / `<`
 * threshold decisions (discrete click vs drag, auto-hide), so the port must be
 * bit-exact, not merely close:
 *
 * - Darwin's hypot is NOT correctly rounded (≈8 % of results differ from the
 *   correctly-rounded value by 1 ulp), and JS `Math.hypot` differs from it in
 *   ≈22 % of cases. Empirically (the `cursorHypot` vectors, 20 000 pairs incl.
 *   subnormals, 1e±300, ±∞, NaN — 0 mismatches) Darwin computes
 *   `sqrt(fma(min, min, max * max))` with power-of-two range scaling.
 * - JS has no fma; `fma` below is the Boldo–Melquiond exact emulation
 *   (TwoProduct + TwoSum + one round-to-odd addition), which is correctly
 *   rounded for the operand ranges used here (max scaled into [1, 2)).
 *
 * Candidates for hoisting into core/math/swift.ts (hypot + fma).
 */

const scratch = new DataView(new ArrayBuffer(8));

/** Veltkamp split (2^27 + 1). */
function split(a: number): [number, number] {
  const c = 134217729 * a;
  const hi = c - (c - a);
  return [hi, a - hi];
}

/** Dekker TwoProduct: a·b = p + e exactly (no overflow/underflow). */
function twoProd(a: number, b: number): [number, number] {
  const p = a * b;
  const [ah, al] = split(a);
  const [bh, bl] = split(b);
  return [p, ah * bh - p + ah * bl + al * bh + al * bl];
}

/** Knuth TwoSum: a + b = s + e exactly. */
function twoSum(a: number, b: number): [number, number] {
  const s = a + b;
  const bb = s - a;
  return [s, a - (s - bb) + (b - bb)];
}

/** x + y rounded to ODD (sticky rounding for the final RN step). */
function addRoundToOdd(x: number, y: number): number {
  const [s, e] = twoSum(x, y);
  if (e === 0 || !Number.isFinite(s)) return s;
  scratch.setFloat64(0, s);
  if ((scratch.getUint32(4) & 1) === 1) return s;
  const bits = scratch.getBigUint64(0);
  // One ulp toward the discarded error (bit patterns are sign-magnitude).
  const awayFromZero = e > 0 === s > 0;
  scratch.setBigUint64(0, awayFromZero ? bits + 1n : bits - 1n);
  return scratch.getFloat64(0);
}

/** Correctly rounded a·b + c (Boldo & Melquiond 2008, Alg. 5.4). Exact for
 * finite operands whose product neither overflows nor has an underflowing
 * error term. */
export function fma(a: number, b: number, c: number): number {
  const [uh, ul] = twoProd(a, b);
  const [th, tl] = twoSum(c, ul);
  const [vh, vl] = twoSum(uh, th);
  return vh + addRoundToOdd(tl, vl);
}

function exponentOf(a: number): number {
  scratch.setFloat64(0, a);
  return ((scratch.getUint32(0) >>> 20) & 0x7ff) - 1023;
}

/** Darwin libm `hypot(x, y)` (±∞ wins over NaN, like IEEE). */
export function chypot(x: number, y: number): number {
  let a = Math.abs(x);
  let b = Math.abs(y);
  if (a === Infinity || b === Infinity) return Infinity;
  if (Number.isNaN(a) || Number.isNaN(b)) return Number.NaN;
  if (a < b) {
    const t = a;
    a = b;
    b = t;
  }
  if (a === 0) return 0;
  // Scale `a` into [1, 2) by an exact power of two (subnormals first
  // normalised by 2^64) so the squares can neither overflow nor underflow.
  let k = exponentOf(a);
  if (k === -1023) {
    a *= 2 ** 64;
    b *= 2 ** 64;
    const k2 = exponentOf(a);
    const s = 2 ** -k2;
    a *= s;
    b *= s;
    k = k2 - 64;
  } else {
    const s = 2 ** -k;
    a *= s;
    b *= s;
  }
  return Math.sqrt(fma(b, b, a * a)) * 2 ** k;
}
