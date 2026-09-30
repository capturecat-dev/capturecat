/**
 * Port of Services/BackgroundLook.swift — the backdrop behind the video card:
 * base fill (gradient / mesh / solid / image / wallpaper / transparent) plus
 * the user's "look" (pixelate, halftone, blur, brightness/contrast/saturation,
 * hue, tint, vignette, grain). The Mac preview and exporter both consume the
 * SAME bitmap from `BackgroundLook.cgImage(for:size:scale:)`; the exporter's
 * `createBackground(size:settings:)` is `BackgroundLook.ciImage(for:size:)`,
 * i.e. `cgImage(for: spec, size: outputSize, scale: 1)` (a clear image when
 * nil), so export pixel size == output size.
 *
 * Ported: `Spec.init(settings)`, `isPlainLook`, `isPlainLookExceptNoise`,
 * `gradientAxis`, `blurSigma`, `pixelateScale`, `halftoneWidth`,
 * `maxImageEdge`, the `cgImage` branch decision (`renderPath`), `styled` as
 * ORDERED CoreImage steps (`styledSteps`), and the private `meshImage` pool
 * list (`meshPools`), `noiseRows` / `grained` grain (`noiseRows`,
 * `grainAmplitude`, `applyGrain`) and `aspectFill` rect (`aspectFillRect`).
 * NOT ported: `Spec.cacheKey` (an internal cache key built from Swift
 * `description` strings — not render-affecting; the web keys its own cache)
 * and `decodedImage(path:)` (ImageIO thumbnail decode: the web must decode
 * the uploaded image with EXIF orientation applied and its longest edge
 * capped at `maxImageEdge` = 4096 px, aspect preserved).
 *
 * Locked by the golden-vector units `backgroundLookSpec` (spec, flags, sizes,
 * branch, styled steps — the step oracle is cross-checked byte-for-byte
 * against the real `styled()` during generation), `backgroundMeshPools`,
 * `backgroundGrain`, `backgroundAspectFill`, `backgroundLookPixels` and
 * `backgroundLookStyledPixels` (real bitmaps; see styleSupport.ts for the
 * CPU reference raster and the dithering tolerance), plus `styleConstants`.
 *
 * ── What the GPU passes must do (order is part of the contract) ──────────
 * All look parameters are in PIXELS of the bitmap (`pixelSize` =
 * round(size × scale)); the export renders at scale 1 = output pixels.
 * CoreImage runs these filters in its DEFAULT working space (extended LINEAR
 * sRGB — BackgroundLook's CIContext sets only the output space), on the
 * gamma-encoded sRGB 8-bit base bitmap; the result is re-encoded to 8-bit
 * sRGB (BGRA8, premultiplied). CI space is Y-UP with origin bottom-left:
 * every `inputCenter` below is in that space (web: yDown = H − yUp).
 *  1. clamp + CIPixellate(center (0,0), scale = pixelateScale) + crop, when
 *     scale ≥ 1 — block grid anchored at the BOTTOM-LEFT corner.
 *  2. clamp + CIDotScreen(center (0,0), angle 0, width = halftoneWidth,
 *     sharpness 0.7) + crop, when halftone > 0.
 *  3. clamp + CIGaussianBlur(inputRadius = blurSigma — a SIGMA in px, not a
 *     radius) + crop, when sigma > 0.01. Edges clamp (no fade to clear).
 *  4. CIColorControls(brightness, saturation, contrast) when any differs from
 *     neutral by ≥ 0.0005.
 *  5. CIHueAdjust(angle = hue° · π/180 radians) when |hue| ≥ 0.0005.
 *  6. tint: solid colour (tint rgb, alpha = tint.alpha · clamp(tintOpacity))
 *     composited source-over, when tintOpacity > 0.
 *  7. CIVignetteEffect(center = canvas centre, radius = hypot(W,H)·0.5·(1.1 −
 *     0.5v), intensity = v, falloff 0.5) with v = clamp(vignette), when > 0.
 *  8. crop to the canvas.
 *  9. grain (NOT CoreImage): on the finished 8-bit bitmap, add
 *     `Int(noise · amplitude)` to R,G,B of every pixel (clamped 0…255, alpha
 *     untouched), noise from the 1×-grid cell (x / s, y / s) with
 *     s = max(1, round(scale)) and y counted from the TOP row.
 */
import type { ProjectSettings, Rect, Size } from "../model/types";
import type { BackgroundType } from "../model/enums";
import type { GradientAxis } from "./backgroundGradientRenderer";
import { mix, srgbaFromCodable, srgbaWhite, type SRGBA } from "./oklabGradient";
import { srounded, smax, smin } from "./swift";

/** Largest edge a background image is decoded at (px). */
export const maxImageEdge = 4096;

/** `BackgroundLook.Spec` */
export interface BackgroundSpec {
  type: BackgroundType;
  gradientStart: SRGBA;
  gradientEnd: SRGBA;
  /** null = legacy topLeading→bottomTrailing diagonal. */
  gradientAngle: number | null;
  solid: SRGBA;
  imagePath: string | null;
  blur: number;
  brightness: number;
  saturation: number;
  tint: SRGBA;
  tintOpacity: number;
  vignette: number;
  pixelate: number;
  halftone: number;
  noise: number;
  contrast: number;
  hue: number;
}

export type BackgroundSettings = Pick<
  ProjectSettings,
  | "backgroundType"
  | "gradientStartColor"
  | "gradientEndColor"
  | "gradientAngle"
  | "solidColor"
  | "backgroundImagePath"
  | "backgroundBlur"
  | "backgroundBrightness"
  | "backgroundSaturation"
  | "backgroundTintColor"
  | "backgroundTintOpacity"
  | "backgroundVignette"
  | "backgroundPixelate"
  | "backgroundHalftone"
  | "backgroundNoise"
  | "backgroundContrast"
  | "backgroundHue"
>;

/** `Spec.init(_ s: ProjectSettings)` */
export function specFromSettings(s: BackgroundSettings): BackgroundSpec {
  return {
    type: s.backgroundType,
    gradientStart: srgbaFromCodable(s.gradientStartColor),
    gradientEnd: srgbaFromCodable(s.gradientEndColor),
    gradientAngle: s.gradientAngle ?? null,
    solid: srgbaFromCodable(s.solidColor),
    imagePath: s.backgroundImagePath ?? null,
    blur: s.backgroundBlur,
    brightness: s.backgroundBrightness,
    saturation: s.backgroundSaturation,
    tint: srgbaFromCodable(s.backgroundTintColor),
    tintOpacity: s.backgroundTintOpacity,
    vignette: s.backgroundVignette,
    pixelate: s.backgroundPixelate,
    halftone: s.backgroundHalftone,
    noise: s.backgroundNoise,
    contrast: s.backgroundContrast,
    hue: s.backgroundHue,
  };
}

/** `Spec.isPlainLookExceptNoise` */
export function isPlainLookExceptNoise(spec: BackgroundSpec): boolean {
  return (
    spec.blur <= 0 &&
    Math.abs(spec.brightness) < 0.0005 &&
    Math.abs(spec.saturation - 1) < 0.0005 &&
    spec.tintOpacity <= 0 &&
    spec.vignette <= 0 &&
    spec.pixelate <= 0 &&
    spec.halftone <= 0 &&
    Math.abs(spec.contrast - 1) < 0.0005 &&
    Math.abs(spec.hue) < 0.0005
  );
}

/** `Spec.isPlainLook` */
export function isPlainLook(spec: BackgroundSpec): boolean {
  return spec.noise <= 0 && isPlainLookExceptNoise(spec);
}

/** `gradientAxis(_:)` — `.angle(gradientAngle)` or the legacy `.diagonal`. */
export function gradientAxis(spec: BackgroundSpec): GradientAxis {
  return spec.gradientAngle != null ? { kind: "angle", degrees: spec.gradientAngle } : { kind: "diagonal" };
}

/** `blurSigma(_:pixelSize:)` — Gaussian SIGMA in px. */
export function blurSigma(blur: number, pixelSize: Size): number {
  return smax(0, smin(1, blur)) * 0.06 * smin(pixelSize.width, pixelSize.height);
}

/** `pixelateScale(_:pixelSize:)` — mosaic block edge in px. */
export function pixelateScale(v: number, pixelSize: Size): number {
  return smax(0, smin(1, v)) * 0.08 * smin(pixelSize.width, pixelSize.height);
}

/** `halftoneWidth(_:pixelSize:)` — CIDotScreen cell width in px. */
export function halftoneWidth(v: number, pixelSize: Size): number {
  return 2 + smax(0, smin(1, v)) * 0.04 * smin(pixelSize.width, pixelSize.height);
}

/** `(size × scale).rounded()` per axis — the bitmap size `cgImage` renders. */
export function pixelSizeFor(size: Size, scale: number): Size {
  return { width: srounded(size.width * scale), height: srounded(size.height * scale) };
}

export type BackgroundRenderPath = "nil" | "base" | "baseGrain" | "styled" | "styledGrain";

/**
 * Which branch `cgImage(for:size:scale:)` takes: nil (transparent / empty
 * canvas), the base fill untouched, base + grain, CoreImage `styled` chain,
 * or styled + grain.
 */
export function renderPath(spec: BackgroundSpec, size: Size, scale: number): BackgroundRenderPath {
  if (spec.type === "Transparent") return "nil";
  const px = pixelSizeFor(size, scale);
  if (!(px.width > 0 && px.height > 0)) return "nil";
  if (isPlainLook(spec)) return "base";
  if (isPlainLookExceptNoise(spec)) return spec.noise > 0 ? "baseGrain" : "base";
  return spec.noise > 0 ? "styledGrain" : "styled";
}

/** One CoreImage step, as data (see the module doc for what each does). */
export type CIStep =
  | { op: "clamp" }
  | { op: "crop"; rect: Rect }
  | { op: "filter"; name: string; params: Record<string, number | number[]> }
  | { op: "compositeColorOver"; color: SRGBA; rect: Rect }
  | { op: "cropToSourceIfInfinite" };

/** `styled(base:spec:pixelSize:)` as ordered CI steps (CI Y-up pixel space). */
export function styledSteps(spec: BackgroundSpec, pixelSize: Size): CIStep[] {
  const rect: Rect = { x: 0, y: 0, width: pixelSize.width, height: pixelSize.height };
  const steps: CIStep[] = [];

  const block = pixelateScale(spec.pixelate, pixelSize);
  if (block >= 1) {
    steps.push(
      { op: "clamp" },
      { op: "filter", name: "CIPixellate", params: { inputCenter: [0, 0], inputScale: block } },
      { op: "crop", rect },
    );
  }

  if (spec.halftone > 0) {
    steps.push(
      { op: "clamp" },
      {
        op: "filter",
        name: "CIDotScreen",
        params: {
          inputCenter: [0, 0],
          inputAngle: 0,
          inputWidth: halftoneWidth(spec.halftone, pixelSize),
          inputSharpness: 0.7,
        },
      },
      { op: "crop", rect },
    );
  }

  const sigma = blurSigma(spec.blur, pixelSize);
  if (sigma > 0.01) {
    steps.push(
      { op: "clamp" },
      { op: "filter", name: "CIGaussianBlur", params: { inputRadius: sigma } },
      { op: "crop", rect },
    );
  }

  if (
    Math.abs(spec.brightness) >= 0.0005 ||
    Math.abs(spec.saturation - 1) >= 0.0005 ||
    Math.abs(spec.contrast - 1) >= 0.0005
  ) {
    steps.push({
      op: "filter",
      name: "CIColorControls",
      params: { inputBrightness: spec.brightness, inputSaturation: spec.saturation, inputContrast: spec.contrast },
    });
  }

  if (Math.abs(spec.hue) >= 0.0005) {
    steps.push({ op: "filter", name: "CIHueAdjust", params: { inputAngle: (spec.hue * Math.PI) / 180 } });
  }

  if (spec.tintOpacity > 0) {
    const t = spec.tint;
    steps.push({
      op: "compositeColorOver",
      color: { red: t.red, green: t.green, blue: t.blue, alpha: t.alpha * smax(0, smin(1, spec.tintOpacity)) },
      rect,
    });
  }

  if (spec.vignette > 0) {
    const v = smax(0, smin(1, spec.vignette));
    const radius = Math.hypot(rect.width, rect.height) * 0.5 * (1.1 - 0.5 * v);
    steps.push({
      op: "filter",
      name: "CIVignetteEffect",
      params: {
        inputCenter: [rect.x + rect.width / 2, rect.y + rect.height / 2],
        inputRadius: radius,
        inputIntensity: v,
        inputFalloff: 0.5,
      },
    });
  }

  steps.push({ op: "crop", rect });
  return steps;
}

/** One radial pool of the mesh backdrop. */
export interface MeshPool {
  /** Y-UP pixel space (CG context); web: yDown = H − y. */
  center: { x: number; y: number };
  radius: number;
  /** RGB used for every stop (its own alpha is REPLACED by the stop alpha). */
  color: SRGBA;
  /** (location, alpha) stops of the radial fade, colour→clear. */
  stops: { location: number; alpha: number }[];
}

/**
 * private `meshImage(start:end:pixelSize:)` pool list. The mesh is: the
 * diagonal Oklab base ramp (`BackgroundGradientRenderer.draw`, axis
 * `.diagonal`), then each pool drawn in order with CG `drawRadialGradient`
 * (start radius 0 → end radius, NO extend options — nothing outside the
 * disc), source-over, into the 8-bit premultiplied context.
 */
export function meshPools(start: SRGBA, end: SRGBA, pixelSize: Size): MeshPool[] {
  const ramp = (t: number) => mix(start, end, t);
  const mid = ramp(0.5);
  const lift = mix(mid, srgbaWhite(1), 0.18);
  const sink = mix(mid, srgbaWhite(0), 0.3);
  const pools: [number, number, number, SRGBA, number][] = [
    [0.18, 0.2, 0.85, ramp(0.15), 0.45],
    [0.85, 0.12, 0.75, ramp(0.85), 0.45],
    [0.5, 0.55, 0.8, lift, 0.15],
    [0.15, 0.85, 0.75, sink, 0.45],
    [0.88, 0.82, 0.8, ramp(0.65), 0.45],
    [0.6, 0.32, 0.45, mid, 0.25],
  ];
  const minEdge = smin(pixelSize.width, pixelSize.height);
  const stopTable: [number, number][] = [
    [0, 1],
    [0.4, 0.7],
    [0.75, 0.25],
    [1, 0],
  ];
  return pools.map(([fx, fy, fr, color, alpha]) => ({
    center: { x: fx * pixelSize.width, y: (1 - fy) * pixelSize.height },
    radius: fr * minEdge,
    color,
    stops: stopTable.map(([loc, a]) => ({ location: loc, alpha: a * alpha })),
  }));
}

// ── Grain (private noiseRows / grained) ─────────────────────────────────────

const f32 = Math.fround;

/** (hi, lo) uint32 pair × (hi, lo) uint32 pair, mod 2^64. */
function mul64(ah: number, al: number, bh: number, bl: number): [number, number] {
  const a0 = al & 0xffff;
  const a1 = al >>> 16;
  const b0 = bl & 0xffff;
  const b1 = bl >>> 16;
  const p00 = a0 * b0;
  const p01 = a0 * b1;
  const p10 = a1 * b0;
  const p11 = a1 * b1;
  const mid = (p00 >>> 16) + (p01 & 0xffff) + (p10 & 0xffff);
  const hiOfLo = p11 + Math.floor(p01 / 65536) + Math.floor(p10 / 65536) + Math.floor(mid / 65536);
  const lo = Math.imul(al, bl) >>> 0;
  const hi = (hiOfLo + Math.imul(ah, bl) + Math.imul(al, bh)) >>> 0;
  return [hi, lo];
}

/** v ^ (v >> k) for 0 < k < 32 on a (hi, lo) pair. */
function xorShr(hi: number, lo: number, k: number): [number, number] {
  const shHi = hi >>> k;
  const shLo = ((lo >>> k) | (hi << (32 - k))) >>> 0;
  return [(hi ^ shHi) >>> 0, (lo ^ shLo) >>> 0];
}

const K1 = [0x9e3779b9, 0x7f4a7c15];
const K2 = [0xbf58476d, 0x1ce4e5b9];
const K3 = [0x94d049bb, 0x133111eb];

/** One noise value (Float32, −1…1) for virtual cell (vx, vy). */
export function noiseValue(vx: number, vy: number): number {
  // UInt64(vx) &* K1 ^ UInt64(vy) &* K2   (`^` binds looser than `&*`)
  const [ah, al] = mul64(0, vx >>> 0, K1[0], K1[1]);
  const [bh, bl] = mul64(0, vy >>> 0, K2[0], K2[1]);
  let hi = (ah ^ bh) >>> 0;
  let lo = (al ^ bl) >>> 0;
  [hi, lo] = xorShr(hi, lo, 30);
  [hi, lo] = mul64(hi, lo, K3[0], K3[1]);
  [hi, lo] = xorShr(hi, lo, 27);
  // Float(v & 0xFFFF) / 65535 * 2 - 1, all in Float32.
  return f32(f32(f32(f32(lo & 0xffff) / 65535) * 2) - 1);
}

/** private `noiseRows(width:height:cell:)` — rows[vy][vx], row 0 = TOP. */
export function noiseRows(width: number, height: number, cell: number): number[][] {
  const vw = Math.trunc((width + cell - 1) / cell);
  const vh = Math.trunc((height + cell - 1) / cell);
  const rows: number[][] = [];
  for (let vy = 0; vy < vh; vy++) {
    const row: number[] = new Array(vw);
    for (let vx = 0; vx < vw; vx++) row[vx] = noiseValue(vx, vy);
    rows.push(row);
  }
  return rows;
}

/** `Float(max(0, min(1, amount)) * 14.5)` */
export function grainAmplitude(amount: number): number {
  return f32(smax(0, smin(1, amount)) * 14.5);
}

/** Per-pixel grain delta: `Int(noise * amplitude)` (Float32 product, truncated). */
export function grainDelta(noise: number, amplitude: number): number {
  const v = Math.trunc(f32(noise * amplitude));
  return v === 0 ? 0 : v;
}

/** `max(1, Int(scale.rounded()))` — the grain's 1×-grid cell in px. */
export function grainCell(scale: number): number {
  return smax(1, Math.trunc(srounded(scale)));
}

/**
 * private `grained(_:amount:scale:)` applied to an RGBA8 buffer (row 0 = top,
 * premultiplied — the grain adds to the stored bytes, alpha untouched).
 */
export function applyGrain(rgba: Uint8Array | number[], width: number, height: number, amount: number, scale: number): number[] {
  const out = Array.from(rgba);
  const amplitude = grainAmplitude(amount);
  const s = grainCell(scale);
  const rows = noiseRows(width, height, s);
  for (let y = 0; y < height; y++) {
    const noise = rows[Math.trunc(y / s)];
    for (let x = 0; x < width; x++) {
      const delta = grainDelta(noise[Math.trunc(x / s)], amplitude);
      const p = (y * width + x) * 4;
      for (let c = 0; c < 3; c++) out[p + c] = smax(0, smin(255, out[p + c] + delta));
    }
  }
  return out;
}

/** private `aspectFill(_:pixelSize:)` draw rect (centred; same rect Y-up or Y-down). */
export function aspectFillRect(sourceWidth: number, sourceHeight: number, pixelSize: Size): Rect {
  const sw = sourceWidth;
  const sh = sourceHeight;
  const scale = smax(pixelSize.width / sw, pixelSize.height / sh);
  const w = sw * scale;
  const h = sh * scale;
  return { x: (pixelSize.width - w) / 2, y: (pixelSize.height - h) / 2, width: w, height: h };
}

/**
 * The base fill `baseCGImage(for:pixelSize:)` draws, as data. Image paths
 * that fail to decode fall back: `.wallpaper` → vertical Oklab ramp white
 * 0.16 → 0.09; `.image` → solid black.
 */
export type BaseFill =
  | { kind: "gradient"; start: SRGBA; end: SRGBA; axis: GradientAxis }
  | { kind: "mesh"; start: SRGBA; end: SRGBA }
  | { kind: "solid"; color: SRGBA }
  | { kind: "image"; path: string }
  | { kind: "none" };

/** `baseCGImage` dispatch. `imageDecodes` says whether `imagePath` loaded. */
export function baseFill(spec: BackgroundSpec, imageDecodes: boolean): BaseFill {
  switch (spec.type) {
    case "Gradient":
      return { kind: "gradient", start: spec.gradientStart, end: spec.gradientEnd, axis: gradientAxis(spec) };
    case "Mesh":
      return { kind: "mesh", start: spec.gradientStart, end: spec.gradientEnd };
    case "Solid Color":
      return { kind: "solid", color: spec.solid };
    case "Image":
    case "Wallpaper":
      if (spec.imagePath != null && imageDecodes) return { kind: "image", path: spec.imagePath };
      if (spec.type === "Wallpaper") {
        return { kind: "gradient", start: srgbaWhite(0.16), end: srgbaWhite(0.09), axis: { kind: "vertical" } };
      }
      return { kind: "solid", color: srgbaWhite(0) };
    case "Transparent":
      return { kind: "none" };
  }
}
