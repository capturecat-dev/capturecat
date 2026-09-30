/**
 * Port of the Mac EXPORTER's subtitle burn — Services/VideoExporter.swift:
 * `export()`'s canvasScale (lines 336–342) and active-subtitle lookup
 * (1798–1801), private `renderSubtitle(subtitle:at:onto:outputSize:
 * canvasScale:settings:)` (3661–3857) and private `subtitleDropShadow`
 * (3862–3885). Every non-text number, as a recipe the web renderer draws.
 *
 * Locked to Swift by the golden-vector units `exportSubtitleLayout`,
 * `exportActiveSubtitle` and `exportSubtitleTextMetrics` (verbatim oracles —
 * the originals are private; see WebVectors+OverlaySubtitle.swift).
 *
 * # Text (AppKit) — what the web must measure and draw itself
 *
 * Font: FontCatalog.font(named: settings.subtitleFontName, size:
 * max(1, subtitleFontSize · canvasScale), weight: subtitleWeight) — nil /
 * "System" / missing family → the system face (SF Pro) at the weight.
 * Paragraph: CENTRE aligned. Measurement = NSAttributedString.boundingRect(
 * with: (constraintWidth, ∞), options: [.usesLineFragmentOrigin,
 * .usesFontLeading]) — word-wrapped to `constraintWidth`, line height =
 * the font's ascender − descender + leading. `measure` returns that rect;
 * only its (absolute) width/height are used. `exportSubtitleTextMetrics`
 * records Swift's values (and font ascender/descender/leading/line height)
 * for a representative set — the web's layout must reproduce them.
 * Karaoke (highlightWords + words): words joined by single spaces; each word
 * run is highlight colour when `currentTime >= word.startTime` else the text
 * colour at 0.4× alpha; spaces use the text colour; `subtitleUppercase`
 * uppercases each word / the whole text (full Unicode mapping).
 *
 * # Raster + coordinate spaces
 *
 * The exporter draws into a full-output bitmap of `bitmapWidth ×
 * bitmapHeight` (= Int(output size)) whose CG space is Y-UP: `xPosition`,
 * `yPosition`, `background.rect`, `textRect`, `background.path` are Y-UP
 * with the origin at the bitmap's bottom-left. For a Y-down web raster use
 * `yDown = bitmapHeight − (y + height)` (see `yUpRectToYDown`). The text is
 * laid out top-down inside `textRect` (first line at its visual top), each
 * line centred in the rect's width.
 *
 * # Background / outline / glow
 *
 * - Background style: `background.path` (CGPath(roundedRect:) CIRCULAR
 *   corners, radius 6·canvasScale) filled sRGB (bg rgb, alpha 0.75 — the
 *   colour's own opacity is IGNORED), then the text on top.
 * - Outline / glow (`effect`): silhouette = text-raster ALPHA × (color.rgb ·
 *   color.a, color.a) (premultiplied), CIGaussianBlur with inputRadius =
 *   `effect.radius` (CI's radius is a σ), cropped to the output; the text
 *   raster is composited OVER it, and the result over the frame. Outline =
 *   black, radius 2·canvasScale; glow = text rgb at opacity·0.8, radius
 *   6·canvasScale. `effect` is null when the radius is ≤ 0 (plain burn).
 * - The exporter caches the overlay raster by `cacheKey`
 *   ("<uuid>|<active word count or -1>").
 */
import type { CodableColor, ProjectSettings, Rect, Size, SubtitleSegment } from "../model/types";
import type { SubtitleWeight } from "../model/enums";
import { cgRoundedRectPath, type PathElements, type RGBA } from "./overlaySupport";
import { rectHeight, rectWidth } from "./geometry";
import { sInt, smax, smin } from "./swift";

export type SubtitleSettings = Pick<
  ProjectSettings,
  | "showSubtitles"
  | "subtitleFontSize"
  | "subtitlePosition"
  | "subtitleStyle"
  | "subtitleCustomX"
  | "subtitleCustomY"
  | "subtitleWeight"
  | "subtitleUppercase"
  | "subtitleFontName"
  | "subtitleColor"
  | "subtitleBackgroundColor"
  | "highlightWords"
  | "subtitleHighlightColor"
>;

/** `export()` — canvas-pt → output-px factor: the preview canvas is the
 * reference when the project has one (> 0 both ways), else the output
 * itself (headless/CLI exports → 1). */
export function exportCanvasScale(outputSize: Size, previewCanvasSize: Size): number {
  const ref = previewCanvasSize.width > 0 && previewCanvasSize.height > 0 ? previewCanvasSize : outputSize;
  return smin(outputSize.width / ref.width, outputSize.height / ref.height);
}

/** `export()` — the burned segment: FIRST with start ≤ t ≤ end (source time),
 * only when `showSubtitles`. */
export function activeSubtitle(
  subtitles: readonly SubtitleSegment[],
  currentTime: number,
  showSubtitles: boolean,
): SubtitleSegment | null {
  if (!showSubtitles) return null;
  for (const s of subtitles) if (currentTime >= s.startTime && currentTime <= s.endTime) return s;
  return null;
}

/** The exporter's overlay cache key and active-word count (−1 = no karaoke). */
export function subtitleCacheKey(
  subtitle: SubtitleSegment,
  currentTime: number,
  settings: Pick<ProjectSettings, "highlightWords">,
): { key: string; activeWordCount: number } {
  let activeWordCount = -1;
  if (settings.highlightWords && subtitle.words.length > 0) {
    activeWordCount = 0;
    for (const w of subtitle.words) if (currentTime >= w.startTime) activeWordCount++;
  }
  return { key: subtitle.id + "|" + String(activeWordCount), activeWordCount };
}

/** Font point size: `max(1, subtitleFontSize · canvasScale)`. */
export function subtitleFontSize(subtitleFontSizePt: number, canvasScale: number): number {
  return smax(1, subtitleFontSizePt * canvasScale);
}

/** Width the text wraps to: `max(1, outputWidth − 2·(20 + 12)·canvasScale)`. */
export function subtitleConstraintWidth(outputWidth: number, canvasScale: number): number {
  const outerEdgePad = 20 * canvasScale;
  const pillHPad = 12 * canvasScale;
  return smax(1, outputWidth - 2 * (outerEdgePad + pillHPad));
}

/** The uppercase transform both renderers apply. */
export function subtitleTransform(text: string, uppercase: boolean): string {
  return uppercase ? text.toUpperCase() : text;
}

export interface SubtitleRun {
  text: string;
  color: RGBA;
  /** Karaoke word state (null for spaces / non-karaoke text). */
  active: boolean | null;
}

function nsColor(c: CodableColor): RGBA {
  return { r: c.red, g: c.green, b: c.blue, a: c.opacity };
}

/** The attributed string runs (font + centred paragraph on every run). */
export function subtitleRuns(subtitle: SubtitleSegment, currentTime: number, settings: SubtitleSettings): SubtitleRun[] {
  const textColor = nsColor(settings.subtitleColor);
  const runs: SubtitleRun[] = [];
  if (settings.highlightWords && subtitle.words.length > 0) {
    const highlight = nsColor(settings.subtitleHighlightColor);
    const dim: RGBA = { r: textColor.r, g: textColor.g, b: textColor.b, a: textColor.a * 0.4 };
    for (let i = 0; i < subtitle.words.length; i++) {
      const word = subtitle.words[i];
      if (i > 0) runs.push({ text: " ", color: textColor, active: null });
      const isActive = currentTime >= word.startTime;
      runs.push({
        text: subtitleTransform(word.text, settings.subtitleUppercase),
        color: isActive ? highlight : dim,
        active: isActive,
      });
    }
  } else {
    runs.push({ text: subtitleTransform(subtitle.text, settings.subtitleUppercase), color: textColor, active: null });
  }
  return runs;
}

/** What the web must measure: runs + font at the constraint width. */
export interface SubtitleMeasureRequest {
  runs: SubtitleRun[];
  fontName: string | null;
  fontSize: number;
  weight: SubtitleWeight;
  constraintWidth: number;
}

/** Returns NSAttributedString.boundingRect for the request (see module doc). */
export type SubtitleMeasure = (req: SubtitleMeasureRequest) => Rect;

export interface SubtitleEffect {
  kind: "shadow" | "glow";
  /** CIGaussianBlur inputRadius (a sigma), output px. */
  radius: number;
  /** Straight-alpha silhouette colour. */
  color: RGBA;
}

export interface SubtitleBackground {
  rect: Rect;
  cornerRadius: number;
  color: RGBA;
  path: PathElements;
}

export interface SubtitleRecipe {
  fontSize: number;
  fontName: string | null;
  weight: SubtitleWeight;
  runs: SubtitleRun[];
  constraintWidth: number;
  textBounds: Rect;
  pillHPad: number;
  pillVPad: number;
  pillCorner: number;
  outerEdgePad: number;
  bgWidth: number;
  bgHeight: number;
  fraction: { x: number; y: number };
  usableW: number;
  usableH: number;
  /** Y-UP bitmap space (see module doc). */
  xPosition: number;
  yPosition: number;
  bitmapWidth: number;
  bitmapHeight: number;
  /** false: the exporter CGContext cannot exist; nothing is burned. */
  drawn: boolean;
  background: SubtitleBackground | null;
  /** Y-UP bitmap space. */
  textRect: Rect;
  effect: SubtitleEffect | null;
  cacheKey: string;
  activeWordCount: number;
}

/** `renderSubtitle(...)` as a recipe. */
export function subtitleRecipe(
  subtitle: SubtitleSegment,
  currentTime: number,
  outputSize: Size,
  canvasScale: number,
  settings: SubtitleSettings,
  measure: SubtitleMeasure,
): SubtitleRecipe {
  const fontSize = subtitleFontSize(settings.subtitleFontSize, canvasScale);
  const runs = subtitleRuns(subtitle, currentTime, settings);

  const pillHPad = 12 * canvasScale;
  const pillVPad = 6 * canvasScale;
  const pillCorner = 6 * canvasScale;
  const outerEdgePad = 20 * canvasScale;

  const constraintWidth = smax(1, outputSize.width - 2 * (outerEdgePad + pillHPad));
  const textBounds = measure({
    runs,
    fontName: settings.subtitleFontName ?? null,
    fontSize,
    weight: settings.subtitleWeight,
    constraintWidth,
  });
  const textW = rectWidth(textBounds);
  const textH = rectHeight(textBounds);
  const bgWidth = textW + pillHPad * 2;
  const bgHeight = textH + pillVPad * 2;

  let fraction: { x: number; y: number };
  if (settings.subtitleCustomX != null && settings.subtitleCustomY != null) {
    fraction = {
      x: smin(1, smax(0, settings.subtitleCustomX)),
      y: smin(1, smax(0, settings.subtitleCustomY)),
    };
  } else if (settings.subtitlePosition === "Top") {
    fraction = { x: 0.5, y: 0 };
  } else if (settings.subtitlePosition === "Center") {
    fraction = { x: 0.5, y: 0.5 };
  } else {
    fraction = { x: 0.5, y: 1 };
  }
  const usableW = smax(0, outputSize.width - 2 * outerEdgePad - bgWidth);
  const usableH = smax(0, outputSize.height - 2 * outerEdgePad - bgHeight);
  const xPosition = outerEdgePad + fraction.x * usableW;
  const yPosition = outerEdgePad + (1 - fraction.y) * usableH;

  const bitmapWidth = sInt(outputSize.width);
  const bitmapHeight = sInt(outputSize.height);

  let background: SubtitleBackground | null = null;
  if (settings.subtitleStyle === "Background") {
    const bg = settings.subtitleBackgroundColor;
    const rect = { x: xPosition, y: yPosition, width: bgWidth, height: bgHeight };
    background = {
      rect,
      cornerRadius: pillCorner,
      color: { r: bg.red, g: bg.green, b: bg.blue, a: 0.75 },
      path: cgRoundedRectPath(rect, pillCorner, pillCorner),
    };
  }

  const textRect = { x: xPosition + pillHPad, y: yPosition + pillVPad, width: textW, height: textH };

  let effect: SubtitleEffect | null = null;
  if (settings.subtitleStyle === "Outline") {
    const radius = 2 * canvasScale;
    if (radius > 0) effect = { kind: "shadow", radius, color: { r: 0, g: 0, b: 0, a: 1 } };
  } else if (settings.subtitleStyle === "Glow") {
    const c = settings.subtitleColor;
    const radius = 6 * canvasScale;
    if (radius > 0) effect = { kind: "glow", radius, color: { r: c.red, g: c.green, b: c.blue, a: c.opacity * 0.8 } };
  }

  const key = subtitleCacheKey(subtitle, currentTime, settings);
  return {
    fontSize,
    fontName: settings.subtitleFontName ?? null,
    weight: settings.subtitleWeight,
    runs,
    constraintWidth,
    textBounds,
    pillHPad,
    pillVPad,
    pillCorner,
    outerEdgePad,
    bgWidth,
    bgHeight,
    fraction,
    usableW,
    usableH,
    xPosition,
    yPosition,
    bitmapWidth,
    bitmapHeight,
    drawn: bitmapWidth > 0 && bitmapHeight > 0,
    background,
    textRect,
    effect,
    cacheKey: key.key,
    activeWordCount: key.activeWordCount,
  };
}

/** Y-up bitmap rect to a Y-down raster rect (bitmap height = `canvasHeight`). */
export function yUpRectToYDown(r: Rect, canvasHeight: number): Rect {
  return { x: r.x, y: canvasHeight - (r.y + r.height), width: r.width, height: r.height };
}
