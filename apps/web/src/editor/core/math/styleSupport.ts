/**
 * Style-cluster support: CPU REFERENCE rasterizers — the executable spec the
 * WebGPU background pass must follow — plus CGPath element data helpers.
 *
 * `rasterBackgroundReference` reproduces `BackgroundLook.cgImage(for:size:scale:)`
 * for the PLAIN and GRAIN-ONLY looks (gradient / mesh / solid / wallpaper
 * placeholder / image fallback) on the CPU. It is checked against REAL Mac
 * bitmaps by the `backgroundLookPixels` golden-vector unit.
 *
 * DITHERING (measured, see style.test.ts): CoreGraphics dithers every
 * gradient by JITTERING THE SAMPLE POSITION inside each pixel (all channels
 * move together; the jitter pattern is CG-internal and not reproducible).
 * Every real pixel lies inside the envelope of the ramp evaluated over the
 * pixel's square (centre ± 0.5 px on both axes) widened by 1/255 — and 0.25 px
 * is NOT enough — so the web may evaluate at pixel centres (or add its own
 * ±0.5 px dither). Centre-sampled vs real: mean |Δ| ≈ 0.6/255, max ≈ 11/255 in
 * the steepest part of a ramp (near-black Oklab ends). Solid fills and the
 * grain arithmetic are exact.
 *
 * Quantisation: CG stores premultiplied 8-bit sRGB; values here are
 * round(v · 255) of the premultiplied float (±1 vs CG's own conversion).
 */
import type { Point, Rect, Size } from "../model/types";
import { drawPoints, type GradientAxis } from "./backgroundGradientRenderer";
import { maxX, maxY, midX, midY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { smin } from "./swift";
import {
  applyGrain,
  baseFill,
  meshPools,
  pixelSizeFor,
  renderPath,
  type BackgroundSpec,
  type MeshPool,
} from "./backgroundLook";
import { gradientTableFromTo, type GradientStop, type SRGBA } from "./oklabGradient";

// ── CGPath element data ─────────────────────────────────────────────────────

/**
 * One CGPath element (`CGPath.applyWithBlock` order): `move`/`line` carry one
 * point, `quad` two, `curve` three (control1, control2, end), `close` none.
 * Coordinates are whatever space the path was built in (the Swift callers
 * build in CG Y-UP bitmap space; a path is flipped to Y-down with
 * y' = H − y — curves stay curves under that affine map).
 */
export interface PathElement {
  op: "move" | "line" | "quad" | "curve" | "close";
  pts: Point[];
}

const move = (x: number, y: number): PathElement => ({ op: "move", pts: [{ x, y }] });
const line = (x: number, y: number): PathElement => ({ op: "line", pts: [{ x, y }] });
const curve = (x1: number, y1: number, x2: number, y2: number, x: number, y: number): PathElement => ({
  op: "curve",
  pts: [
    { x: x1, y: y1 },
    { x: x2, y: y2 },
    { x, y },
  ],
});
const close = (): PathElement => ({ op: "close", pts: [] });

/**
 * Cubic-Bézier circle constant CoreGraphics uses for ellipses and rounded
 * corners: the 10-digit 0.5522847498 (measured from real CGPaths), NOT the
 * exact 4(√2−1)/3 = 0.55228474983079… (that differs by ~1e-11·r).
 */
export const cgKappa = 0.5522847498;

/** `CGPath(rect:transform:nil)` — standardized rect, 4 lines, close. */
export function cgPathRect(r: Rect): PathElement[] {
  const x0 = minX(r);
  const x1 = maxX(r);
  const y0 = minY(r);
  const y1 = maxY(r);
  return [move(x0, y0), line(x1, y0), line(x1, y1), line(x0, y1), close()];
}

/** `CGPath(ellipseIn:transform:nil)` — 4 cubics from (maxX, midY), counter-clockwise in Y-up. */
export function cgPathEllipse(r: Rect): PathElement[] {
  // Standardized accessors (midX/midY, |width|/2): also matches CG for
  // CGRect.null (infinite origin), which (x1 - x0) / 2 turns into NaN.
  const x0 = minX(r);
  const y0 = minY(r);
  const x1 = maxX(r);
  const y1 = maxY(r);
  const cx = midX(r);
  const cy = midY(r);
  const kx = (rectWidth(r) / 2) * cgKappa;
  const ky = (rectHeight(r) / 2) * cgKappa;
  return [
    move(x1, cy),
    curve(x1, cy + ky, cx + kx, y1, cx, y1),
    curve(cx - kx, y1, x0, cy + ky, x0, cy),
    curve(x0, cy - ky, cx - kx, y0, cx, y0),
    curve(cx + kx, y0, x1, cy - ky, x1, cy),
    close(),
  ];
}

/**
 * `CGPath(roundedRect:cornerWidth:cornerHeight:transform:nil)` — a plain
 * rect path when either corner is ≤ 0; otherwise each corner is CLAMPED to
 * half its side (measured: CG does not reject oversize corners) and the path
 * is line + quarter-ellipse cubic per corner, starting at (maxX, midY).
 */
export function cgPathRoundedRect(r: Rect, cornerWidth: number, cornerHeight: number): PathElement[] {
  // Standardized accessors (see cgPathEllipse); verified against both the
  // style (cgPathPrimitives) and overlay (overlayPathPrimitives) vectors.
  const rw = smin(cornerWidth, rectWidth(r) / 2);
  const rh = smin(cornerHeight, rectHeight(r) / 2);
  if (!(rw > 0) || !(rh > 0)) return cgPathRect(r);
  const x0 = minX(r);
  const y0 = minY(r);
  const x1 = maxX(r);
  const y1 = maxY(r);
  const kw = rw * cgKappa;
  const kh = rh * cgKappa;
  return [
    move(x1, midY(r)),
    line(x1, y1 - rh),
    curve(x1, y1 - rh + kh, x1 - rw + kw, y1, x1 - rw, y1),
    line(x0 + rw, y1),
    curve(x0 + rw - kw, y1, x0, y1 - rh + kh, x0, y1 - rh),
    line(x0, y0 + rh),
    curve(x0, y0 + rh - kh, x0 + rw - kw, y0, x0 + rw, y0),
    line(x1 - rw, y0),
    curve(x1 - rw + kw, y0, x1, y0 + rh - kh, x1, y0 + rh),
    close(),
  ];
}

/** Premultiplied float RGBA (0…1). */
type PRGBA = [number, number, number, number];

/** CG-style lookup into the dense stop table: component lerp in sRGB. */
export function interpolateTable(table: readonly GradientStop[], t: number): SRGBA {
  const tt = t < 0 ? 0 : t > 1 ? 1 : t;
  // Locations are k/256 exactly — binary search is unnecessary.
  const n = table.length - 1;
  const x = tt * n;
  let i = Math.floor(x);
  if (i >= n) i = n - 1;
  const f = x - i;
  const a = table[i].color;
  const b = table[i + 1].color;
  return {
    red: a.red + (b.red - a.red) * f,
    green: a.green + (b.green - a.green) * f,
    blue: a.blue + (b.blue - a.blue) * f,
    alpha: a.alpha + (b.alpha - a.alpha) * f,
  };
}

function premul(c: SRGBA): PRGBA {
  return [c.red * c.alpha, c.green * c.alpha, c.blue * c.alpha, c.alpha];
}

function over(src: PRGBA, dst: PRGBA): PRGBA {
  const k = 1 - src[3];
  return [src[0] + dst[0] * k, src[1] + dst[1] * k, src[2] + dst[2] * k, src[3] + dst[3] * k];
}

/** Linear gradient value at a Y-UP point. */
function linearAt(table: readonly GradientStop[], p0: Point, p1: Point, x: number, y: number): SRGBA {
  const dx = p1.x - p0.x;
  const dy = p1.y - p0.y;
  const len2 = dx * dx + dy * dy;
  const t = len2 > 0 ? ((x - p0.x) * dx + (y - p0.y) * dy) / len2 : 0;
  return interpolateTable(table, t);
}

/** Radial pool (no extend) at a Y-UP point: straight colour + alpha, or null outside. */
function poolAt(pool: MeshPool, x: number, y: number): PRGBA | null {
  if (!(pool.radius > 0)) return null;
  const d = Math.hypot(x - pool.center.x, y - pool.center.y);
  const t = d / pool.radius;
  if (t > 1) return null;
  const st = pool.stops;
  let a = st[st.length - 1].alpha;
  for (let i = 0; i < st.length - 1; i++) {
    if (t >= st[i].location && t <= st[i + 1].location) {
      const span = st[i + 1].location - st[i].location;
      const f = span > 0 ? (t - st[i].location) / span : 0;
      a = st[i].alpha + (st[i + 1].alpha - st[i].alpha) * f;
      break;
    }
  }
  return [pool.color.red * a, pool.color.green * a, pool.color.blue * a, a];
}

interface Shader {
  /** Premultiplied colour at a Y-UP continuous point. */
  at(x: number, y: number): PRGBA;
}

function makeShader(spec: BackgroundSpec, pixelSize: Size): Shader | null {
  const fill = baseFill(spec, false);
  const rect: Rect = { x: 0, y: 0, width: pixelSize.width, height: pixelSize.height };
  const linear = (start: SRGBA, end: SRGBA, axis: GradientAxis) => {
    const pts = drawPoints(rect, axis);
    const table = gradientTableFromTo(start, end);
    return (x: number, y: number): PRGBA =>
      pts ? premul(linearAt(table, pts.p0, pts.p1, x, y)) : [0, 0, 0, 0];
  };
  switch (fill.kind) {
    case "gradient": {
      const f = linear(fill.start, fill.end, fill.axis);
      return { at: f };
    }
    case "mesh": {
      const base = linear(fill.start, fill.end, { kind: "diagonal" });
      const pools = meshPools(fill.start, fill.end, pixelSize);
      return {
        at(x, y) {
          let c = base(x, y);
          for (const pool of pools) {
            const s = poolAt(pool, x, y);
            if (s) c = over(s, c);
          }
          return c;
        },
      };
    }
    case "solid": {
      const c = premul(fill.color);
      return { at: () => c };
    }
    case "image":
    case "none":
      return null;
  }
}

const q8 = (v: number) => {
  const r = Math.round(v * 255);
  return r < 0 ? 0 : r > 255 ? 255 : r;
};

export interface ReferenceBitmap {
  width: number;
  height: number;
  /** RGBA8 premultiplied, row 0 = TOP. */
  rgba: number[];
}

/**
 * CPU reference of `BackgroundLook.cgImage(for:size:scale:)` for plain and
 * grain-only looks (null for the nil branch; throws for CoreImage looks or a
 * decoded image — those need the GPU passes). Samples at pixel centres.
 */
export function rasterBackgroundReference(spec: BackgroundSpec, size: Size, scale: number): ReferenceBitmap | null {
  const path = renderPath(spec, size, scale);
  if (path === "nil") return null;
  if (path === "styled" || path === "styledGrain") throw new Error("styled looks need the CoreImage-equivalent GPU passes");
  const px = pixelSizeFor(size, scale);
  const W = px.width;
  const H = px.height;
  const shader = makeShader(spec, px);
  if (!shader) throw new Error("image backgrounds need the decoded image");
  const rgba: number[] = new Array(W * H * 4);
  for (let py = 0; py < H; py++) {
    for (let pxi = 0; pxi < W; pxi++) {
      const c = shader.at(pxi + 0.5, H - (py + 0.5));
      const p = (py * W + pxi) * 4;
      rgba[p] = q8(c[0]);
      rgba[p + 1] = q8(c[1]);
      rgba[p + 2] = q8(c[2]);
      rgba[p + 3] = q8(c[3]);
    }
  }
  return {
    width: W,
    height: H,
    rgba: path === "baseGrain" ? applyGrain(rgba, W, H, spec.noise, scale) : rgba,
  };
}

/**
 * The dither envelope: per channel, the [lo, hi] range (8-bit) of the shading
 * over the pixel square (centre ± `jitter` px), widened by `slack`, with the
 * grain delta applied to both bounds. Every real CG pixel must lie inside.
 */
export function rasterBackgroundEnvelope(
  spec: BackgroundSpec,
  size: Size,
  scale: number,
  jitter = 0.5,
  slack = 1,
  steps = 8,
): { lo: number[]; hi: number[] } | null {
  const path = renderPath(spec, size, scale);
  if (path === "nil") return null;
  const px = pixelSizeFor(size, scale);
  const W = px.width;
  const H = px.height;
  const shader = makeShader(spec, px);
  if (!shader) throw new Error("unsupported background for the envelope");
  const lo: number[] = new Array(W * H * 4);
  const hi: number[] = new Array(W * H * 4);
  for (let py = 0; py < H; py++) {
    for (let pxi = 0; pxi < W; pxi++) {
      const l = [Infinity, Infinity, Infinity, Infinity];
      const h = [-Infinity, -Infinity, -Infinity, -Infinity];
      for (let a = 0; a <= steps; a++) {
        for (let b = 0; b <= steps; b++) {
          const ox = -jitter + (2 * jitter * a) / steps;
          const oy = -jitter + (2 * jitter * b) / steps;
          const c = shader.at(pxi + 0.5 + ox, H - (py + 0.5 + oy));
          for (let k = 0; k < 4; k++) {
            const v = c[k] * 255;
            if (v < l[k]) l[k] = v;
            if (v > h[k]) h[k] = v;
          }
        }
      }
      const p = (py * W + pxi) * 4;
      for (let k = 0; k < 4; k++) {
        lo[p + k] = Math.max(0, Math.floor(l[k] - slack));
        hi[p + k] = Math.min(255, Math.ceil(h[k] + slack));
      }
    }
  }
  if (path === "baseGrain") {
    return { lo: applyGrain(lo, W, H, spec.noise, scale), hi: applyGrain(hi, W, H, spec.noise, scale) };
  }
  return { lo, hi };
}
