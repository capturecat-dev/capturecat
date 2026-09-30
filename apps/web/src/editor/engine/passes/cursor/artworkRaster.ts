/**
 * Exact-coverage rasterizer for the drawn cursor styles — the web twin of
 * `CursorStyleProvider.rasterizedCGImage` for macOS Arrow / White Arrow /
 * Dot / Ring, from the provider's own draw ops
 * (`core/math/cursorStyleProvider.artwork`, locked by `cursorStyleAssets`).
 *
 * CoreGraphics antialiases by AREA coverage; so does this: every op's region
 * (polygon interior; a closed polygon's round-joined stroke = segment slabs ∪
 * round joins; a disk; an annulus) is intersected with horizontal
 * sub-scanlines in USER space (the raster CTM is an axis-aligned stretch,
 * pixelW/baseW × pixelH/baseH), the covered x-intervals are accumulated per
 * pixel exactly, and 16 sub-scanlines integrate y (midpoint rule — exact on
 * the linear pieces of a straight edge). Ops are painted in order,
 * source-over, premultiplied, rounded to 8 bits after each op like the 8-bit
 * bitmap.
 *
 * Curves (the ovals and the round joins) are CG arcs — cubics with
 * κ = 0.5522847498 — flattened into chords before scan conversion (see
 * `flattenedCircle`). Against the REAL Swift rasters (shipped 1×/2×/3× +
 * 50×70, 57×80, 110×154, 25×35, 33×47, 45×45, 60×60, 37×37, 132×132 grids):
 * arrows mean |Δ| 0.02–0.19/255 (max ≤ 21 on a few join pixels), ovals mean
 * ≤ 0.9 (max ≤ 23) — cursor.test.ts locks the shipped grids.
 *
 * Browser Canvas2D is NOT used: its GPU path antialiases with 4× MSAA
 * (coverage in quarters, up to 95/255 off) and its CPU stroker lands stroke
 * edges ~0.1 px off CoreGraphics' (up to 57/255 on the arrow's diagonal).
 */
import type { Point, Size } from "../../../core/model/types";
import type { CursorStyle } from "../../../core/model/enums";
import { artwork, type CursorDrawOp } from "../../../core/math/cursorStyleProvider";

const SUB = 16;

/**
 * Chord tolerance (device px) for flattening CG arcs. CoreGraphics' own
 * flattening is undocumented; exact circles leave CG's edges ~0.1 px inside
 * ours (chords sit inside the arc). 0.07 px fits the Swift rasters best
 * (sweep 0.03…0.5 over 11 oval grids: summed mean |Δ| 10.1 → 4.9; arrow joins
 * max 32 → 21).
 */
const FLATTEN_TOL = 0.07;

type Interval = [number, number];

/** x-intervals of the polygon interior (non-zero winding) on the line y. */
function polygonSpans(pts: readonly Point[], y: number, out: Interval[]): void {
  const xs: { x: number; w: number }[] = [];
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i];
    const b = pts[(i + 1) % pts.length];
    if (a.y === b.y) continue;
    const up = a.y < b.y;
    const y0 = up ? a.y : b.y;
    const y1 = up ? b.y : a.y;
    if (!(y >= y0 && y < y1)) continue;
    xs.push({ x: a.x + ((y - a.y) / (b.y - a.y)) * (b.x - a.x), w: up ? 1 : -1 });
  }
  xs.sort((p, q) => p.x - q.x);
  let wind = 0;
  for (let i = 0; i < xs.length; i++) {
    const before = wind;
    wind += xs[i].w;
    if (before === 0 && wind !== 0) out.push([xs[i].x, xs[i].x]);
    else if (before !== 0 && wind === 0) out[out.length - 1][1] = xs[i].x;
  }
}

/** x-intervals inside an odd number of the closed polygons on the line y. */
function evenOddSpans(polys: readonly (readonly Point[])[], y: number, out: Interval[]): void {
  const xs: number[] = [];
  for (const pts of polys) {
    for (let i = 0; i < pts.length; i++) {
      const a = pts[i];
      const b = pts[(i + 1) % pts.length];
      if (a.y === b.y) continue;
      const y0 = Math.min(a.y, b.y);
      const y1 = Math.max(a.y, b.y);
      if (!(y >= y0 && y < y1)) continue;
      xs.push(a.x + ((y - a.y) / (b.y - a.y)) * (b.x - a.x));
    }
  }
  xs.sort((p, q) => p - q);
  for (let i = 0; i + 1 < xs.length; i += 2) out.push([xs[i], xs[i + 1]]);
}

/** Line y ∩ a convex polygon (one interval, or null). */
function convexSpan(poly: readonly Point[], y: number): Interval | null {
  const o: Interval[] = [];
  evenOddSpans([poly], y, o);
  return o.length ? [o[0][0], o[o.length - 1][1]] : null;
}

/**
 * A CG circle (`NSBezierPath(ovalIn:)` / a round join's arc: four cubics,
 * κ = 0.5522847498) flattened into chords: each cubic cut into n uniform
 * parameter steps, n from Wang's bound for FLATTEN_TOL device px.
 */
function flattenedCircle(cx: number, cy: number, r: number, sx: number, sy: number): Point[] {
  const k = r * 0.5522847498;
  const quads: Point[][] = [
    [{ x: cx + r, y: cy }, { x: cx + r, y: cy + k }, { x: cx + k, y: cy + r }, { x: cx, y: cy + r }],
    [{ x: cx, y: cy + r }, { x: cx - k, y: cy + r }, { x: cx - r, y: cy + k }, { x: cx - r, y: cy }],
    [{ x: cx - r, y: cy }, { x: cx - r, y: cy - k }, { x: cx - k, y: cy - r }, { x: cx, y: cy - r }],
    [{ x: cx, y: cy - r }, { x: cx + k, y: cy - r }, { x: cx + r, y: cy - k }, { x: cx + r, y: cy }],
  ];
  const out: Point[] = [];
  for (const [p0, p1, p2, p3] of quads) {
    let L = 0;
    for (const [a, b, c] of [[p0, p1, p2], [p1, p2, p3]]) {
      L = Math.max(L, Math.hypot((a.x - 2 * b.x + c.x) * sx, (a.y - 2 * b.y + c.y) * sy));
    }
    const n = Math.max(1, Math.ceil(Math.sqrt((0.75 * L) / FLATTEN_TOL)));
    for (let i = 0; i < n; i++) {
      const t = i / n;
      const u = 1 - t;
      out.push({
        x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
        y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y,
      });
    }
  }
  return out;
}

/** Line y ∩ the rectangle body of a stroked segment ab of half-width r:
 * {a + t·u + s·n : 0 ≤ t ≤ |ab|, |s| ≤ r} (convex → one interval). */
function slabSpan(a: Point, b: Point, r: number, y: number): Interval | null {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const L = Math.hypot(dx, dy);
  if (!(L > 0)) return null;
  const ux = dx / L;
  const uy = dy / L;
  const nx = -uy;
  const ny = ux;
  let xl = -Infinity;
  let xh = Infinity;
  // min ≤ k·(x − ax) + c0 ≤ max — t (k = ux) and s (k = nx).
  const rows: [number, number, number, number][] = [
    [ux, (y - a.y) * uy, 0, L],
    [nx, (y - a.y) * ny, -r, r],
  ];
  for (const [k, c0, min, max] of rows) {
    if (Math.abs(k) < 1e-12) {
      if (!(c0 >= min && c0 <= max)) return null;
      continue;
    }
    let p = (min - c0) / k + a.x;
    let q = (max - c0) / k + a.x;
    if (p > q) [p, q] = [q, p];
    xl = Math.max(xl, p);
    xh = Math.min(xh, q);
  }
  return xh >= xl ? [xl, xh] : null;
}

function mergeSpans(spans: Interval[]): Interval[] {
  if (spans.length < 2) return spans;
  spans.sort((p, q) => p[0] - q[0]);
  const out: Interval[] = [[spans[0][0], spans[0][1]]];
  for (let i = 1; i < spans.length; i++) {
    const last = out[out.length - 1];
    if (spans[i][0] <= last[1]) last[1] = Math.max(last[1], spans[i][1]);
    else out.push([spans[i][0], spans[i][1]]);
  }
  return out;
}

/** One op's region as a scanline query: covered x-intervals (user space) on the line y. */
function prepareOp(op: CursorDrawOp, sx: number, sy: number): (y: number) => Interval[] {
  switch (op.kind) {
    case "fillPath":
      return (y) => {
        const out: Interval[] = [];
        polygonSpans(op.points, y, out);
        return out;
      };
    case "strokePath": {
      // Closed path + round joins: segment slabs ∪ round joins.
      const r = op.lineWidth / 2;
      const p = op.points;
      const joins = p.map((c) => flattenedCircle(c.x, c.y, r, sx, sy));
      return (y) => {
        const out: Interval[] = [];
        for (let i = 0; i < p.length; i++) {
          const s = slabSpan(p[i], p[(i + 1) % p.length], r, y);
          if (s) out.push(s);
          const j = convexSpan(joins[i], y);
          if (j) out.push(j);
        }
        return mergeSpans(out);
      };
    }
    case "fillOval": {
      const disk = flattenedCircle(op.rect.x + op.rect.width / 2, op.rect.y + op.rect.height / 2, op.rect.width / 2, sx, sy);
      return (y) => {
        const out: Interval[] = [];
        evenOddSpans([disk], y, out);
        return out;
      };
    }
    case "strokeOval": {
      const cx = op.rect.x + op.rect.width / 2;
      const cy = op.rect.y + op.rect.height / 2;
      const R = op.rect.width / 2;
      const w = op.lineWidth / 2;
      const ring = [flattenedCircle(cx, cy, R + w, sx, sy), flattenedCircle(cx, cy, Math.max(0, R - w), sx, sy)];
      return (y) => {
        const out: Interval[] = [];
        evenOddSpans(ring, y, out);
        return out;
      };
    }
  }
}

/**
 * Premultiplied RGBA8 (rows top-down) of `style` stretched onto a `pixel`
 * grid; null for styles without vector artwork (Hand).
 */
export function rasterizeArtwork(style: CursorStyle, pixel: Size): Uint8Array | null {
  const art = artwork(style);
  if (!art) return null;
  const W = pixel.width;
  const H = pixel.height;
  const sx = W / art.size.width;
  const sy = H / art.size.height;
  const buf = new Float64Array(W * H * 4);
  const cov = new Float64Array(W * H);
  for (const op of art.ops) {
    cov.fill(0);
    const spans = prepareOp(op, sx, sy);
    for (let row = 0; row < H; row++) {
      const base = row * W;
      for (let k = 0; k < SUB; k++) {
        const yPx = row + (k + 0.5) / SUB;
        // Flipped artwork is Y-down user space; a non-flipped NSImage draws Y-up.
        const yUser = art.flipped ? yPx / sy : art.size.height - yPx / sy;
        for (const [a, b] of spans(yUser)) {
          const x0 = Math.max(0, a * sx);
          const x1 = Math.min(W, b * sx);
          if (!(x1 > x0)) continue;
          const i0 = Math.floor(x0);
          const i1 = Math.min(W - 1, Math.floor(x1));
          if (i0 === i1) {
            cov[base + i0] += (x1 - x0) / SUB;
            continue;
          }
          cov[base + i0] += (i0 + 1 - x0) / SUB;
          for (let i = i0 + 1; i < i1; i++) cov[base + i] += 1 / SUB;
          cov[base + i1] += (x1 - i1) / SUB;
        }
      }
    }
    const c = op.color;
    for (let p = 0; p < W * H; p++) {
      const a = Math.min(1, cov[p]) * c.a;
      if (a <= 0) continue;
      const o = p * 4;
      const keep = 1 - a;
      buf[o] = Math.round(c.r * 255 * a + buf[o] * keep);
      buf[o + 1] = Math.round(c.g * 255 * a + buf[o + 1] * keep);
      buf[o + 2] = Math.round(c.b * 255 * a + buf[o + 2] * keep);
      buf[o + 3] = Math.round(255 * a + buf[o + 3] * keep);
    }
  }
  const out = new Uint8Array(W * H * 4);
  for (let i = 0; i < out.length; i++) out[i] = Math.max(0, Math.min(255, buf[i]));
  return out;
}
