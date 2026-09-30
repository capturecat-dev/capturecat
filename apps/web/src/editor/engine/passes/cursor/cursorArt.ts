/**
 * Cursor sprite rasters — what `VideoExporter.makeCursorAsset` gets from
 * `CursorStyleProvider.rasterizedCGImage(for:pixelSize:)`: the style's
 * artwork stretched onto a `rasterPixelSize(pointSize × cursorRasterScale)`
 * pixel grid, premultiplied RGBA8, rows top-down.
 *
 * Sources, best first:
 *   1. The REAL Swift rasters shipped in `public/editor/cursors/manifest.json`
 *      (`CaptureCat --web-cursor-sprites`, 1×/2×/3× of every style) — used
 *      byte-for-byte whenever the export's pixel grid is one of them.
 *   2. Vector styles (macOS Arrow, White Arrow, Dot, Ring): the provider's
 *      draw ops (`core/math/cursorStyleProvider.artwork`, a verbatim oracle
 *      locked by the `cursorStyleAssets` vectors) scan-converted with exact
 *      area coverage at the exact grid (./artworkRaster.ts) — same CTM
 *      stretch, op order, round joins, centred strokes, fill last.
 *   3. Hand (`NSCursor.pointingHand.image`, a SYSTEM bitmap with 32 px and
 *      64 px reps): resampled from the shipped 2× raster (== the 64 px rep,
 *      the rep CoreGraphics picks above 32 px) — or the 1× raster for grids
 *      ≤ 32 px. Magnification (every grid > 64 px, i.e. cursorRasterScale > 2)
 *      reproduces CG's `.high` filter (probed: 2 taps, phase → weight table,
 *      `CG_MAG_WEIGHT`): max |Δ| 2/255, mean 0.04 vs the Swift rasters at
 *      75/96/107/128/213 px. Minification (33–63 px, ≤ 31 px) uses a
 *      support-scaled Catmull-Rom — CG's minifier has scale-dependent
 *      negative lobes we do not reproduce (mean 0.7, max ≈ 30 at 20/40/48 px).
 */
import type { Point, Size } from "../../../core/model/types";
import { CursorStyle } from "../../../core/model/enums";
import { rasterizeArtwork } from "./artworkRaster";

export interface CursorArtRaster {
  scale: number;
  width: number;
  height: number;
  /** Premultiplied RGBA8, rows top-down (the CGImage's bytes). */
  rgba: Uint8Array;
}

export interface CursorArtStyle {
  pointSize: Size;
  hotSpot: Point;
  /** Apple system artwork (Hand). */
  system: boolean;
  rasters: CursorArtRaster[];
}

export interface CursorArt {
  styles: Map<string, CursorArtStyle>;
}

export const CURSOR_ART_URL = "/editor/cursors/manifest.json";

function decodeBase64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Parses the `--web-cursor-sprites` manifest (null on any shape error). */
export function parseCursorArt(json: unknown): CursorArt | null {
  if (typeof json !== "object" || json === null) return null;
  const styles = (json as { styles?: unknown }).styles;
  if (!Array.isArray(styles)) return null;
  const map = new Map<string, CursorArtStyle>();
  for (const s of styles as Record<string, unknown>[]) {
    if (typeof s.style !== "string" || !Array.isArray(s.rasters)) return null;
    const rasters: CursorArtRaster[] = [];
    for (const r of s.rasters as Record<string, unknown>[]) {
      if (typeof r.rgbaBase64 !== "string") return null;
      const rgba = decodeBase64(r.rgbaBase64);
      const width = Number(r.pixelWidth);
      const height = Number(r.pixelHeight);
      if (rgba.length !== width * height * 4) return null;
      rasters.push({ scale: Number(r.scale), width, height, rgba });
    }
    map.set(s.style, {
      pointSize: { width: Number(s.pointWidth), height: Number(s.pointHeight) },
      hotSpot: { x: Number(s.hotSpotX), y: Number(s.hotSpotY) },
      system: s.system === true,
      rasters,
    });
  }
  return { styles: map };
}

let pending: Promise<CursorArt | null> | null = null;

/** Loads (once per realm) the shipped Swift rasters. Never rejects. */
export function loadCursorArt(url = CURSOR_ART_URL): Promise<CursorArt | null> {
  pending ??= fetch(url)
    .then((r) => (r.ok ? r.json() : null))
    .then((j) => parseCursorArt(j))
    .catch(() => null);
  return pending;
}

/** A sprite raster ready for upload (premultiplied RGBA8, rows top-down). */
export interface SpriteRaster {
  width: number;
  height: number;
  rgba: Uint8Array;
  origin: "swift" | "analytic" | "resampled";
}

// ── Catmull-Rom resampler (Hand) ────────────────────────────────────────────

function catmullRom(x: number): number {
  const a = Math.abs(x);
  if (a < 1) return 1.5 * a * a * a - 2.5 * a * a + 1;
  if (a < 2) return -0.5 * a * a * a + 2.5 * a * a - 4 * a + 2;
  return 0;
}

/**
 * CoreGraphics' `.high` MAGNIFICATION of a bitmap rep, probed on macOS 26.2
 * (step-edge responses of the exact rasterizedCGImage path, 281 grid sizes):
 * a 2-tap interpolation whose weight is a pure function of the output
 * sample's phase between the two source pixels, the phase rounded to 1/8 and
 * mapped through this table (in 1/255ths; symmetric pairs sum to 255) —
 * sharper than linear. Exact for every phase the probe hit.
 */
const CG_MAG_WEIGHT = [0, 15, 31, 63, 127.5, 192, 224, 240, 255];

function taps(srcLen: number, dstLen: number): { lo: number; w: Float64Array }[] {
  const s = srcLen / dstLen;
  const out: { lo: number; w: Float64Array }[] = [];
  if (s < 1) {
    for (let o = 0; o < dstLen; o++) {
      const c = (o + 0.5) * s - 0.5;
      const lo = Math.floor(c);
      const k = Math.round((c - lo) * 8);
      const w1 = CG_MAG_WEIGHT[k] / 255;
      out.push({ lo, w: Float64Array.of(1 - w1, w1) });
    }
    return out;
  }
  // Minification: CG's filter has scale-dependent negative lobes we do not
  // reproduce exactly; a support-scaled Catmull-Rom is the closest fit.
  const k = s;
  for (let o = 0; o < dstLen; o++) {
    const c = (o + 0.5) * s - 0.5;
    const lo = Math.floor(c - 2 * k);
    const hi = Math.ceil(c + 2 * k);
    const w = new Float64Array(hi - lo + 1);
    let sum = 0;
    for (let i = lo; i <= hi; i++) {
      const v = catmullRom((i - c) / k);
      w[i - lo] = v;
      sum += v;
    }
    if (sum !== 0) for (let i = 0; i < w.length; i++) w[i] /= sum;
    out.push({ lo, w });
  }
  return out;
}

/** Separable resample of premultiplied RGBA8 (CG magnification table / Catmull-Rom minification), transparent outside. */
export function resampleRGBA(src: CursorArtRaster, width: number, height: number): Uint8Array {
  const tx = taps(src.width, width);
  const ty = taps(src.height, height);
  const mid = new Float64Array(width * src.height * 4);
  for (let y = 0; y < src.height; y++) {
    for (let x = 0; x < width; x++) {
      const { lo, w } = tx[x];
      let r = 0, g = 0, b = 0, a = 0;
      for (let k = 0; k < w.length; k++) {
        const sx = lo + k;
        if (sx < 0 || sx >= src.width) continue;
        const o = (y * src.width + sx) * 4;
        r += src.rgba[o] * w[k];
        g += src.rgba[o + 1] * w[k];
        b += src.rgba[o + 2] * w[k];
        a += src.rgba[o + 3] * w[k];
      }
      const m = (y * width + x) * 4;
      mid[m] = r;
      mid[m + 1] = g;
      mid[m + 2] = b;
      mid[m + 3] = a;
    }
  }
  const out = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    const { lo, w } = ty[y];
    for (let x = 0; x < width; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let k = 0; k < w.length; k++) {
        const sy = lo + k;
        if (sy < 0 || sy >= src.height) continue;
        const o = (sy * width + x) * 4;
        r += mid[o] * w[k];
        g += mid[o + 1] * w[k];
        b += mid[o + 2] * w[k];
        a += mid[o + 3] * w[k];
      }
      const A = Math.min(255, Math.max(0, Math.round(a)));
      const o = (y * width + x) * 4;
      // Premultiplied: colour never exceeds alpha.
      out[o] = Math.min(A, Math.max(0, Math.round(r)));
      out[o + 1] = Math.min(A, Math.max(0, Math.round(g)));
      out[o + 2] = Math.min(A, Math.max(0, Math.round(b)));
      out[o + 3] = A;
    }
  }
  return out;
}

/**
 * The raster the exporter samples for `style` on a `pixel` grid
 * (`rasterPixelSize(pointSize × cursorRasterScale)`).
 */
export function spriteRaster(style: CursorStyle, pixel: Size, art: CursorArt | null): SpriteRaster | null {
  const shipped = art?.styles.get(style);
  const exact = shipped?.rasters.find((r) => r.width === pixel.width && r.height === pixel.height);
  if (exact) return { width: exact.width, height: exact.height, rgba: exact.rgba, origin: "swift" };
  if (style === CursorStyle.hand) {
    const one = shipped?.rasters.find((r) => r.scale === 1);
    const two = shipped?.rasters.find((r) => r.scale === 2);
    // CG draws the 32 px rep at ≤ 1× and the 64 px rep above.
    const src = one && pixel.width <= one.width ? one : (two ?? one);
    if (src) {
      return { width: pixel.width, height: pixel.height, rgba: resampleRGBA(src, pixel.width, pixel.height), origin: "resampled" };
    }
    // No shipped Hand artwork (asset fetch failed): the arrow is the only
    // artwork the web can draw — never ship a cursor-less frame silently.
    console.warn("[cursor] Hand artwork unavailable; drawing the macOS arrow instead");
    style = CursorStyle.system;
  }
  const rgba = rasterizeArtwork(style, pixel);
  return rgba ? { width: pixel.width, height: pixel.height, rgba, origin: "analytic" } : null;
}
