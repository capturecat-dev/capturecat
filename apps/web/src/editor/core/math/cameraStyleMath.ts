/**
 * Port of Services/CameraStyleMath.swift — camera-bubble styling shared by the
 * Mac preview compositor and exporter: colour adjustments + filter presets,
 * shape corner radius / clip path (circle, squircle superellipse, rounded
 * rect, square), border colour, ring light recipe, and the name-tag layout.
 *
 * Locked by the golden-vector units `cameraStyleAdjustments`,
 * `cameraStyleShapes`, `cameraStyleBorderColor`, `cameraStyleRing`,
 * `cameraStyleTagRect`, `cameraStyleTagLayout`, `cameraStyleTagBitmap`,
 * `cameraStyleTagTextMetrics`, `cgPathPrimitives` and `styleConstants`.
 *
 * ── adjustedImage(_:adjustments:) → `adjustedImageSteps` (CI steps as data)
 * Preset FIRST, then manual sliders; identity → the input untouched (no
 * steps). In the exporter the chain runs in the export CIContext whose
 * working space is the SOURCE's non-linear space (sRGB, or Display P3 for P3
 * sources — VideoColorTags.renderColorSpace), i.e. on gamma-encoded values.
 *   CIPhotoEffectMono / CIPhotoEffectNoir / CIPhotoEffectFade — Apple's
 *     "Photos" presets (no parameters; LUT-like colour maps).
 *   CITemperatureAndTint(inputNeutral (6500, 0), inputTargetNeutral
 *     (5100, 0) warm | (8200, 0) cool) — white-balance shift.
 *   CIColorControls(inputBrightness, inputContrast, inputSaturation) — only
 *     when brightness ≠ 0 or contrast ≠ 1 or saturation ≠ 1.
 *   CIHueAdjust(inputAngle = hue° · π / 180) — only when hue ≠ 0.
 *   cropToSourceIfInfinite — pin an infinite extent back to the input's.
 * The pixel semantics of these CoreImage filters are Apple-internal; the web
 * GPU pass must be validated against real Mac output (render-parity gate).
 *
 * ── Text (name tag) — NOT portable: the tag font is `NSFont(name:size:)` or
 * the system font SEMIBOLD (SF Pro). `tagLayout` / `tagBitmapRecipe` take the
 * measured line sizes (`NSAttributedString.size()`) as an injected `measure`
 * callback; the web must measure with a metrically identical font (SF Pro
 * Semibold where licensed, else expect pill-width drift). Swift-measured
 * sizes for representative strings are recorded in `cameraStyleTagTextMetrics`.
 */
import type { ProjectSettings, Rect, Size } from "../model/types";
import type { CameraFilterStyle, CameraShape, CameraTagPosition } from "../model/enums";
import type { CIStep } from "./backgroundLook";
import { maxY, midX, midY, minY, rectHeight, rectWidth } from "./geometry";
import type { SRGBA } from "./oklabGradient";
import { cgPathEllipse, cgPathRect, cgPathRoundedRect, type PathElement } from "./styleSupport";
import { smax, smin } from "./swift";

// ── Colour adjustments ──────────────────────────────────────────────────────

/** `CameraStyleMath.Adjustments` */
export interface CameraAdjustments {
  brightness: number;
  contrast: number;
  saturation: number;
  hue: number;
  filter: CameraFilterStyle;
}

export const identityAdjustments: CameraAdjustments = Object.freeze({
  brightness: 0,
  contrast: 1,
  saturation: 1,
  hue: 0,
  filter: "None" as CameraFilterStyle,
});

/** `Adjustments(settings:)` */
export function adjustmentsFromSettings(
  s: Pick<ProjectSettings, "cameraBrightness" | "cameraContrast" | "cameraSaturation" | "cameraHue" | "cameraFilter">,
): CameraAdjustments {
  return {
    brightness: s.cameraBrightness,
    contrast: s.cameraContrast,
    saturation: s.cameraSaturation,
    hue: s.cameraHue,
    filter: s.cameraFilter,
  };
}

/** `isIdentity` — synthesized Equatable against `.identity` (NaN ≠ NaN, −0 == 0). */
export function isIdentity(a: CameraAdjustments): boolean {
  return (
    a.brightness === identityAdjustments.brightness &&
    a.contrast === identityAdjustments.contrast &&
    a.saturation === identityAdjustments.saturation &&
    a.hue === identityAdjustments.hue &&
    a.filter === identityAdjustments.filter
  );
}

/** CITemperatureAndTint neutral (input) and the Warm/Cool target neutrals. */
export const temperatureNeutral = [6500, 0];
export const warmTargetNeutral = [5100, 0];
export const coolTargetNeutral = [8200, 0];

/** `adjustedImage(_:adjustments:)` as ordered CI steps ([] = identity, image untouched). */
export function adjustedImageSteps(a: CameraAdjustments): CIStep[] {
  if (isIdentity(a)) return [];
  const steps: CIStep[] = [];
  switch (a.filter) {
    case "None":
      break;
    case "Mono":
      steps.push({ op: "filter", name: "CIPhotoEffectMono", params: {} });
      break;
    case "Noir":
      steps.push({ op: "filter", name: "CIPhotoEffectNoir", params: {} });
      break;
    case "Fade":
      steps.push({ op: "filter", name: "CIPhotoEffectFade", params: {} });
      break;
    case "Warm":
      steps.push({
        op: "filter",
        name: "CITemperatureAndTint",
        params: { inputNeutral: temperatureNeutral, inputTargetNeutral: warmTargetNeutral },
      });
      break;
    case "Cool":
      steps.push({
        op: "filter",
        name: "CITemperatureAndTint",
        params: { inputNeutral: temperatureNeutral, inputTargetNeutral: coolTargetNeutral },
      });
      break;
  }
  if (a.brightness !== 0 || a.contrast !== 1 || a.saturation !== 1) {
    steps.push({
      op: "filter",
      name: "CIColorControls",
      params: { inputBrightness: a.brightness, inputContrast: a.contrast, inputSaturation: a.saturation },
    });
  }
  if (a.hue !== 0) {
    steps.push({ op: "filter", name: "CIHueAdjust", params: { inputAngle: (a.hue * Math.PI) / 180 } });
  }
  steps.push({ op: "cropToSourceIfInfinite" });
  return steps;
}

// ── Shape ───────────────────────────────────────────────────────────────────

/** `cornerRadius(shape:customRadius:scale:)` — only the rounded rect has one. */
export function cornerRadius(shape: CameraShape, customRadius: number, scale: number): number {
  switch (shape) {
    case "Rounded Rectangle":
      return smax(0, customRadius) * scale;
    case "Circle":
    case "Square":
    case "Squircle":
      return 0;
  }
}

export const squircleExponent = 4.5;
export const squircleSamples = 256;

/**
 * `superellipsePath(in:)` — 256-point closed polyline of |x/a|ⁿ + |y/b|ⁿ = 1,
 * n = 4.5, uniform in the parametric angle, starting at (maxX, midY).
 */
export function superellipsePath(rect: Rect): PathElement[] {
  const a = rectWidth(rect) / 2;
  const b = rectHeight(rect) / 2;
  const cx = midX(rect);
  const cy = midY(rect);
  const exponent = 2.0 / squircleExponent;
  const out: PathElement[] = [];
  for (let i = 0; i < squircleSamples; i++) {
    const t = (i / squircleSamples) * 2 * Math.PI;
    const c = Math.cos(t);
    const s = Math.sin(t);
    const x = cx + a * (c < 0 ? -1 : 1) * Math.pow(Math.abs(c), exponent);
    const y = cy + b * (s < 0 ? -1 : 1) * Math.pow(Math.abs(s), exponent);
    out.push({ op: i === 0 ? "move" : "line", pts: [{ x, y }] });
  }
  out.push({ op: "close", pts: [] });
  return out;
}

/** `clipPath(shape:customRadius:rect:scale:)` — the one camera clip path. */
export function clipPath(shape: CameraShape, customRadius: number, rect: Rect, scale: number): PathElement[] {
  switch (shape) {
    case "Circle":
      return cgPathEllipse(rect);
    case "Squircle":
      return superellipsePath(rect);
    case "Rounded Rectangle": {
      const r = smin(cornerRadius("Rounded Rectangle", customRadius, scale), smin(rectWidth(rect), rectHeight(rect)) / 2);
      if (!(r > 0)) return cgPathRect(rect);
      return cgPathRoundedRect(rect, r, r);
    }
    case "Square":
      return cgPathRect(rect);
  }
}

// ── Border ──────────────────────────────────────────────────────────────────

/**
 * `borderNSColor(_:)` in sRGB components: the stored colour, else the
 * historical white at 30% (`NSColor(white: 1, alpha: 0.3)`, which converts
 * to sRGB (1, 1, 1, 0.3) — see `cameraStyleBorderColor`).
 */
export function borderColor(s: Pick<ProjectSettings, "cameraBorderColor">): SRGBA {
  const c = s.cameraBorderColor;
  if (c) return { red: c.red, green: c.green, blue: c.blue, alpha: c.opacity };
  return { red: 1, green: 1, blue: 1, alpha: 0.3 };
}

// ── Ring light ──────────────────────────────────────────────────────────────

export const ringOutsideFraction = 0.12;
export const ringColor = Object.freeze({ r: 1.0, g: 0.93, b: 0.82 });
export const ringPeakAlpha = 0.55;
export const ringSigmaFraction = 0.34;

/** `ringPadding(for:)` — outward reach of the glow. */
export function ringPadding(size: Size): number {
  return smin(size.width, size.height) * ringOutsideFraction;
}

/**
 * The numbers `ringImage(size:shape:customRadius:intensity:scale:)` renders
 * with (null where it returns nil). Recipe, all in the bitmap's CG Y-UP space
 * (the drawing is symmetric on both axes, so Y-down is identical):
 *  1. `pxW × pxH` RGBA8 premultiplied sRGB bitmap, CTM scaled by `scale`;
 *     fill `path` (the clip path of `bubbleRect`, in points) with ringColor
 *     at alpha 1.
 *  2. CIGaussianBlur(inputRadius = `sigma` — a SIGMA in px) of that bitmap
 *     (NOT clamped: edges fade to clear), in a CIContext whose working AND
 *     output space is sRGB (non-linear), cropped to (0, 0, pxW, pxH).
 *  3. New bitmap, CTM scaled by `scale`; clip to (0,0,padded) ∪ path with the
 *     EVEN-ODD rule (i.e. keep only OUTSIDE the shape); draw the blurred
 *     image over (0, 0, padded) at global alpha `alpha`.
 * Placement: the bitmap sits at bubble origin − (pad, pad).
 */
export interface RingRecipe {
  level: number;
  pad: number;
  padded: Size;
  pxW: number;
  pxH: number;
  bubbleRect: Rect;
  path: PathElement[];
  sigma: number;
  alpha: number;
}

export function ringRecipe(
  size: Size,
  shape: CameraShape,
  customRadius: number,
  intensity: number,
  scale: number,
): RingRecipe | null {
  const level = smin(1, smax(0, intensity));
  if (!(level > 0 && size.width >= 2 && size.height >= 2)) return null;
  const pad = ringPadding(size);
  const padded = { width: size.width + 2 * pad, height: size.height + 2 * pad };
  const pxW = Math.trunc(Math.ceil(padded.width * scale));
  const pxH = Math.trunc(Math.ceil(padded.height * scale));
  if (!(pxW > 0 && pxH > 0)) return null;
  const bubbleRect: Rect = { x: pad, y: pad, width: size.width, height: size.height };
  const path = clipPath(shape, customRadius, bubbleRect, 1);
  const sigma = pad * ringSigmaFraction * (0.8 + 0.4 * level) * scale;
  const alpha = smin(1, 2 * ringPeakAlpha * level);
  return { level, pad, padded, pxW, pxH, bubbleRect, path, sigma, alpha };
}

// ── Name tag ────────────────────────────────────────────────────────────────

export const tagFontFraction = 0.115;
export const tagSubtextFontScale = 0.78;
export const tagHPaddingFactor = 0.9;
export const tagVPaddingFactor = 0.42;
export const tagGapFactor = 0.35;

export interface TagLayout {
  pillSize: Size;
  fontSize: number;
  subFontSize: number;
}

/** `NSAttributedString.size()` of `text` in the tag font (`fontName` or system semibold) at `fontSize`. */
export type TagMeasure = (text: string, fontName: string | null, fontSize: number) => Size;

/**
 * Swift `trimmingCharacters(in: .whitespacesAndNewlines)`: Unicode Z* plus
 * U+0009–U+000D and U+0085 (NOT String.prototype.trim, which also strips
 * U+FEFF and keeps U+0085).
 */
export function swiftTrimWhitespacesAndNewlines(s: string): string {
  const ws = /^[\p{Z}\t\n\v\f\r\u0085]+|[\p{Z}\t\n\v\f\r\u0085]+$/gu;
  return s.replace(ws, "");
}

type TagSettings = Pick<ProjectSettings, "cameraTagText" | "cameraTagSubtext" | "cameraTagFontName">;

/** `tagLayout(settings:bubbleWidth:)` with injected text measurement. */
export function tagLayout(s: TagSettings, bubbleWidth: number, measure: TagMeasure): TagLayout | null {
  const text = swiftTrimWhitespacesAndNewlines(s.cameraTagText);
  if (!(text.length > 0 && bubbleWidth > 8)) return null;
  const fontSize = smax(8, bubbleWidth * tagFontFraction);
  const subSize = smax(7, fontSize * tagSubtextFontScale);
  const sub = swiftTrimWhitespacesAndNewlines(s.cameraTagSubtext);
  const fontName = s.cameraTagFontName ?? null;

  const main = measure(text, fontName, fontSize);
  let textW = Math.ceil(main.width);
  let textH = Math.ceil(main.height);
  if (sub.length > 0) {
    const subLine = measure(sub, fontName, subSize);
    textW = smax(textW, Math.ceil(subLine.width));
    textH += Math.ceil(subLine.height);
  }
  const hPad = fontSize * tagHPaddingFactor;
  const vPad = fontSize * tagVPaddingFactor;
  const maxW = bubbleWidth * 2.2;
  return {
    pillSize: { width: smin(textW + 2 * hPad, maxW), height: textH + 2 * vPad },
    fontSize,
    subFontSize: subSize,
  };
}

/** `tagRect(bubbleRect:pillSize:position:yAxisIsUp:)` */
export function tagRect(bubbleRect: Rect, pillSize: Size, position: CameraTagPosition, yAxisIsUp: boolean): Rect {
  const x = midX(bubbleRect) - pillSize.width / 2;
  const gap = pillSize.height * tagGapFactor;
  let y: number;
  switch (position) {
    case "Below":
      y = yAxisIsUp ? minY(bubbleRect) - gap - pillSize.height : maxY(bubbleRect) + gap;
      break;
    case "Above":
      y = yAxisIsUp ? maxY(bubbleRect) + gap : minY(bubbleRect) - gap - pillSize.height;
      break;
    case "Overlap Bottom":
      y = yAxisIsUp ? minY(bubbleRect) - pillSize.height / 2 : maxY(bubbleRect) - pillSize.height / 2;
      break;
  }
  return { x, y, width: pillSize.width, height: pillSize.height };
}

/**
 * The non-text numbers of `tagBitmap(settings:bubbleWidth:scale:)`. Recipe
 * (bitmap CG Y-UP, CTM scaled by `scale`, units = layout points):
 *  - fill `pillPath` (rounded rect (0,0,pill) with corner = pill.height/2,
 *    which CG clamps to half the width for narrow pills) with `background`;
 *  - draw the main line (tag font at `fontSize`, `textColor`, centred) in
 *    `mainRect`; the subtext (font at `subFontSize`, textColor with alpha ×
 *    0.75) in `subRect`. Each rect's TOP edge (Y-up maxY) is where AppKit
 *    starts the line box (ascender at the top, centred horizontally).
 * Web (Y-down, pill height H): rect y' = H − (y + height).
 */
export interface TagBitmapRecipe {
  layout: TagLayout;
  pxW: number;
  pxH: number;
  radius: number;
  pillPath: PathElement[];
  background: SRGBA;
  textColor: SRGBA;
  subTextColor: SRGBA;
  mainH: number;
  subH: number;
  topY: number;
  inset: number;
  mainRect: Rect;
  subRect: Rect | null;
}

export function tagBitmapRecipe(
  s: TagSettings & Pick<ProjectSettings, "cameraTagBackgroundColor" | "cameraTagTextColor">,
  bubbleWidth: number,
  scale: number,
  measure: TagMeasure,
): TagBitmapRecipe | null {
  const layout = tagLayout(s, bubbleWidth, measure);
  if (!layout) return null;
  const pill = layout.pillSize;
  const pxW = Math.trunc(Math.ceil(pill.width * scale));
  const pxH = Math.trunc(Math.ceil(pill.height * scale));
  if (!(pxW > 0 && pxH > 0)) return null;
  const radius = pill.height / 2;
  const bg = s.cameraTagBackgroundColor;
  const tc = s.cameraTagTextColor;
  const text = swiftTrimWhitespacesAndNewlines(s.cameraTagText);
  const sub = swiftTrimWhitespacesAndNewlines(s.cameraTagSubtext);
  const fontName = s.cameraTagFontName ?? null;
  const mainH = Math.ceil(measure(text, fontName, layout.fontSize).height);
  const subH = sub.length > 0 ? Math.ceil(measure(sub, fontName, layout.subFontSize).height) : 0;
  const totalH = mainH + subH;
  const topY = (pill.height + totalH) / 2;
  const inset = layout.fontSize * 0.3;
  return {
    layout,
    pxW,
    pxH,
    radius,
    pillPath: cgPathRoundedRect({ x: 0, y: 0, width: pill.width, height: pill.height }, radius, radius),
    background: { red: bg.red, green: bg.green, blue: bg.blue, alpha: bg.opacity },
    textColor: { red: tc.red, green: tc.green, blue: tc.blue, alpha: tc.opacity },
    subTextColor: { red: tc.red, green: tc.green, blue: tc.blue, alpha: tc.opacity * 0.75 },
    mainH,
    subH,
    topY,
    inset,
    mainRect: { x: inset, y: topY - mainH, width: pill.width - 2 * inset, height: mainH },
    subRect: sub.length > 0 ? { x: inset, y: topY - mainH - subH, width: pill.width - 2 * inset, height: subH } : null,
  };
}

// -- System-font tag line height ------------------------------------------------

/**
 * Line height (NSAttributedString.size().height) of the SYSTEM SEMIBOLD tag
 * font (SF Pro with optical sizes) as a function of point size: an integer
 * step function, independent of the text, with ONE non-monotone step (the
 * Text/Display optical switch at 21 pt: 25 at 20.17 pt, 24 from 21 pt).
 * Breakpoints [start size, height] measured on macOS (scan every 0.01 pt,
 * bisected to 1e-9 pt) over 7 to 300 pt; the height holds from its start
 * size up to the next start. Locked by the cameraStyleTagLineHeights unit.
 * Use it for the default tag font whatever font the browser ends up drawing
 * with, so the pill HEIGHT matches the Mac exactly.
 */
export const systemTagLineHeightTable: ReadonlyArray<readonly [number, number]> = [
  [7.0, 9], [7.757575758099556, 10], [8.791919192075733, 11], [9.481955555677413, 12],
  [9.82626262664795, 13], [10.860606060624121, 14], [11.89494949519634, 15], [12.929292929768565, 16],
  [13.963636363744737, 17], [14.222696296572686, 18], [14.997979798316956, 19], [16.032323232889176, 20],
  [17.066666666865352, 21], [18.101010101437573, 22], [18.963437037467955, 23], [19.13535353541375, 24],
  [20.169696969985964, 25], [21.000000000596046, 24], [21.204040404558185, 25], [21.3333333337307, 26],
  [22.238383838534354, 27], [23.272727273106575, 28], [24.307070707082744, 29], [25.34141414165497, 30],
  [26.074074074625976, 31], [26.375757576227187, 32], [27.410101010203363, 33], [28.444444444775584, 34],
  [29.4787878793478, 35], [30.513131313323978, 36], [30.814814814925185, 37], [31.54747474789619, 38],
  [32.581818181872364, 39], [33.6161616164446, 40], [34.65050505101681, 41], [35.555555555820476, 42],
  [35.68484848499298, 43], [36.719191919565205, 44], [37.753535353541366, 45], [38.78787878811359, 46],
  [39.82222222268581, 47], [40.29629629671574, 48], [40.856565656661985, 49], [41.89090909123421, 50],
  [42.92525252580644, 51], [43.959595959782604, 52], [44.993939394354825, 53], [45.037037037611015, 54],
  [46.028282828331, 55], [47.06262626290322, 56], [48.09696969747543, 57], [49.13131313145162, 58],
  [49.777777777910245, 59], [50.16565656602384, 60], [51.2, 61], [52.23434343457221, 62],
  [53.26868686914443, 63], [54.30303030312062, 64], [54.51851851880551, 65], [55.33737373769283, 66],
  [56.37171717226505, 67], [57.406060606241226, 68], [58.44040404081343, 69], [59.259259259700755, 70],
  [59.47474747478961, 71], [60.50909090936183, 72], [61.54343434393407, 73], [62.57777777791024, 74],
  [63.61212121248245, 75], [64.0, 76], [64.6464646470547, 77], [65.68080808103083, 78],
  [66.71515151560307, 79], [67.7494949495792, 80], [68.7407407408953, 81], [68.78383838415144, 82],
  [69.81818181872367, 83], [70.85252525269985, 84], [71.88686868727207, 85], [72.92121212124826, 86],
  [73.48148148179055, 87], [73.9555555558205, 88], [74.98989899039267, 89], [76.02424242436886, 90],
  [77.05858585894107, 91], [78.09292929351331, 92], [78.2222222226858, 93], [79.12727272748947, 94],
  [80.16161616206168, 95], [81.19595959603784, 96], [82.23030303061007, 97], [82.96296296298503, 98],
  [83.26464646518231, 99], [84.29898989915847, 100], [85.3333333337307, 101], [86.36767676770687, 102],
  [87.4020202022791, 103], [87.70370370388031, 104], [88.43636363685131, 105], [89.47070707082747, 106],
  [90.50505050539968, 107], [91.53939393997193, 108], [92.44444444477556, 109], [92.5737373739481, 110],
  [93.60808080852031, 111], [94.6424242424965, 112], [95.67676767706871, 113], [96.71111111164095, 114],
  [97.18518518567086, 115], [97.74545454561711, 116], [98.77979798018931, 117], [99.8141414141655, 118],
  [100.84848484873771, 119], [101.88282828330995, 120], [101.92592592597006, 121], [102.91717171728608, 122],
  [103.95151515185835, 123], [104.98585858643055, 124], [106.02020202040671, 125], [106.66666666686534, 126],
  [107.05454545497895, 127], [108.08888888895511, 128], [109.12323232352735, 129], [110.15757575809955, 130],
  [111.19191919207572, 131], [111.40740740776062, 132], [112.22626262664795, 133], [113.26060606062413, 134],
  [114.29494949519635, 135], [115.32929292976858, 136], [116.14814814865592, 137], [116.36363636374475, 138],
  [117.39797979831695, 139], [118.43232323288919, 140], [119.46666666686535, 141], [120.50101010143756, 142],
  [120.8888888889551, 143], [121.53535353541375, 144], [122.56969696998598, 145], [123.60404040455819, 146],
  [124.63838383853435, 147], [125.62962962985037, 148], [125.67272727310659, 149], [126.70707070708275, 150],
  [127.74141414165499, 151], [128.77575757622716, 152], [129.8101010102033, 153], [130.37037037074566, 154],
  [130.8444444447756, 155], [131.87878787934778, 156], [132.91313131332402, 157], [133.94747474789617, 158],
  [134.98181818187237, 159], [135.11111111164098, 160], [136.0161616164446, 161], [137.05050505101684, 162],
  [138.08484848499302, 163], [139.11919191956517, 164], [139.85185185194013, 165], [140.15353535354137, 166],
  [141.1878787881136, 167], [142.2222222226858, 168], [143.25656565666196, 169], [144.29090909123417, 170],
  [144.59259259283544, 171], [145.32525252580643, 172], [146.3595959597826, 173], [147.39393939435485, 174],
  [148.42828282833102, 175], [149.33333333373068, 176], [149.46262626290323, 177], [150.49696969747544, 178],
  [151.5313131314516, 179], [152.56565656602385, 180], [153.6, 181], [154.07407407462597, 182],
  [154.63434343457217, 183], [155.6686868691445, 184], [156.7030303031206, 185], [157.7373737376928, 186],
  [158.77171717226508, 187], [158.81481481492517, 188], [159.80606060624123, 189], [160.84040404081344, 190],
  [161.87474747478961, 191], [162.90909090936185, 192], [163.5555555558205, 193], [163.9434343439341, 194],
  [164.97777777791023, 195], [166.01212121248244, 196], [167.0464646470547, 197], [168.08080808103085, 198],
  [168.2962962967158, 199], [169.1151515156031, 200], [170.14949494957924, 201], [171.18383838415144, 202],
  [172.21818181872365, 203], [173.037037037611, 204], [173.25252525269985, 205], [174.2868686872721, 206],
  [175.32121212124824, 207], [176.3555555558205, 208], [177.3898989903927, 209], [177.77777777791025, 210],
  [178.42424242436886, 211], [179.45858585894115, 212], [180.49292929351333, 213], [181.52727272748945, 214],
  [182.51851851880548, 215], [182.56161616206165, 216], [183.59595959603786, 217], [184.6303030306101, 218],
  [185.66464646518233, 219], [186.69898989915845, 220], [187.25925925970074, 221], [187.7333333337307, 222],
  [188.7676767677068, 223], [189.8020202022791, 224], [190.83636363685127, 225], [191.8707070708275, 226],
  [192.0, 227], [192.90505050539974, 228], [193.93939393997192, 229], [194.9737373739481, 230],
  [196.00808080852033, 231], [196.74074074089532, 232], [197.0424242424965, 233], [198.07676767706872, 234],
  [199.11111111164098, 235], [200.1454545456171, 236], [201.17979798018928, 237], [201.4814814817906, 238],
  [202.2141414141655, 239], [203.24848484873772, 240], [204.28282828330993, 241], [205.3171717172861, 242],
  [206.22222222268584, 243], [206.35151515185834, 244], [207.38585858643057, 245], [208.42020202040678, 246],
  [209.45454545497898, 247], [210.4888888889551, 248], [210.96296296298505, 249], [211.52323232352728, 250],
  [212.55757575809957, 251], [213.59191919207572, 252], [214.62626262664793, 253], [215.6606060606241, 254],
  [215.7037037038803, 255], [216.69494949519634, 256], [217.72929292976858, 257], [218.76363636374472, 258],
  [219.797979798317, 259], [220.44444444477557, 260], [220.8323232328892, 261], [221.86666666686534, 262],
  [222.90101010143763, 263], [223.93535353541373, 264], [224.969696969986, 265], [225.18518518567086, 266],
  [226.0040404045582, 267], [227.03838383853434, 268], [228.07272727310658, 269], [229.10707070708273, 270],
  [229.92592592597006, 271], [230.14141414165493, 272], [231.1757575762272, 273], [232.21010101020335, 274],
  [233.24444444477558, 275], [234.27878787934782, 276], [234.66666666686535, 277], [235.313131313324, 278],
  [236.3474747478962, 279], [237.38181818187235, 280], [238.41616161644464, 281], [239.40740740776062, 282],
  [239.45050505101682, 283], [240.484848484993, 284], [241.5191919195652, 285], [242.55353535354135, 286],
  [243.58787878811358, 287], [244.14814814865593, 288], [244.62222222268582, 289], [245.656565656662, 290],
  [246.6909090912342, 291], [247.72525252580647, 292], [248.7595959597826, 293], [248.88888888895514, 294],
  [249.79393939435482, 295], [250.828282828331, 296], [251.86262626290326, 297], [252.89696969747547, 298],
  [253.62962962985037, 299], [253.9313131314516, 300], [254.96565656602382, 301], [256.0, 302],
  [257.0343434345722, 303], [258.0686868691444, 304], [258.3703703707457, 305], [259.1030303031206, 306],
  [260.1373737376929, 307], [261.17171717226506, 308], [262.2060606062413, 309], [263.111111111641, 310],
  [263.24040404081353, 311], [264.2747474747895, 312], [265.3090909093619, 313], [266.34343434393406, 314],
  [267.3777777779102, 315], [267.8518518519401, 316], [268.4121212124824, 317], [269.44646464705454, 318],
  [270.4808080810309, 319], [271.51515151560307, 320], [272.5494949495793, 321], [272.59259259283556, 322],
  [273.5838383841514, 323], [274.61818181872366, 324], [275.6525252526998, 325], [276.68686868727207, 326],
  [277.3333333337307, 327], [277.7212121212483, 328], [278.7555555558204, 329], [279.78989899039266, 330],
  [280.8242424243689, 331], [281.85858585894107, 332], [282.07407407462597, 333], [282.89292929351336, 334],
  [283.92727272748954, 335], [284.96161616206166, 336], [285.9959595960379, 337], [286.81481481492517, 338],
  [287.03030303061007, 339], [288.06464646518236, 340], [289.0989898991584, 341], [290.13333333373066, 342],
  [291.1676767677069, 343], [291.5555555558205, 344], [292.2020202022792, 345], [293.23636363685137, 346],
  [294.2707070708274, 347], [295.30505050539966, 348], [296.2962962967158, 349], [296.33939393997196, 350],
  [297.3737373739481, 351], [298.40808080852037, 352], [299.4424242424965, 353],
];

/** Tag line height for the system semibold font at fontSize (7 to 300 pt; clamps outside). */
export function systemTagLineHeight(fontSize: number): number {
  const t = systemTagLineHeightTable;
  let lo = 0;
  let hi = t.length - 1;
  if (fontSize < t[0][0]) return t[0][1];
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (t[mid][0] <= fontSize) lo = mid;
    else hi = mid - 1;
  }
  return t[lo][1];
}
