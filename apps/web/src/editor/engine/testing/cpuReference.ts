/**
 * CPU reference for the background + card passes — the test oracle the lab
 * parity check compares GPU pixels against (tolerance 2/255).
 *
 * Every function here is the float64 twin of a WGSL function in
 * `gpu/shaders.ts` (named alike) and consumes the SAME geometry/colour math
 * (`layout.ts`, `color.ts`) the passes are fed from. It is deliberately
 * written per pixel and unoptimised: it runs for a few hundred sample points.
 *
 * Scope: backgrounds (solid, gradient/legacy diagonal, P3 working space),
 * the baked card shadow (mask × α → separable Gaussian → offset → over bg),
 * and the video card over a CONSTANT-colour source region (the fixtures'
 * white border band) including the Lanczos / bilinear clear-edge falloff and
 * the inner × outer clip coverage.
 */
import { cgOklabRamp, gradientT, q8, srgba, srgbToWorking, type WorkingSpace } from "../color";
import type { RenderSettings } from "../contract";
import type { CardGeometry, Rect } from "../layout";
import type { ShapeRaster } from "../shapes";

export interface ReferenceScene {
  settings: RenderSettings;
  geometry: CardGeometry;
  workingSpace: WorkingSpace;
  /** Source (recording) pixel size. */
  sourceSize: { width: number; height: number };
  /** Squircle raster (same rasterizer the engine uses), when the frame shape needs it. */
  squircle?: ShapeRaster | null;
  /** Premultiplied source colour assumed around the sampled card pixels. */
  videoColor: [number, number, number, number];
}

type RGBA = [number, number, number, number];

// ── background (backgroundWGSL fs_main) ─────────────────────────────────────

export function backgroundAt(scene: ReferenceScene, x: number, y: number): RGBA {
  const s = scene.settings;
  const { width: W, height: H } = scene.geometry.target;
  if (s.backgroundType === "Transparent") return [0, 0, 0, 0];
  const c =
    s.backgroundType === "Solid Color"
      ? srgba(s.solidColor)
      : cgOklabRamp(srgba(s.gradientStartColor), srgba(s.gradientEndColor), gradientT(x, y, W, H, s.gradientAngle));
  const qa = Math.round(Math.max(0, Math.min(1, c.a)) * 255) / 255;
  if (qa <= 0) return [0, 0, 0, 0];
  const pm = [c.r, c.g, c.b].map((v) => Math.round(Math.max(0, Math.min(1, v)) * c.a * 255) / 255);
  let rgb: [number, number, number] = [pm[0] / qa, pm[1] / qa, pm[2] / qa];
  rgb = srgbToWorking(rgb, scene.workingSpace);
  return [q8(rgb[0] * qa), q8(rgb[1] * qa), q8(rgb[2] * qa), q8(qa)];
}

// ── SDF coverage (sdRoundRect / coverageFromSd) ─────────────────────────────

export function sdRoundRect(px: number, py: number, rect: Rect, radius: number): number {
  const hx = rect.width / 2;
  const hy = rect.height / 2;
  const r = Math.max(0, Math.min(radius, Math.min(hx, hy)));
  const qx = Math.abs(px - (rect.x + hx)) - hx + r;
  const qy = Math.abs(py - (rect.y + hy)) - hy + r;
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}

export function coverage(d: number): number {
  return Math.max(0, Math.min(1, 0.5 - d));
}

function squircleCoverage(r: ShapeRaster, x: number, y: number): number {
  const ix = Math.floor(x) - r.originX;
  const iy = Math.floor(y) - r.originY;
  if (ix < 0 || iy < 0 || ix >= r.width || iy >= r.height) return 0;
  return r.coverage[iy * r.width + ix] / 255;
}

// ── shadow (shapeMaskWGSL → blurWGSL ×2 → shadowComposeWGSL) ────────────────

function shadowMask(scene: ReferenceScene, i: number, j: number): number {
  const sh = scene.geometry.shadow!;
  const { width: W, height: H } = scene.geometry.target;
  if (i < 0 || j < 0 || i >= W || j >= H) return 0;
  const cx = i + 0.5;
  const cy = j + 0.5;
  let cov: number;
  if (sh.shape === "squircle") cov = scene.squircle ? squircleCoverage(scene.squircle, cx, cy) : 0;
  else cov = coverage(sdRoundRect(cx, cy, sh.rect, sh.shape === "roundedRect" ? sh.cornerRadius : 0));
  return cov * sh.alpha;
}

const weightCache = new Map<string, number[]>();
function gaussWeights(sigma: number, taps: number): number[] {
  const key = `${sigma}|${taps}`;
  let w = weightCache.get(key);
  if (!w) {
    w = [];
    let sum = 0;
    for (let k = -taps; k <= taps; k++) {
      const v = Math.exp((-0.5 * k * k) / (sigma * sigma));
      w.push(v);
      sum += v;
    }
    w = w.map((v) => v / sum);
    weightCache.set(key, w);
  }
  return w;
}

/** Blurred shadow alpha at texel (i, j) — zero outside the canvas at every stage. */
function blurredShadow(scene: ReferenceScene, i: number, j: number): number {
  const sh = scene.geometry.shadow!;
  const { width: W, height: H } = scene.geometry.target;
  if (i < 0 || j < 0 || i >= W || j >= H) return 0;
  const taps = Math.max(1, Math.ceil(sh.sigma * 3));
  const w = gaussWeights(sh.sigma, taps);
  let acc = 0;
  for (let l = -taps; l <= taps; l++) {
    const jj = j + l;
    if (jj < 0 || jj >= H) continue;
    let row = 0;
    for (let k = -taps; k <= taps; k++) {
      const ii = i + k;
      if (ii < 0 || ii >= W) continue;
      row += w[k + taps] * shadowMask(scene, ii, jj);
    }
    acc += w[l + taps] * row;
  }
  return acc;
}

/** bilinearClear over the blurred shadow, sampled at p − (0, offset). */
export function shadowAlphaAt(scene: ReferenceScene, x: number, y: number): number {
  const sh = scene.geometry.shadow;
  if (!sh) return 0;
  const px = x;
  const py = y - sh.offsetY;
  const sx = px - 0.5;
  const sy = py - 0.5;
  const i0 = Math.floor(sx);
  const j0 = Math.floor(sy);
  const fx = sx - i0;
  const fy = sy - j0;
  const a = blurredShadow(scene, i0, j0);
  const b = blurredShadow(scene, i0 + 1, j0);
  const c = blurredShadow(scene, i0, j0 + 1);
  const d = blurredShadow(scene, i0 + 1, j0 + 1);
  return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;
}

/** The baked base texel (rgba8unorm): background × (1 − shadow α). */
export function baseAt(scene: ReferenceScene, x: number, y: number): RGBA {
  const bg = backgroundAt(scene, x, y);
  const a = shadowAlphaAt(scene, x, y);
  // Black shadow (0,0,0,a) source-over the background.
  return [q8(bg[0] * (1 - a)), q8(bg[1] * (1 - a)), q8(bg[2] * (1 - a)), q8(a + bg[3] * (1 - a))];
}

// ── video card (fit passes + cardFitted/cardDirect) ─────────────────────────

function lanczos3(x: number): number {
  const ax = Math.abs(x);
  if (ax < 1e-6) return 1;
  if (ax >= 3) return 0;
  const px = Math.PI * x;
  return (3 * Math.sin(px) * Math.sin(px / 3)) / (px * px);
}

/** In-bounds Lanczos weight fraction for fitted texel `i` along an axis (constant source). */
function lanczosEdge(i: number, s: number, srcLen: number): number {
  const c = (i + 0.5) / s;
  const support = 3 / s;
  const i0 = Math.ceil(c - 0.5 - support);
  const i1 = Math.floor(c - 0.5 + support);
  let inside = 0;
  let all = 0;
  for (let k = i0; k <= i1; k++) {
    const w = lanczos3((k + 0.5 - c) * s);
    all += w;
    if (k >= 0 && k < srcLen) inside += w;
  }
  return inside / all;
}

function edgeFactor1(s: number, len: number): number {
  const t = s - 0.5;
  const i0 = Math.floor(t);
  const f = t - i0;
  let w = 1;
  if (i0 < 0) w -= 1 - f;
  if (i0 + 1 > len - 1) w -= f;
  return Math.max(0, Math.min(1, w));
}

/** Premultiplied video colour the card pass samples at card-space point (x, y). */
function videoSample(scene: ReferenceScene, x: number, y: number): RGBA {
  const g = scene.geometry;
  const vc = scene.videoColor;
  const lx = x - g.videoRect.x;
  const ly = y - g.videoRect.y;
  const s = g.videoScale;
  if (s < 0.999) {
    const dstW = Math.max(1, Math.ceil(scene.sourceSize.width * s - 1e-4));
    const dstH = Math.max(1, Math.ceil(scene.sourceSize.height * s - 1e-4));
    // Bilinear over fitted texels whose value is q8(vc × edgeX(i) × edgeY(j)) (rgba8unorm).
    const sx = lx - 0.5;
    const sy = ly - 0.5;
    const i0 = Math.floor(sx);
    const j0 = Math.floor(sy);
    const fx = sx - i0;
    const fy = sy - j0;
    const edge = (i: number, j: number): number => {
      const ic = Math.max(0, Math.min(dstW - 1, i)); // clamp-to-edge sampler
      const jc = Math.max(0, Math.min(dstH - 1, j));
      return lanczosEdge(ic, s, scene.sourceSize.width) * lanczosEdge(jc, s, scene.sourceSize.height);
    };
    const e00 = edge(i0, j0);
    const e10 = edge(i0 + 1, j0);
    const e01 = edge(i0, j0 + 1);
    const e11 = edge(i0 + 1, j0 + 1);
    const e = edgeFactor1(lx, dstW) * edgeFactor1(ly, dstH);
    return vc.map((v) => {
      const t00 = q8(v * e00);
      const t10 = q8(v * e10);
      const t01 = q8(v * e01);
      const t11 = q8(v * e11);
      return ((t00 * (1 - fx) + t10 * fx) * (1 - fy) + (t01 * (1 - fx) + t11 * fx) * fy) * e;
    }) as RGBA;
  }
  const srcX = lx / s;
  const srcY = ly / s;
  const e = edgeFactor1(srcX, scene.sourceSize.width) * edgeFactor1(srcY, scene.sourceSize.height);
  return vc.map((v) => v * e) as RGBA;
}

function inRect(x: number, y: number, r: Rect): boolean {
  return x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
}

/** Card coverage (inner × outer) at a card-space pixel centre. */
export function cardCoverageAt(scene: ReferenceScene, x: number, y: number): number {
  const g = scene.geometry;
  let cov = 1;
  if (g.inner.kind !== "none") cov *= coverage(sdRoundRect(x, y, g.videoRect, g.inner.radius));
  if (g.outer.kind === "roundedRect") cov *= coverage(sdRoundRect(x, y, g.videoRect, g.outer.radius));
  else if (g.outer.kind === "squircle") cov *= scene.squircle ? squircleCoverage(scene.squircle, x, y) : 0;
  return cov;
}

/** Final canvas pixel (identity camera): card over base, 8-bit. */
export function pixelAt(scene: ReferenceScene, px: number, py: number): RGBA {
  const x = px + 0.5;
  const y = py + 0.5;
  const base = baseAt(scene, x, y);
  const g = scene.geometry;
  if (!inRect(x, y, g.videoRect) || !inRect(x, y, g.contentRect)) return base;
  const cov = cardCoverageAt(scene, x, y);
  const v = videoSample(scene, x, y).map((c) => c * cov) as RGBA;
  const a = v[3];
  return [q8(v[0] + base[0] * (1 - a)), q8(v[1] + base[1] * (1 - a)), q8(v[2] + base[2] * (1 - a)), q8(a + base[3] * (1 - a))];
}
