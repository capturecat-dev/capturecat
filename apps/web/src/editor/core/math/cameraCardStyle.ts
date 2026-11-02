/**
 * Port of Services/CameraCardStyle.swift — the camera styles of
 * docs/camera-cutout.md §12, resolved from the project settings with every
 * default applied and every number clamped: the ONE place the renderer and
 * the camera pane read them from, so nothing clamps or defaults differently.
 *
 *  - popOutAmount       null = 0.5 (geometry keeps today's 22 % headroom exactly)
 *  - fill               gradient (default) / camera / color / image
 *  - gradient colours   cameraCardGradientStart/End, else §3's
 *  - color              cameraCardColor ?? (0.11, 0.11, 0.13); every §12
 *                       colour draws OPAQUE (alpha dropped)
 *  - imagePath          null when absent or empty (→ the gradient, §12.3)
 *  - backgroundBlur     the camera fill's portrait blur, 0 for every other fill
 *  - edge softness / inset, border preset + thickness + colour, shrink toggle
 *  - imageFillRect: the image fill's aspect-fill placement
 */
import type { CameraCardBorder, CameraCardFill } from "../model/enums";
import type { CodableColor, ProjectSettings, Rect, Size } from "../model/types";
import { popOutCardBottom, popOutCardTop } from "./cameraCutoutMath";
import { midX, midY } from "./geometry";
import { smax, smin } from "./swift";

/** sRGB components, alpha dropped. */
export interface CardRGB {
  r: number;
  g: number;
  b: number;
}

export interface CameraCardStyle {
  popOutAmount: number | null;
  fill: CameraCardFill;
  gradientTop: CardRGB;
  gradientBottom: CardRGB;
  color: CardRGB;
  imagePath: string | null;
  backgroundBlur: number;
  edgeSoftness: number;
  edgeInset: number;
  /** null = no border ring. */
  border: CameraCardBorder | null;
  /** Border thickness 0…1 (only meaningful with `border`). */
  borderThickness: number;
  borderColor: CardRGB;
  shrinkOnZoom: boolean;
}

export type CameraCardStyleSettings = Pick<
  ProjectSettings,
  | "cameraPopOutAmount"
  | "cameraCardFill"
  | "cameraCardGradientStart"
  | "cameraCardGradientEnd"
  | "cameraCardColor"
  | "cameraCardImagePath"
  | "cameraBackgroundBlur"
  | "cameraEdgeSoftness"
  | "cameraEdgeInset"
  | "cameraCardBorder"
  | "cameraCardBorderWidth"
  | "cameraCardBorderColor"
  | "cameraShrinkOnZoom"
>;

export const defaultCardColor: CardRGB = { r: 0.11, g: 0.11, b: 0.13 };
/** §12.3 border gradient presets, sRGB, top → bottom. */
export const auroraTop: CardRGB = { r: 0.36, g: 0.91, b: 1.0 };
export const auroraBottom: CardRGB = { r: 0.29, g: 0.4, b: 1.0 };
export const goldTop: CardRGB = { r: 1.0, g: 0.89, b: 0.52 };
export const goldBottom: CardRGB = { r: 0.85, g: 0.55, b: 0.16 };
/** Border thickness / colour when the keys are absent. */
export const defaultBorderThickness = 0.5;
export const defaultBorderColor: CardRGB = { r: 1, g: 1, b: 1 };
/** §12.3 camera-fill blur: σ = blur × this × the camera frame's height (camera px). */
export const backgroundBlurSigmaFraction = 0.03;

const rgb = (c: CodableColor): CardRGB => ({ r: c.red, g: c.green, b: c.blue });
const unit = (v: number | undefined): number => smin(1, smax(0, v ?? 0));

/** `CameraCardStyle(_ s: ProjectSettings)` */
export function cameraCardStyle(s: CameraCardStyleSettings): CameraCardStyle {
  const fill = s.cameraCardFill ?? "gradient";
  return {
    popOutAmount: s.cameraPopOutAmount == null ? null : smin(1, smax(0, s.cameraPopOutAmount)),
    fill,
    gradientTop: s.cameraCardGradientStart ? rgb(s.cameraCardGradientStart) : { r: popOutCardTop.red, g: popOutCardTop.green, b: popOutCardTop.blue },
    gradientBottom: s.cameraCardGradientEnd
      ? rgb(s.cameraCardGradientEnd)
      : { r: popOutCardBottom.red, g: popOutCardBottom.green, b: popOutCardBottom.blue },
    color: s.cameraCardColor ? rgb(s.cameraCardColor) : defaultCardColor,
    imagePath: s.cameraCardImagePath ? s.cameraCardImagePath : null,
    backgroundBlur: fill === "camera" ? unit(s.cameraBackgroundBlur) : 0,
    edgeSoftness: unit(s.cameraEdgeSoftness),
    edgeInset: unit(s.cameraEdgeInset),
    border: s.cameraCardBorder ?? null,
    borderThickness: smin(1, smax(0, s.cameraCardBorderWidth ?? defaultBorderThickness)),
    borderColor: s.cameraCardBorderColor ? rgb(s.cameraCardBorderColor) : defaultBorderColor,
    shrinkOnZoom: s.cameraShrinkOnZoom ?? true,
  };
}

/** `geometryBorderWidth` — the thickness handed to `cutoutGeometry` (null = no ring). */
export function geometryBorderWidth(style: CameraCardStyle): number | null {
  return style.border === null ? null : style.borderThickness;
}

/** `borderColors` — the ring's colours top → bottom (solid: the same colour twice). */
export function borderColors(style: CameraCardStyle): { top: CardRGB; bottom: CardRGB } {
  switch (style.border) {
    case "aurora":
      return { top: auroraTop, bottom: auroraBottom };
    case "gold":
      return { top: goldTop, bottom: goldBottom };
    default:
      return { top: style.borderColor, bottom: style.borderColor };
  }
}

/** `blurSigma(cameraHeight:)` — §12.3 camera-fill blur σ in CAMERA pixels for a frame `height` tall. */
export function blurSigma(style: CameraCardStyle, cameraHeight: number): number {
  return style.backgroundBlur * backgroundBlurSigmaFraction * cameraHeight;
}

/** `imageFillRect(imageSize:card:)` — the image aspect-filled into the card (§12.3):
 *  s = max(C.w / iw, C.h / ih), centred on C. Same in Y-down and Y-up space. */
export function imageFillRect(imageSize: Size, card: Rect): Rect {
  if (!(imageSize.width > 0 && imageSize.height > 0)) return card;
  const s = smax(card.width / imageSize.width, card.height / imageSize.height);
  const w = imageSize.width * s;
  const h = imageSize.height * s;
  return { x: midX(card) - w / 2, y: midY(card) - h / 2, width: w, height: h };
}

/** `processesMaskEdge` — the person mask needs §12.4 edge processing at all. */
export function processesMaskEdge(style: CameraCardStyle): boolean {
  return style.edgeSoftness > 0 || style.edgeInset > 0;
}
