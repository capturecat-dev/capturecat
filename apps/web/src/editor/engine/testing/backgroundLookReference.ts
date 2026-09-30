/**
 * CPU reference of `BackgroundLook.cgImage(for:size:scale:)` INCLUDING the
 * CoreImage look chain — the executable spec the WebGPU background bake
 * (`passes/background/`) follows step for step. Float64, per pixel,
 * unoptimised: tests and the lab only.
 *
 * The CoreImage semantics below were measured against the real CIFilters
 * (a scratch CoreImage oracle fed synthetic images; see the pass headers) and
 * are asserted here against REAL Mac bitmaps by the `backgroundLookStyledPixels`
 * golden vectors (`input.gpuTargets`):
 *
 *  - CI works in LINEAR sRGB (extended), premultiplied; the 8-bit sRGB base is
 *    linearised per texel.
 *  - CIPixellate is a WARP: each block reads the SOURCE at the block centre
 *    c + s·(round_even((p − c)/s − ½) + ½) with bilinear filtering of the
 *    8-bit GAMMA texels (clamped), then linearises.
 *  - CIDotScreen (angle 0, sharpness 0.7): per pixel, L = luma(linear) with
 *    CI's weights (0.2125, 0.7154, 0.0721); P = sin(2πx/w) + sin(2πy/w) at the
 *    Y-up pixel centre; out = clamp(½ + (L − ½)/(1 − s) − P·k, 0, 1) grey,
 *    k = 0.9932·s / (4(1 − s)) (the 0.9932 is measured).
 *  - CIGaussianBlur: an exact Gaussian in linear light with clamp-to-edge
 *    (≤ 1/255 vs CI for σ ≥ 2); for σ < 2 CI's kernel is wider — modelled as
 *    σ_eff = √(σ² + 0.09·clamp(2 − σ, 0, 1)).
 *  - CIColorControls: saturation (luma mix, CI weights) → contrast
 *    ((c − ½)·k + ½) → brightness (+b), in linear light, unclamped.
 *  - CIHueAdjust: the SVG/feColorMatrix hueRotate matrix, in linear light.
 *  - Tint: CIColor components are sRGB → linearised, composited source-over.
 *  - CIVignetteEffect: rgb × lin(1 − I·smootherstep((t − (1 − h))/(2h))),
 *    t = |p − centre| / radius, h = ½ + falloff.
 *  - createCGImage(.BGRA8, sRGB): encode, round to 8 bits (premultiplied).
 *  - Grain: exact integer arithmetic on the finished bytes (core applyGrain).
 */
import {
  applyGrain,
  blurSigma,
  halftoneWidth,
  pixelateScale,
  renderPath,
  type BackgroundSpec,
} from "../../core/math/backgroundLook";
import { rasterBackgroundReference } from "../../core/math/styleSupport";
import type { Size } from "../../core/model/types";
import {
  CI_LUMA,
  DOT_SCREEN_GAIN,
  DOT_SCREEN_SHARPNESS,
  VIGNETTE_FALLOFF,
  ciBlurSigma,
  enc,
  hueMatrix,
  lin,
  roundEven,
  smootherstep01,
} from "../passes/background/ciLook";

export { CI_LUMA, DOT_SCREEN_GAIN, ciBlurSigma, enc, hueMatrix, lin, roundEven, smootherstep01 } from "../passes/background/ciLook";

export interface Bitmap {
  width: number;
  height: number;
  /** RGBA8 premultiplied sRGB, row 0 = TOP. */
  rgba: number[];
}

/** The base fill with the look neutralised (plain CG raster). */
function baseBitmap(spec: BackgroundSpec, size: Size, scale: number): Bitmap | null {
  const plain: BackgroundSpec = {
    ...spec,
    blur: 0, brightness: 0, saturation: 1, tintOpacity: 0, vignette: 0,
    pixelate: 0, halftone: 0, noise: 0, contrast: 1, hue: 0,
  };
  return rasterBackgroundReference(plain, size, scale);
}

/** The styled chain on an 8-bit base (`styled` + createCGImage). */
export function styledReference(spec: BackgroundSpec, base: Bitmap): Bitmap {
  const W = base.width;
  const H = base.height;
  const px = { width: W, height: H };
  const n = W * H;
  // gamma texel (straight) at integer Y-UP coords, clamped
  const g = (x: number, yu: number, c: number) => {
    const xi = Math.max(0, Math.min(W - 1, x));
    const yi = Math.max(0, Math.min(H - 1, yu));
    return base.rgba[((H - 1 - yi) * W + xi) * 4 + c] / 255;
  };
  // Linear premultiplied working image.
  let img = new Float64Array(n * 4);
  const toLinear = (rgb: number[], a: number, o: number) => {
    for (let c = 0; c < 3; c++) img[o + c] = a > 0 ? lin(rgb[c] / a) * a : 0;
    img[o + 3] = a;
  };

  const block = pixelateScale(spec.pixelate, px);
  if (block >= 1) {
    for (let yd = 0; yd < H; yd++) {
      for (let x = 0; x < W; x++) {
        const yu = H - 1 - yd;
        const bx = (roundEven((x + 0.5) / block - 0.5) + 0.5) * block;
        const by = (roundEven((yu + 0.5) / block - 0.5) + 0.5) * block;
        const sx = bx - 0.5;
        const sy = by - 0.5;
        const x0 = Math.floor(sx);
        const y0 = Math.floor(sy);
        const fx = sx - x0;
        const fy = sy - y0;
        const v = [0, 1, 2, 3].map(
          (c) =>
            (g(x0, y0, c) * (1 - fx) + g(x0 + 1, y0, c) * fx) * (1 - fy) +
            (g(x0, y0 + 1, c) * (1 - fx) + g(x0 + 1, y0 + 1, c) * fx) * fy,
        );
        toLinear(v, v[3], (yd * W + x) * 4);
      }
    }
  } else {
    for (let i = 0; i < n; i++) {
      const v = [0, 1, 2, 3].map((c) => base.rgba[i * 4 + c] / 255);
      toLinear(v, v[3], i * 4);
    }
  }

  if (spec.halftone > 0) {
    const width = halftoneWidth(spec.halftone, px);
    const s = DOT_SCREEN_SHARPNESS;
    const k = (DOT_SCREEN_GAIN * s) / (4 * (1 - s));
    const w2 = (2 * Math.PI) / width;
    const out = new Float64Array(n * 4);
    for (let yd = 0; yd < H; yd++) {
      for (let x = 0; x < W; x++) {
        const o = (yd * W + x) * 4;
        const a = img[o + 3];
        // Luma of the PREMULTIPLIED colour; the grey is re-premultiplied by
        // the source alpha (measured: white @ α 160/255 → 150).
        const L = img[o] * CI_LUMA[0] + img[o + 1] * CI_LUMA[1] + img[o + 2] * CI_LUMA[2];
        const P = Math.sin(w2 * (x + 0.5)) + Math.sin(w2 * (H - yd - 0.5));
        const v = Math.max(0, Math.min(1, 0.5 + (L - 0.5) / (1 - s) - P * k));
        out[o] = out[o + 1] = out[o + 2] = v * a;
        out[o + 3] = a;
      }
    }
    img = out;
  }

  const sigma = blurSigma(spec.blur, px);
  if (sigma > 0.01) {
    const se = ciBlurSigma(sigma);
    const r = Math.ceil(se * 4);
    const kern: number[] = [];
    let ks = 0;
    for (let i = -r; i <= r; i++) {
      const v = Math.exp(-(i * i) / (2 * se * se));
      kern.push(v);
      ks += v;
    }
    const pass = (src: Float64Array, dx: number, dy: number) => {
      const dst = new Float64Array(n * 4);
      for (let y = 0; y < H; y++) {
        for (let x = 0; x < W; x++) {
          const o = (y * W + x) * 4;
          for (let i = -r; i <= r; i++) {
            const sx = Math.max(0, Math.min(W - 1, x + dx * i));
            const sy = Math.max(0, Math.min(H - 1, y + dy * i));
            const q = (sy * W + sx) * 4;
            const wgt = kern[i + r] / ks;
            for (let c = 0; c < 4; c++) dst[o + c] += wgt * src[q + c];
          }
        }
      }
      return dst;
    };
    img = pass(pass(img, 1, 0), 0, 1);
  }

  const doColor =
    Math.abs(spec.brightness) >= 0.0005 || Math.abs(spec.saturation - 1) >= 0.0005 || Math.abs(spec.contrast - 1) >= 0.0005;
  const doHue = Math.abs(spec.hue) >= 0.0005;
  const hm = hueMatrix((spec.hue * Math.PI) / 180);
  const tintA = spec.tintOpacity > 0 ? spec.tint.alpha * Math.max(0, Math.min(1, spec.tintOpacity)) : 0;
  const tint = [lin(spec.tint.red), lin(spec.tint.green), lin(spec.tint.blue)];
  const v = Math.max(0, Math.min(1, spec.vignette));
  const vRadius = Math.hypot(W, H) * 0.5 * (1.1 - 0.5 * v);
  const hw = 0.5 + VIGNETTE_FALLOFF;
  const out: number[] = new Array(n * 4);
  for (let yd = 0; yd < H; yd++) {
    for (let x = 0; x < W; x++) {
      const o = (yd * W + x) * 4;
      let a = img[o + 3];
      let c = [0, 1, 2].map((k) => (a > 0 ? img[o + k] / a : 0));
      if (doColor) {
        const l = c[0] * CI_LUMA[0] + c[1] * CI_LUMA[1] + c[2] * CI_LUMA[2];
        c = c.map((q) => l + (q - l) * spec.saturation);
        c = c.map((q) => (q - 0.5) * spec.contrast + 0.5 + spec.brightness);
      }
      if (doHue) {
        c = [
          hm[0] * c[0] + hm[1] * c[1] + hm[2] * c[2],
          hm[3] * c[0] + hm[4] * c[1] + hm[5] * c[2],
          hm[6] * c[0] + hm[7] * c[1] + hm[8] * c[2],
        ];
      }
      let pm = c.map((q) => q * a);
      if (tintA > 0) {
        pm = pm.map((q, k) => tint[k] * tintA + q * (1 - tintA));
        a = tintA + a * (1 - tintA);
      }
      if (v > 0) {
        const t = Math.hypot(x + 0.5 - W / 2, H - yd - 0.5 - H / 2) / vRadius;
        const m = lin(1 - v * smootherstep01((t - (1 - hw)) / (2 * hw)));
        pm = pm.map((q) => q * m);
      }
      const qa = Math.round(Math.max(0, Math.min(1, a)) * 255);
      for (let k = 0; k < 3; k++) out[o + k] = qa > 0 ? Math.round(enc(pm[k] / Math.max(a, 1e-9)) * qa) : 0;
      out[o + 3] = qa;
    }
  }
  return { width: W, height: H, rgba: out };
}

/** The whole `cgImage(for:size:scale:)` (null = nil / transparent). */
export function backgroundLookReference(spec: BackgroundSpec, size: Size, scale: number): Bitmap | null {
  const path = renderPath(spec, size, scale);
  if (path === "nil") return null;
  const base = baseBitmap(spec, size, scale);
  if (!base) return null;
  let bmp = path === "styled" || path === "styledGrain" ? styledReference(spec, base) : base;
  if (path === "baseGrain" || path === "styledGrain") {
    bmp = { ...bmp, rgba: applyGrain(bmp.rgba, bmp.width, bmp.height, spec.noise, scale) };
  }
  return bmp;
}
