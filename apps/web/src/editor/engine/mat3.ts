/**
 * Row-major 3×3 homographies in Y-DOWN pixel space: p' = M · (x, y, 1).
 * The card camera (zoom about the focal point, offset, intro slide, and later
 * the TiltMath perspective warp) is one of these, so every card transform the
 * Mac exporter chains (`CGAffineTransform` / `CIPerspectiveTransform`) folds
 * into a single uniform.
 */
export type Mat3 = [number, number, number, number, number, number, number, number, number];

export const IDENTITY: Mat3 = [1, 0, 0, 0, 1, 0, 0, 0, 1];

export function multiply(a: Mat3, b: Mat3): Mat3 {
  const o = new Array(9).fill(0) as Mat3;
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      o[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
    }
  }
  return o;
}

export function invert(m: Mat3): Mat3 {
  const [a, b, c, d, e, f, g, h, i] = m;
  const A = e * i - f * h;
  const B = -(d * i - f * g);
  const C = d * h - e * g;
  const det = a * A + b * B + c * C;
  if (Math.abs(det) < 1e-12) return IDENTITY;
  const k = 1 / det;
  return [
    A * k, -(b * i - c * h) * k, (b * f - c * e) * k,
    B * k, (a * i - c * g) * k, -(a * f - c * d) * k,
    C * k, -(a * h - b * g) * k, (a * e - b * d) * k,
  ];
}

export function translate(tx: number, ty: number): Mat3 {
  return [1, 0, tx, 0, 1, ty, 0, 0, 1];
}

export function scaleAbout(s: number, ax: number, ay: number): Mat3 {
  return [s, 0, ax * (1 - s), 0, s, ay * (1 - s), 0, 0, 1];
}

export function isIdentity(m: Mat3, eps = 1e-9): boolean {
  for (let i = 0; i < 9; i++) if (Math.abs(m[i] - IDENTITY[i]) > eps) return false;
  return true;
}

export function apply(m: Mat3, x: number, y: number): [number, number] {
  const w = m[6] * x + m[7] * y + m[8];
  return [(m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w];
}

/** Rows padded to vec4 for WGSL uniforms (3 × vec4f). */
export function toRows(m: Mat3): number[] {
  return [m[0], m[1], m[2], 0, m[3], m[4], m[5], 0, m[6], m[7], m[8], 0];
}

/** Linear pixel footprint of the inverse map at a point (1 for identity). */
export function inverseFootprint(inv: Mat3, x: number, y: number): number {
  const [x0, y0] = apply(inv, x, y);
  const [x1, y1] = apply(inv, x + 1, y);
  const [x2, y2] = apply(inv, x, y + 1);
  const det = Math.abs((x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0));
  return Math.sqrt(det) || 1;
}
