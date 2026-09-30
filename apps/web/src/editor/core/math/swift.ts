/**
 * Swift standard-library semantics that JavaScript does NOT share.
 *
 * Every port in core/ MUST use these instead of the JS builtins where the
 * Swift source uses the Swift function — the golden vectors include NaN, -0,
 * ties and empty inputs precisely to catch the differences:
 *
 * - `min`/`max`: Swift returns an operand by comparison (`y < x ? y : x`,
 *   `y >= x ? y : x`), so NaN and -0 behave differently from Math.min/max
 *   (which propagate NaN and order -0 < +0).
 * - `rounded()`: Swift's default is schoolbook (ties AWAY from zero);
 *   Math.round rounds ties toward +∞ (−2.5 → −2 in JS, −3 in Swift).
 * - `String(format: "%.Nf")`: printf rounds the EXACT binary value with ties
 *   to even; `Number.prototype.toFixed` breaks exact ties upward.
 * - `Sequence.max()/min()` scan semantics.
 */

/** Swift `min(x, y)` — `y < x ? y : x`. */
export function smin(x: number, y: number, ...rest: number[]): number {
  let m = y < x ? y : x;
  if (rest.length === 0) return m;
  // Swift variadic: `var minValue = min(min(x, y), z); for v in rest where v < minValue`
  for (const v of rest) if (v < m) m = v;
  return m;
}

/** Swift `max(x, y)` — `y >= x ? y : x`. */
export function smax(x: number, y: number, ...rest: number[]): number {
  let m = y >= x ? y : x;
  if (rest.length === 0) return m;
  // Swift variadic: `var maxValue = max(max(x, y), z); for v in rest where v >= maxValue`
  for (const v of rest) if (v >= m) m = v;
  return m;
}

/** `max(lo, min(hi, v))` exactly as Swift evaluates it. */
export function sclamp(v: number, lo: number, hi: number): number {
  return smax(lo, smin(hi, v));
}

/** Swift `Double.rounded()` (toNearestOrAwayFromZero). */
export function srounded(x: number): number {
  if (!Number.isFinite(x)) return x;
  // Math.round on |x| breaks ties upward == away from zero for |x|.
  const a = Math.round(Math.abs(x));
  return x < 0 || Object.is(x, -0) ? -a : a;
}

/** C `round()` (Foundation) is the same ties-away rule as `rounded()`. */
export const cround = srounded;

/** Swift `Double.rounded(.toNearestOrEven)` / C `rint` (banker's rounding). */
export function sroundedEven(x: number): number {
  if (!Number.isFinite(x)) return x;
  const f = Math.floor(x);
  const d = x - f;
  let r: number;
  if (d < 0.5) r = f;
  else if (d > 0.5) r = f + 1;
  else r = f % 2 === 0 ? f : f + 1;
  return r === 0 && (x < 0 || Object.is(x, -0)) ? -0 : r;
}

/** Swift `Sequence.max()` for numbers (nil when empty). */
export function seqMax(xs: readonly number[]): number | null {
  if (xs.length === 0) return null;
  let result = xs[0];
  for (let i = 1; i < xs.length; i++) if (result < xs[i]) result = xs[i];
  return result;
}

/** Swift `Sequence.min()` for numbers (nil when empty). */
export function seqMin(xs: readonly number[]): number | null {
  if (xs.length === 0) return null;
  let result = xs[0];
  for (let i = 1; i < xs.length; i++) if (xs[i] < result) result = xs[i];
  return result;
}

/** Swift `Int(x)` for a finite Double — truncation toward zero. Throws where
 * Swift would trap (NaN / ±∞ / out of Int64 range) so a bad port is loud. */
export function sInt(x: number): number {
  if (!Number.isFinite(x)) throw new RangeError(`Int(${x}) traps in Swift`);
  const t = Math.trunc(x);
  return t === 0 ? 0 : t;
}

/**
 * C `printf("%.<digits>f", x)` — the exact binary value rounded half-to-even,
 * which is what Swift's `String(format:)` produces on Darwin.
 */
export function formatFixed(x: number, digits: number): string {
  if (Number.isNaN(x)) return "nan";
  if (!Number.isFinite(x)) return x > 0 ? "inf" : "-inf";
  const negative = x < 0 || Object.is(x, -0);
  const ax = Math.abs(x);
  // Exact rational: ax = mant * 2^exp.
  const { mant, exp } = decompose(ax);
  const scale = 10n ** BigInt(digits);
  let num: bigint;
  let den: bigint;
  if (exp >= 0) {
    num = mant * (1n << BigInt(exp)) * scale;
    den = 1n;
  } else {
    num = mant * scale;
    den = 1n << BigInt(-exp);
  }
  let q = num / den;
  const r = num - q * den;
  const twice = r * 2n;
  if (twice > den || (twice === den && q % 2n === 1n)) q += 1n;
  let s = q.toString();
  if (digits > 0) {
    s = s.padStart(digits + 1, "0");
    s = `${s.slice(0, s.length - digits)}.${s.slice(s.length - digits)}`;
  }
  return (negative ? "-" : "") + s;
}

function decompose(ax: number): { mant: bigint; exp: number } {
  if (ax === 0) return { mant: 0n, exp: 0 };
  const buf = new DataView(new ArrayBuffer(8));
  buf.setFloat64(0, ax);
  const hi = buf.getUint32(0);
  const lo = buf.getUint32(4);
  const biased = (hi >>> 20) & 0x7ff;
  const fracHi = BigInt(hi & 0xfffff);
  const frac = (fracHi << 32n) | BigInt(lo);
  if (biased === 0) return { mant: frac, exp: -1074 };
  return { mant: frac | (1n << 52n), exp: biased - 1075 };
}

/** 64-bit FNV-1a over UTF-8 (Project.fnv1a64). */
export function fnv1a64(s: string): bigint {
  let hash = 0xcbf29ce484222325n;
  const bytes = new TextEncoder().encode(s);
  for (const b of bytes) {
    hash ^= BigInt(b);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash;
}

/** Foundation `UUID.uuidString` for 16 bytes (uppercase, 8-4-4-4-12). */
export function uuidStringFromBytes(bytes: Uint8Array): string {
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0").toUpperCase()).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Darwin libm (hypot is NOT correctly rounded on Darwin, and differs from Math.hypot). */
export { chypot, fma } from "./libm";
