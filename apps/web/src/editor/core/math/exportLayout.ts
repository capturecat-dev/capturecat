/**
 * The exporter's card layout — ports of VideoExporter.swift's private
 * `frameLayout`, `alignmentFractions`, `zoomAnchorPoint`, the geometry of
 * `compositeFrame`, `exportFrameTimes`, the export-time `canvasScale` and
 * hidden-menu-bar crop, and the `staticLayout` device-bezel shrink + card
 * corner radii.
 *
 * COORDINATES: these functions keep the exporter's CoreImage convention —
 * OUTPUT PIXELS, **Y-UP**, origin bottom-left (like the Swift they lock to).
 * Use `flipRectY` / `flipPointY` exactly once at the GPU boundary to get the
 * web renderer's Y-down space.
 *
 * GPU contract (compositeFrame): the source frame (pixel origin at 0,0) is
 * scaled by `videoScale` (downscales use a Lanczos resample in CI — a
 * high-quality minifying filter is required on the GPU), translated to
 * `videoRect.min`, CROPPED to `videoRect`, then zoom-transformed about the
 * focal anchor (`zoomTransform`, Lanczos again when zoom < 1), CROPPED to
 * `contentRect`, and masked by the inner rounded rect (`innerCornerRadius`,
 * squircle for device frames).
 *
 * Locked by the `exportFrameLayout`, `exportCardTransform`,
 * `exportFrameTimes`, `exportOutputGeometry` and `exportStaticLayout` vectors.
 */
import type { RecordingSourceKind } from "../model/enums";
import type { Point, ProjectSettings, Rect, Size } from "../model/types";
import {
  type AffineTransform,
  concatTransform,
  identityTransform,
  maxY,
  minX,
  minY,
  rectHeight,
  rectWidth,
  scaleTransform,
  scaledBy,
  translatedBy,
  translationTransform,
} from "./geometry";
import { alignment, customOrigin, type Fractions, isCustom } from "./placementMath";
import { smax, smin } from "./swift";

/** VideoExporter.FrameLayout (Y-up output pixels). */
export interface FrameLayout {
  contentRect: Rect;
  videoRect: Rect;
  videoScale: number;
}

type LayoutSettings = Pick<ProjectSettings, "backgroundPadding" | "videoPlacement" | "videoCustomX" | "videoCustomY">;

/** `alignmentFractions(for:)` — PlacementMath's Y-down fractions flipped to Y-up. */
export function alignmentFractions(settings: LayoutSettings): Fractions {
  const f = alignment(settings);
  return { x: f.x, y: 1 - f.y };
}

/** `frameLayout(sourceSize:outputSize:settings:canvasScale:)` */
export function frameLayout(
  sourceSize: Size,
  outputSize: Size,
  settings: LayoutSettings,
  canvasScale = 1,
): FrameLayout {
  // Heavy padding can never collapse the video: ≤ 35% of the smaller side.
  const requested = smax(0, settings.backgroundPadding * canvasScale);
  const padding = smin(requested, smin(outputSize.width, outputSize.height) * 0.35);
  const contentWidth = smax(1, outputSize.width - padding * 2);
  const contentHeight = smax(1, outputSize.height - padding * 2);
  const a = alignmentFractions(settings);
  const contentRect: Rect = {
    x: padding * (0.5 + a.x),
    y: padding * (0.5 + a.y),
    width: contentWidth,
    height: contentHeight,
  };

  const sourceWidth = smax(1, sourceSize.width);
  const sourceHeight = smax(1, sourceSize.height);
  const videoScale = smin(rectWidth(contentRect) / sourceWidth, rectHeight(contentRect) / sourceHeight);
  const videoWidth = sourceWidth * videoScale;
  const videoHeight = sourceHeight * videoScale;

  let videoX = minX(contentRect) + (rectWidth(contentRect) - videoWidth) * a.x;
  let videoY = minY(contentRect) + (rectHeight(contentRect) - videoHeight) * a.y;
  if (isCustom(settings)) {
    const f = alignment(settings); // Y-down
    const origin = customOrigin(f, outputSize, { width: videoWidth, height: videoHeight });
    videoX = origin.x;
    videoY = outputSize.height - origin.y - videoHeight;
  }
  return {
    contentRect,
    videoRect: { x: videoX, y: videoY, width: videoWidth, height: videoHeight },
    videoScale,
  };
}

/** `zoomAnchorPoint(focalPoint:videoRect:)` — focal (0–1, Y-down) → Y-up pixels. */
export function zoomAnchorPoint(focalPoint: Point, videoRect: Rect): Point {
  const clampedX = smax(0, smin(1, focalPoint.x));
  const clampedY = smax(0, smin(1, focalPoint.y));
  return {
    x: minX(videoRect) + clampedX * rectWidth(videoRect),
    y: maxY(videoRect) - clampedY * rectHeight(videoRect),
  };
}

/** Swift's `.ulpOfOne` for Double. */
const ULP_OF_ONE = 2.220446049250313e-16;

/** compositeFrame's zoom about the anchor. Two numerically distinct branches,
 * exactly as Swift computes them. */
export function zoomTransform(zoom: number, anchor: Point): { transform: AffineTransform; branch: "identity" | "lanczos" | "affine" } {
  const safeZoom = smax(zoom, 0.01);
  if (!(Math.abs(safeZoom - 1) > ULP_OF_ONE)) return { transform: { ...identityTransform }, branch: "identity" };
  if (safeZoom < 1) {
    // CILanczosScaleTransform about the origin, then translate by anchor·(1−z).
    const t = concatTransform(
      scaleTransform(safeZoom, safeZoom),
      translationTransform(anchor.x * (1 - safeZoom), anchor.y * (1 - safeZoom)),
    );
    return { transform: t, branch: "lanczos" };
  }
  let t = { ...identityTransform };
  t = translatedBy(t, anchor.x, anchor.y);
  t = scaledBy(t, safeZoom, safeZoom);
  t = translatedBy(t, -anchor.x, -anchor.y);
  return { transform: t, branch: "affine" };
}

/** The fit: source pixels → the card's video rect (before zoom). */
export function fitTransform(layout: FrameLayout): AffineTransform {
  return concatTransform(
    scaleTransform(layout.videoScale, layout.videoScale),
    translationTransform(minX(layout.videoRect), minY(layout.videoRect)),
  );
}

/** The whole card geometry for one frame (Y-up output pixels). */
export function cardTransform(layout: FrameLayout, zoom: number, focalPoint: Point) {
  const anchor = zoomAnchorPoint(focalPoint, layout.videoRect);
  const z = zoomTransform(zoom, anchor);
  const fit = fitTransform(layout);
  return {
    anchor,
    safeZoom: smax(zoom, 0.01),
    branch: z.branch,
    zoomTransform: z.transform,
    fitTransform: fit,
    sourceToOutput: concatTransform(fit, z.transform),
    /** Crop applied after the fit, before the zoom. */
    videoClip: layout.videoRect,
    /** Crop applied after the zoom. */
    contentClip: layout.contentRect,
  };
}

/**
 * `CMTime(seconds:preferredTimescale:).seconds` — MEASURED against the real
 * CMTime by the `exportFrameTimes` vectors: the value is `seconds × timescale`
 * TRUNCATED toward zero (not rounded), then value/timescale. So at 30 fps
 * frame 11 (11/30·600 = 219.99999999999997) samples t = 0.365, a 1/600 s
 * early — the exporter's frame clock carries this quantisation and the web
 * must reproduce it to sample the same instants.
 */
export function cmTimeSeconds(seconds: number, timescale = 600): number {
  return cmTimeValue(seconds, timescale) / timescale;
}

/** `CMTime(seconds:preferredTimescale:).value` — seconds × timescale truncated toward zero. */
export function cmTimeValue(seconds: number, timescale = 600): number {
  const v = Math.trunc(seconds * timescale);
  return v === 0 ? 0 : v;
}

/** `exportFrameTimes(duration:fps:startOffset:)` in OUTPUT seconds (1/600 s grid). */
export function exportFrameTimes(duration: number, fps: number, startOffset = 0): number[] {
  const safeFPS = smax(1, fps);
  const totalFrames = smax(1, Math.trunc(Math.ceil(smax(0, duration) * safeFPS)));
  const out: number[] = new Array(totalFrames);
  for (let index = 0; index < totalFrames; index++) {
    out[index] = cmTimeSeconds(index / safeFPS + startOffset, 600);
  }
  return out;
}

/** VideoExporter.export's `canvasScale`: spatial settings are authored in
 * PREVIEW points; headless exports (no editor window) use the output canvas
 * itself as the reference, i.e. scale 1. */
export function canvasScale(outputSize: Size, previewCanvasSize: Size | null): number {
  const ref =
    previewCanvasSize && previewCanvasSize.width > 0 && previewCanvasSize.height > 0 ? previewCanvasSize : outputSize;
  return smin(outputSize.width / ref.width, outputSize.height / ref.height);
}

/** VideoExporter.export's hidden-menu-bar crop fraction (0 = none). */
export function menuBarCrop(
  settings: Pick<ProjectSettings, "menuBarReplacement" | "menuBarHeight">,
  recordingSourceKind: RecordingSourceKind,
  sourceSegmentKinds: readonly RecordingSourceKind[],
): number {
  if (
    !(settings.menuBarReplacement === "Hidden" && recordingSourceKind !== "device" && !sourceSegmentKinds.includes("device"))
  ) {
    return 0;
  }
  return smin(0.12, smax(0, settings.menuBarHeight / 100));
}

/** The natural size the layout sees after the menu-bar crop (the same
 * formula cursorChain.menuBarCroppedSize applies to the cursor space). */
export function effectiveNaturalSize(naturalSize: Size, crop: number): Size {
  return { width: naturalSize.width, height: naturalSize.height * (1 - crop) };
}

/** Y-up ↔ Y-down conversions live in geometry.ts (single source). */
export { flipPointY, flipRectY } from "./geometry";
