/**
 * Port of the PRIVATE camera-bubble and card-frame compositing numbers of
 * Services/VideoExporter.swift (commit da569841c7b63175bffa46d897457f157224774d):
 *
 *   export(...)                 static camera setup  (VideoExporter.swift:336-342, 1079-1155)
 *                               per-frame camera flow (:1425-1475, :1919-1991, :2197-2242)
 *   frameShapeCGPath            :2879-2901
 *   roundedRectangleMaskImage   :2903-2956
 *   cameraShapeCGPath           :2964-2972
 *   cameraShapeMaskImage        :2976-3011
 *   cameraShapeStrokeImage      :3015-3054
 *   cameraShapeShadowImage      :3058-3087
 *   compositeCamera             :3097-3177
 *   fadeImage                   :3181-3189
 *   makeFrameShadow             :3191-3238
 *   createBackground            :3616-3621  (= BackgroundLook.ciImage(for: Spec(settings), size: outputSize),
 *                                            i.e. backgroundLook.ts at scale 1; see that module)
 *
 * Locked by the golden-vector units exportCameraStatics, exportCameraFrame,
 * exportCompositeCamera, exportMaskGeometry and exportCameraReader (all
 * VERBATIM ORACLES: the Swift is private/inline; the oracles call the REAL
 * ReactiveCameraLayout / CameraLayoutMath / CameraStyleMath functions).
 *
 * SPACE: every rect here is in the EXPORTER CoreImage space: output pixels,
 * Y-UP, origin bottom-left (outputRect = (0, 0, W, H)). To draw in the web
 * Y-down space flip a rect with y2 = H - (y + height) AFTER computing in Y-up
 * (ReactiveCameraLayout.cameraRect is only the mirror image of its Y-down call
 * when the bubble fits, so compute Y-up and flip for exact parity).
 *
 * What the GPU passes do with these numbers (all blur radii are CoreImage
 * CIGaussianBlur SIGMAS in output px):
 *  - Camera frame: aspect-FILL into the bubble rect (fillScale, dx, dy),
 *    cropped to the rect, clipped by the mask (luminance of a white-on-black
 *    mask; outside the rect nothing), then stacked OVER TRANSPARENT in this
 *    order: shadow, ring glow, clipped camera, stroke, name tag; then the 3D
 *    tilt (TiltMath homography about the bubble, only when abs(pitch) or
 *    abs(yaw) > 0.01), then the whole group is faded (premultiplied RGBA x
 *    alpha) when opacity < 1, then composited over the frame.
 *  - Plain bubble: the static mask / stroke / shadow / ring / tag are baked
 *    ONCE at baseRect (bottom-right corner) and re-targeted every frame by
 *    the affine assetTransform (scale sx, sy then translate), so the stroke
 *    width, shadow blur and tag scale WITH the bubble.
 *  - Layout override (cameraOnly / sideBySide / mid-morph): the mask is a
 *    CIRoundedRectangleGenerator (circular corners of maskRadius, white)
 *    cropped to the rect; stroke/ring/tag/bubble-shadow are the baked assets
 *    re-targeted and faded by chrome (dropped when chrome <= 0.01); a card
 *    shadow (makeFrameShadow, rounded rect of maskRadius) fades in with
 *    cardness; the tile is composited onto the card BEFORE the card
 *    transform stage so tilt/zoom/dip move it with the card.
 *  - Bubble shadow (cameraShapeShadowImage): shape filled black at alpha
 *    0.45, blurred with sigma = shadowRadius (6 x canvasScale; NOT halved,
 *    unlike the frame shadow), no offset, cropped to shadowExtent.
 *  - Frame / card shadow (makeFrameShadow): shape filled black at alpha
 *    shadowOpacity x 0.45, blurred with sigma = shadowRadius / 2, moved by
 *    offsetY = -(shadowRadius / 3) in Y-UP (i.e. DOWN on screen), cropped to
 *    the extent.
 *  - Stroke (cameraShapeStrokeImage): the shape path stroked with lineWidth
 *    (centred on the outline) in a bitmap the size of the EXTENT (= the
 *    bubble rect), so the OUTER half of the stroke is clipped away.
 *  - Masks are CG bitmaps of ceil(extent) pixels whose bottom-left sits at
 *    the extent origin, cropped back to the exact (fractional) extent.
 */
import type { CameraLayoutRegion, Point, ProjectSettings, Rect, Size } from "../model/types";
import type { CameraShape, FrameShape } from "../model/enums";
import { type AffineTransform, insetBy, minX, minY, rectHeight, rectWidth } from "./geometry";
import { bubbleSize, cameraRect, canvasFitScale, shapeAspect } from "./reactiveCameraLayout";
import { bubbleApproxCornerRadius, cardTransform, resolve, type CameraLayoutResolved } from "./cameraLayoutMath";
import {
  borderColor,
  clipPath,
  ringPadding,
  ringRecipe,
  tagLayout,
  tagRect,
  type RingRecipe,
  type TagMeasure,
} from "./cameraStyleMath";
import { path as continuousRoundedPath } from "./continuousRoundedRect";
import type { SRGBA } from "./oklabGradient";
import { cgPathRect, cgPathRoundedRect, type PathElement } from "./styleSupport";
import { smax, smin } from "./swift";
import { canvasScale as layoutCanvasScale, cmTimeValue } from "./exportLayout";

// -- Bitmap masks --------------------------------------------------------------

/** A CG mask bitmap: ceil(extent) pixels, shape path in bitmap space (Y-up, origin = extent origin). */
export interface MaskBitmap {
  extent: Rect;
  width: number;
  height: number;
  /** The shape rect relative to the extent origin. */
  adjustedRect: Rect;
  path: PathElement[];
}

export interface StrokeBitmap extends MaskBitmap {
  lineWidth: number;
  color: SRGBA;
}

export interface InvertibleMaskBitmap extends MaskBitmap {
  inverted: boolean;
}

/** frameShapeCGPath(rect:cornerRadius:frameShape:) */
export function frameShapePath(rect: Rect, cornerRadius: number, frameShape: FrameShape): PathElement[] {
  switch (frameShape) {
    case "Rectangle":
      return cgPathRect(rect);
    case "Rounded Rectangle":
      return cgPathRoundedRect(rect, cornerRadius, cornerRadius);
    case "Squircle":
      return continuousRoundedPath(rect, cornerRadius);
  }
}

interface MaskGeometry {
  width: number;
  height: number;
  adjustedRect: Rect;
}

function maskGeometry(extent: Rect, rect: Rect): MaskGeometry | null {
  const width = Math.trunc(Math.ceil(rectWidth(extent)));
  const height = Math.trunc(Math.ceil(rectHeight(extent)));
  if (!(width > 0 && height > 0)) return null;
  return {
    width,
    height,
    adjustedRect: {
      x: minX(rect) - minX(extent),
      y: minY(rect) - minY(extent),
      width: rectWidth(rect),
      height: rectHeight(rect),
    },
  };
}

/**
 * roundedRectangleMaskImage(extent:rect:cornerRadius:inverted:frameShape:):
 * base fill black (white when inverted), the frame shape filled white (black
 * when inverted). null where Swift returns nil.
 */
export function roundedRectangleMask(
  extent: Rect,
  rect: Rect,
  cornerRadius: number,
  inverted: boolean,
  frameShape: FrameShape = "Rounded Rectangle",
): InvertibleMaskBitmap | null {
  const g = maskGeometry(extent, rect);
  if (!g) return null;
  return { extent, ...g, inverted, path: frameShapePath(g.adjustedRect, cornerRadius, frameShape) };
}

/** cameraShapeMaskImage(extent:rect:shape:cornerRadius:scale:): black base, camera shape filled white. */
export function cameraShapeMask(
  extent: Rect,
  rect: Rect,
  shape: CameraShape,
  cornerRadius: number,
  scale: number,
): MaskBitmap | null {
  const g = maskGeometry(extent, rect);
  if (!g) return null;
  return { extent, ...g, path: clipPath(shape, cornerRadius, g.adjustedRect, scale) };
}

/** cameraShapeStrokeImage(...): clear base, camera shape STROKED (lineWidth, colour); null when lineWidth <= 0. */
export function cameraShapeStroke(
  extent: Rect,
  rect: Rect,
  shape: CameraShape,
  cornerRadius: number,
  scale: number,
  lineWidth: number,
  strokeColor: SRGBA,
): StrokeBitmap | null {
  if (!(lineWidth > 0)) return null;
  const g = maskGeometry(extent, rect);
  if (!g) return null;
  return { extent, ...g, path: clipPath(shape, cornerRadius, g.adjustedRect, scale), lineWidth, color: strokeColor };
}

export interface ShapeShadow {
  mask: MaskBitmap;
  alpha: number;
  sigma: number;
}

/** cameraShapeShadowImage(...): shape mask, black at alpha 0.45, CIGaussianBlur sigma = shadowRadius. */
export function cameraShapeShadow(
  extent: Rect,
  rect: Rect,
  shape: CameraShape,
  cornerRadius: number,
  scale: number,
  shadowRadius: number,
): ShapeShadow | null {
  if (!(shadowRadius > 0)) return null;
  const mask = cameraShapeMask(extent, rect, shape, cornerRadius, scale);
  if (!mask) return null;
  return { mask, alpha: 0.45, sigma: shadowRadius };
}

export interface FrameShadow extends ShapeShadow {
  offsetY: number;
}

/**
 * makeFrameShadow(extent:rect:cornerRadius:shadowRadius:shadowOpacity:frameShape:):
 * mask (non-inverted), black at alpha shadowOpacity x 0.45, sigma =
 * shadowRadius / 2, then translated by (0, offsetY) (Y-up) and cropped to the extent.
 */
export function frameShadow(
  extent: Rect,
  rect: Rect,
  cornerRadius: number,
  shadowRadius: number,
  shadowOpacity: number,
  frameShape: FrameShape = "Rounded Rectangle",
): FrameShadow | null {
  if (!(shadowRadius > 0 && shadowOpacity > 0)) return null;
  const m = roundedRectangleMask(extent, rect, cornerRadius, false, frameShape);
  if (!m) return null;
  return {
    mask: { extent: m.extent, width: m.width, height: m.height, adjustedRect: m.adjustedRect, path: m.path },
    alpha: shadowOpacity * 0.45,
    sigma: shadowRadius / 2,
    offsetY: -(shadowRadius / 3),
  };
}

// -- compositeCamera / fadeImage ------------------------------------------------

/** fadeImage(_:alpha:) multiplier: CIColorMatrix scaling premultiplied R, G, B, A. */
export function fadeAlpha(alpha: number): number {
  return smin(1, smax(0, alpha));
}

export interface CompositeCameraGeometry {
  fillScale: number;
  scaledW: number;
  scaledH: number;
  dx: number;
  dy: number;
  /** Camera transform: scale(fillScale) then translate(dx, dy), then crop to rect. */
  transform: AffineTransform;
  applyTilt: boolean;
  /** null = no fade (opacity >= 1). */
  fade: number | null;
}

/** The numbers compositeCamera(camera:rect:...) derives; null when the camera extent is empty (frame returned untouched). */
export function compositeCameraGeometry(
  camExtent: Rect,
  rect: Rect,
  opacity: number,
  tiltPitch: number,
  tiltYaw: number,
): CompositeCameraGeometry | null {
  if (!(rectWidth(camExtent) > 0 && rectHeight(camExtent) > 0)) return null;
  const fillScale = smax(rectWidth(rect) / rectWidth(camExtent), rectHeight(rect) / rectHeight(camExtent));
  const scaledW = rectWidth(camExtent) * fillScale;
  const scaledH = rectHeight(camExtent) * fillScale;
  const dx = minX(rect) - (scaledW - rectWidth(rect)) / 2 - minX(camExtent) * fillScale;
  const dy = minY(rect) - (scaledH - rectHeight(rect)) / 2 - minY(camExtent) * fillScale;
  return {
    fillScale,
    scaledW,
    scaledH,
    dx,
    dy,
    transform: { a: fillScale, b: 0, c: 0, d: fillScale, tx: dx, ty: dy },
    applyTilt: Math.abs(tiltPitch) > 0.01 || Math.abs(tiltYaw) > 0.01,
    fade: opacity < 1 ? fadeAlpha(opacity) : null,
  };
}

// -- Static per-export camera setup ------------------------------------------------

export type ExportCameraSettings = Pick<
  ProjectSettings,
  | "cameraSize"
  | "cameraShape"
  | "cameraOrientation"
  | "cameraCornerRadius"
  | "cameraBorderWidth"
  | "cameraBorderColor"
  | "cameraRingLight"
  | "cameraTagText"
  | "cameraTagSubtext"
  | "cameraTagFontName"
  | "cameraTagPosition"
>;

/** ProjectSettings.effectiveCameraSize = max(120, cameraSize). */
export function effectiveCameraSize(s: Pick<ProjectSettings, "cameraSize">): number {
  return smax(120, s.cameraSize);
}

/** referenceCanvas + canvasScale (VideoExporter.swift:336-342); previewCanvasSize zero = headless export. */
export function exportCanvasScale(outputSize: Size, previewCanvasSize: Size): { referenceCanvas: Size; canvasScale: number } {
  const referenceCanvas =
    previewCanvasSize.width > 0 && previewCanvasSize.height > 0 ? previewCanvasSize : outputSize;
  // Single source for the factor: exportLayout.canvasScale.
  return { referenceCanvas, canvasScale: layoutCanvasScale(outputSize, previewCanvasSize) };
}

export interface ExportCameraRing {
  recipe: RingRecipe;
  /** Bitmap origin (baseRect outset by the ring padding), Y-up. */
  origin: Point;
  /** Crop rect after placing. */
  crop: Rect;
}

export interface ExportCameraTag {
  pillSize: Size;
  /** Where the pill bitmap is placed (Y-up); NOT cropped. */
  rect: Rect;
}

export interface ExportCameraAssets {
  /** Canonical bottom-right rect in Y-up output px. */
  baseRect: Rect;
  shadowRadius: number;
  shadowSlack: number;
  shadowExtent: Rect;
  mask: MaskBitmap | null;
  stroke: StrokeBitmap | null;
  shadow: ShapeShadow | null;
  ring: ExportCameraRing | null;
  tag: ExportCameraTag | null;
}

export interface ExportCameraStatics {
  referenceCanvas: Size;
  canvasScale: number;
  cameraFit: number;
  cameraBaseSize: number;
  cameraPadding: number;
  cameraAspect: number;
  /** null when there is no camera reader (no camera composited at all). */
  assets: ExportCameraAssets | null;
}

/**
 * The per-export camera constants and baked-asset geometry. hasCameraReader
 * = showCamera AND a camera file with a video track that started reading.
 * cameraNaturalSize = the camera track naturalSize (zero when unknown).
 * measure = tag text measurement (see cameraStyleMath.ts).
 */
export function exportCameraStatics(
  s: ExportCameraSettings,
  outputSize: Size,
  previewCanvasSize: Size,
  cameraNaturalSize: Size,
  hasCameraReader: boolean,
  measure: TagMeasure,
): ExportCameraStatics {
  const { referenceCanvas, canvasScale } = exportCanvasScale(outputSize, previewCanvasSize);
  const cameraFit = canvasFitScale(referenceCanvas);
  const cameraBaseSize = smax(1, effectiveCameraSize(s) * cameraFit * canvasScale);
  const cameraPadding = 12 * cameraFit * canvasScale;
  const cameraAspect = shapeAspect(
    s.cameraShape,
    cameraNaturalSize.width > 0 && cameraNaturalSize.height > 0 ? cameraNaturalSize.width / cameraNaturalSize.height : 1,
    s.cameraOrientation,
  );
  if (!hasCameraReader) {
    return { referenceCanvas, canvasScale, cameraFit, cameraBaseSize, cameraPadding, cameraAspect, assets: null };
  }
  const baseBubble = bubbleSize(cameraBaseSize, cameraAspect);
  const baseRect: Rect = {
    x: outputSize.width - cameraPadding - baseBubble.width,
    y: 0 + cameraPadding,
    width: baseBubble.width,
    height: baseBubble.height,
  };
  const shadowRadius = 6 * canvasScale;
  const shadowSlack = shadowRadius * 4 + 4;
  const shadowExtent = insetBy(baseRect, -shadowSlack, -shadowSlack);
  const mask = cameraShapeMask(baseRect, baseRect, s.cameraShape, s.cameraCornerRadius, canvasScale);
  const stroke =
    s.cameraBorderWidth > 0
      ? cameraShapeStroke(
          baseRect,
          baseRect,
          s.cameraShape,
          s.cameraCornerRadius,
          canvasScale,
          s.cameraBorderWidth * canvasScale,
          borderColor(s),
        )
      : null;
  const shadow = cameraShapeShadow(shadowExtent, baseRect, s.cameraShape, s.cameraCornerRadius, canvasScale, shadowRadius);
  const baseSize: Size = { width: baseRect.width, height: baseRect.height };
  const recipe = ringRecipe(baseSize, s.cameraShape, s.cameraCornerRadius * canvasScale, s.cameraRingLight, 1);
  let ring: ExportCameraRing | null = null;
  if (recipe) {
    const pad = ringPadding(baseSize);
    ring = {
      recipe,
      origin: { x: minX(baseRect) - pad, y: minY(baseRect) - pad },
      crop: insetBy(baseRect, -pad, -pad),
    };
  }
  let tag: ExportCameraTag | null = null;
  const layout = tagLayout(s, rectWidth(baseRect), measure);
  if (layout && Math.trunc(Math.ceil(layout.pillSize.width)) > 0 && Math.trunc(Math.ceil(layout.pillSize.height)) > 0) {
    tag = { pillSize: layout.pillSize, rect: tagRect(baseRect, layout.pillSize, s.cameraTagPosition, true) };
  }
  return {
    referenceCanvas,
    canvasScale,
    cameraFit,
    cameraBaseSize,
    cameraPadding,
    cameraAspect,
    assets: { baseRect, shadowRadius, shadowSlack, shadowExtent, mask, stroke, shadow, ring, tag },
  };
}

// -- Per-frame camera flow ---------------------------------------------------------

export type ExportFrameCameraSettings = Pick<
  ProjectSettings,
  | "cameraPosition"
  | "cameraCustomX"
  | "cameraCustomY"
  | "cameraShape"
  | "cameraCornerRadius"
  | "cornerRadius"
  | "shadowRadius"
  | "shadowOpacity"
  | "cameraOpacity"
  | "cameraTiltPitch"
  | "cameraTiltYaw"
>;

export interface ExportFrameCameraInput {
  /** Timeline SOURCE seconds of this output frame. */
  currentTime: number;
  /** RAW smoothed zoom from the camera path (not the cover-compensated card zoom). */
  zoom: number;
  /** sourceCMTime is non-nil: the clip is visible at this frame. */
  sourceVisible: boolean;
  /** A camera pixel buffer has been decoded so far (see CameraReaderCursor). */
  cameraFrameDecoded: boolean;
  /** The poster image loaded (project.cameraPosterURL decodes). */
  posterAvailable: boolean;
}

export interface ExportPlainCamera {
  rect: Rect;
  assetTransform: AffineTransform;
  opacity: number;
  tiltPitch: number;
  tiltYaw: number;
}

export interface ExportCardShadow {
  extent: Rect;
  rect: Rect;
  cornerRadius: number;
  shadowRadius: number;
  shadowOpacity: number;
}

export interface ExportOverrideCamera {
  rect: Rect;
  /** CIRoundedRectangleGenerator radius (max(0, radius)). */
  maskRadius: number;
  /** min(layout radius, half the short side) — also the card-shadow corner. */
  radius: number;
  chrome: number;
  /** false = stroke / ring / tag / bubble shadow are dropped (chrome <= 0.01). */
  chromeVisible: boolean;
  assetTransform: AffineTransform;
  cardness: number;
  cardShadow: ExportCardShadow | null;
  opacity: number;
  tiltPitch: number;
  tiltYaw: number;
}

export interface ExportFrameCamera {
  bubbleRectNow: Rect;
  bubbleCornerRadius: number;
  cardCornerRadius: number;
  layout: CameraLayoutResolved;
  /** CameraLayoutMath.cardTransform applied to the card (over transparency). */
  cardTransform: AffineTransform;
  cameraTargetTime: number;
  /** live = decoded frame, poster, or none (no source: nothing drawn). */
  source: "live" | "poster" | "none";
  /** plain bubble (late, canvas level), override tile (before the card transform stage) or none. */
  path: "plain" | "override" | "none";
  plain: ExportPlainCamera | null;
  override: ExportOverrideCamera | null;
}

/** assetXform: scale(sx, sy) then translate so baseRect lands on rect. */
export function assetTransformFor(rect: Rect, baseRect: Rect): AffineTransform {
  const sx = rectWidth(baseRect) > 0 ? rectWidth(rect) / rectWidth(baseRect) : 1;
  const sy = rectHeight(baseRect) > 0 ? rectHeight(rect) / rectHeight(baseRect) : 1;
  return { a: sx, b: 0, c: 0, d: sy, tx: minX(rect) - minX(baseRect) * sx, ty: minY(rect) - minY(baseRect) * sy };
}

/**
 * One output frame of the exporter camera flow. videoRect = the exporter
 * staticLayout.videoRect (Y-up output px); regions in SOURCE time.
 */
export function exportFrameCamera(
  statics: ExportCameraStatics,
  s: ExportFrameCameraSettings,
  regions: readonly CameraLayoutRegion[],
  videoRect: Rect,
  outputSize: Size,
  cameraTimeOffset: number,
  f: ExportFrameCameraInput,
): ExportFrameCamera {
  const outputRect: Rect = { x: 0, y: 0, width: outputSize.width, height: outputSize.height };
  const custom =
    s.cameraCustomX != null && s.cameraCustomY != null ? { x: s.cameraCustomX, y: s.cameraCustomY } : null;
  const bubbleRectNow = cameraRect(
    outputRect,
    s.cameraPosition,
    custom,
    statics.cameraBaseSize,
    f.zoom,
    statics.cameraPadding,
    statics.cameraAspect,
    true,
  );
  const bubbleCornerRadius = bubbleApproxCornerRadius(s.cameraShape, s.cameraCornerRadius * statics.canvasScale, {
    width: bubbleRectNow.width,
    height: bubbleRectNow.height,
  });
  const cardCornerRadius = smax(0, s.cornerRadius * statics.canvasScale);
  const layout = resolve(
    f.currentTime,
    regions,
    videoRect,
    bubbleRectNow,
    bubbleCornerRadius,
    cardCornerRadius,
    statics.assets !== null,
  );
  const cameraTargetTime = f.currentTime - cameraTimeOffset;
  const source: ExportFrameCamera["source"] =
    cameraTargetTime >= 0 && f.cameraFrameDecoded ? "live" : f.posterAvailable ? "poster" : "none";

  const out: ExportFrameCamera = {
    bubbleRectNow,
    bubbleCornerRadius,
    cardCornerRadius,
    layout,
    cardTransform: cardTransform(layout, videoRect),
    cameraTargetTime,
    source,
    path: "none",
    plain: null,
    override: null,
  };
  const assets = statics.assets;
  if (!assets || !f.sourceVisible || source === "none") return out;

  if (!layout.isPlainBubble && layout.cameraOpacity > 0.001 && layout.cameraRect) {
    const rect = layout.cameraRect;
    const radius = smin(layout.cameraCornerRadius, smin(rectWidth(rect), rectHeight(rect)) / 2);
    const chrome = layout.chromeOpacity;
    const cardness = 1 - chrome;
    let cardShadow: ExportCardShadow | null = null;
    if (cardness > 0.01 && s.shadowRadius > 0 && s.shadowOpacity > 0) {
      const slack = Math.ceil(s.shadowRadius * statics.canvasScale * 2 + 24);
      cardShadow = {
        extent: insetBy(rect, -slack, -slack),
        rect,
        cornerRadius: radius,
        shadowRadius: smax(0, s.shadowRadius * statics.canvasScale),
        shadowOpacity: smax(0, s.shadowOpacity) * cardness,
      };
    }
    out.path = "override";
    out.override = {
      rect,
      maskRadius: smax(0, radius),
      radius,
      chrome,
      chromeVisible: chrome > 0.01,
      assetTransform: assetTransformFor(rect, assets.baseRect),
      cardness,
      cardShadow,
      opacity: s.cameraOpacity * layout.cameraOpacity,
      tiltPitch: s.cameraTiltPitch * chrome,
      tiltYaw: s.cameraTiltYaw * chrome,
    };
  } else if (layout.cameraOpacity > 0.001 && layout.isPlainBubble) {
    out.path = "plain";
    out.plain = {
      rect: bubbleRectNow,
      assetTransform: assetTransformFor(bubbleRectNow, assets.baseRect),
      opacity: s.cameraOpacity,
      tiltPitch: s.cameraTiltPitch,
      tiltYaw: s.cameraTiltYaw,
    };
  }
  return out;
}

// -- Camera reader advance (VideoExporter.swift:1425-1441) --------------------------

/** A CMTime as (value, timescale). */
export interface CMTimeValue {
  value: bigint;
  timescale: number;
}

/**
 * CMTime(seconds:preferredTimescale: 600).value — the product seconds x 600
 * TRUNCATED toward zero (measured against the real CMTime by the
 * exportFrameTimes + exportCameraReader vectors; NOT rounded). Single source:
 * exportLayout.cmTimeValue.
 */
export function cmTimeValue600(seconds: number): bigint {
  return BigInt(cmTimeValue(seconds, 600));
}

/** CMTimeCompare(a, b) <= 0 for numeric times (exact rational comparison). */
export function cmTimeLessOrEqual(a: CMTimeValue, b: CMTimeValue): boolean {
  return a.value * BigInt(b.timescale) <= b.value * BigInt(a.timescale);
}

/**
 * The exporter camera reader only ever walks FORWARD. Each output frame, when
 * currentTime - cameraTimeOffset >= 0, every sample whose PTS <= CMTime(seconds:
 * target, preferredTimescale: 600) is consumed and the last one becomes the
 * current camera frame. A backwards source jump (clip reorder) therefore keeps
 * showing the last decoded frame; a negative target does not advance and that
 * frame draws the poster instead (usesLive false).
 */
export class CameraReaderCursor {
  private next = 0;
  /** Index of the current decoded sample, -1 before the first. */
  current = -1;

  constructor(private readonly samples: readonly CMTimeValue[]) {}

  advance(currentTime: number, cameraTimeOffset: number): { target: number; current: number; usesLive: boolean } {
    const target = currentTime - cameraTimeOffset;
    if (target >= 0) {
      const cam: CMTimeValue = { value: cmTimeValue600(target), timescale: 600 };
      while (this.next < this.samples.length && cmTimeLessOrEqual(this.samples[this.next], cam)) {
        this.current = this.next;
        this.next++;
      }
    }
    return { target, current: this.current, usesLive: target >= 0 && this.current >= 0 };
  }
}
