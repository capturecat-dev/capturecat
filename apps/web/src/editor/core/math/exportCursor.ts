/**
 * The Mac exporter's PRIVATE cursor pipeline, as numbers — ports of
 * Services/VideoExporter.swift (commit da569841c7b63175bffa46d897457f157224774d):
 *
 *   - `export` locals ≈ lines 331–408: `canvasScale`, `fullCursorCoordinateSize`,
 *     `sourceToOutputScale`, `maximumZoom`, `cursorRasterScale` (+ the
 *     menu-bar crop in ./cursorChain.ts)            → `exportCanvasScale`, `exportCursorSetup`
 *   - the per-frame gate ≈ lines 1486–1490, 1736–1781 → `exportCursorFrame`
 *   - `shouldHideCursor` ≈ 3240                       → `shouldHideCursor`
 *   - `renderClickRipple` ≈ 3290                      → `renderClickRipple`
 *   - `renderCursorCI` + `manualDropShadow` ≈ 3354–3490 → `cursorSpriteComposite`
 *   - `renderCursor` + `drawFallbackCursor` ≈ 3492–3613 → `cursorCGFallback`
 *   - `makeCursorAsset` ≈ 3557                        → `makeCursorAsset`
 *
 * All private/inline → locked by VERBATIM-ORACLE golden vectors
 * (`exportCursorShouldHide`, `exportCursorSetup`, `exportCursorComposite`,
 * `exportCursorCGFallback`) that call the real shared types
 * (CursorOverlayLayout, CursorPhysicsMath, ClickRippleOverlay,
 * CursorStyleProvider, CGRect.applying) wherever those are reachable.
 *
 * SPACES. The exporter composites in CoreImage: output PIXELS, Y-UP, origin
 * bottom-left. `layout.videoRect` (from frameLayout) is Y-up. The cursor
 * layout itself is computed Y-DOWN (`viewRect(from:canvasHeight:)` flips the
 * card rect first) and flipped back with `imageSpaceRect(in:)`. Every
 * `...YUp` value below is CI space; `spriteTransformYDown` is the same mapping
 * for a Y-down GPU pass (texel v from the TOP row → output y from the top).
 *
 * WHAT THE GPU CURSOR PASS MUST DO (renderCursorCI, the path every export
 * takes on macOS — `renderCursor` is only the rasterization-failed fallback):
 *   1. Skip when `shouldHideCursor` or when the layout guard fails (null).
 *   2. Sample the style raster (`rasterPixelSize` texels, artwork stretched to
 *      fill — see ./cursorStyleProvider.ts) through `spriteTransformYDown`
 *      (= scale texels → drawRect, then the tip-pinned physics pose), bilinear
 *      (CoreImage default sampling; it only ever DOWNsamples, the raster scale
 *      includes 1.25× slack).
 *   3. Drop shadow under the sprite: the sprite's alpha × `shadow.opacity`
 *      (0.3) in black, Gaussian-blurred with sigma `shadow.sigma`
 *      (= shadowBlurRadius·canvasScale·0.5 — CIGaussianBlur's radius IS a
 *      sigma; the CALayer shadowRadius is ~2σ), offset by
 *      `shadow.offsetYDown` (= +1·canvasScale px DOWN), sprite composited
 *      source-over on top, then the pair source-over onto the frame. (macOS 26+
 *      runs CIDropShadow with `dropShadow.*` — radius = the CALayer radius,
 *      its internal blur model is undocumented; pre-26 the manual twin with
 *      `shadow.*`, whose parameters are the explicit ones the web follows.)
 *   4. The ripple overlay (`renderClickRipple`) composites AFTER the cursor, and
 *      only when the cursor itself was eligible (showCursor + fresh position +
 *      a source frame), even if auto-hide hid the sprite.
 */
import { canvasScale as layoutCanvasScale } from "./exportLayout";
import type { CursorEvent, Point, Project, ProjectSettings, Rect, Size } from "../model/types";
import type { CursorStyle } from "../model/enums";
import type { AffineTransform } from "./geometry";
import {
  concatTransform,
  identityTransform,
  insetBy,
  maxX,
  maxY,
  minX,
  minY,
  rectHeight,
  rectWidth,
  scaleTransform,
  translationTransform,
} from "./geometry";
import {
  imageSpaceRect,
  make as makeOverlayLayout,
  resolveCoordinateSize,
  shadowBlurRadius,
  shadowOffset,
  shadowOpacity,
  viewRect,
  type CursorOverlayLayout,
} from "./cursorOverlayLayout";
import {
  affineTransform as physicsAffineTransform,
  isIdentity,
  pose as physicsPose,
  yFlipped,
  type Pose,
} from "./cursorPhysicsMath";
import {
  activeRipples,
  dragHighlightRuns,
  dragHighlightStrength,
  renderForExport,
  type RippleExportDraw,
} from "./clickRippleOverlay";
import { interpolateIfFresh } from "./cursorSmoother";
import { asset as styleAsset, rasterPixelSize } from "./cursorStyleProvider";
import { menuBarCrop, menuBarCroppedSize } from "./cursorChain";
import { chypot } from "./cursorSupport";
import { seqMax, smax, smin } from "./swift";

// ── export() setup ──────────────────────────────────────────────────────────

/** `canvasScale` (export ≈ 331–339): output ÷ the editor's preview canvas
 * (the output itself when there was no editor window). Uniform in practice. */
export function exportCanvasScale(outputSize: Size, previewCanvasSize: Size): number {
  // Single source: exportLayout.canvasScale.
  return layoutCanvasScale(outputSize, previewCanvasSize);
}

export interface ExportCursorSetup {
  /** `CursorOverlayLayout.resolveCoordinateSize(recordedSize:, fallbackSourceSize: naturalSize)`. */
  fullCursorCoordinateSize: Size;
  sourceToOutputScale: number;
  /** `max(1, zoomRegions.map(\.zoomLevel).max() ?? 1)`. */
  maximumZoom: number;
  /** Raster density for the cursor sprite (≥ 1). */
  cursorRasterScale: number;
  menuBarCrop: number;
  /** Natural size minus the cropped menu-bar strip (layout input). */
  effectiveNaturalSize: Size;
  /** Cursor coordinate space after the crop — `displayWidth/Height` and every
   * cursor consumer's `coordinateSize`. */
  resolvedCursorCoordinateSize: Size;
}

/**
 * The per-export cursor numbers (export ≈ 345–408). `cursorCoordinateSize` is
 * the recording's size when valid, else zero (./cursorChain.ts
 * `recordingCoordinateSize`). Events must be shifted separately with
 * `shiftForMenuBarCrop(events, fullCursorCoordinateSize, menuBarCrop)`.
 */
export function exportCursorSetup(
  cursorCoordinateSize: Size,
  naturalSize: Size,
  outputSize: Size,
  settings: Pick<ProjectSettings, "cursorScale" | "menuBarReplacement" | "menuBarHeight">,
  project: Pick<Project, "zoomRegions" | "recordingSourceKind" | "sourceSegments">,
): ExportCursorSetup {
  const fullCursorCoordinateSize = resolveCoordinateSize(cursorCoordinateSize, naturalSize);
  const sourceToOutputScale = smin(
    outputSize.width / smax(1, fullCursorCoordinateSize.width),
    outputSize.height / smax(1, fullCursorCoordinateSize.height),
  );
  const maximumZoom = smax(1, seqMax(project.zoomRegions.map((z) => z.zoomLevel)) ?? 1);
  const cursorRasterScale = smax(1, sourceToOutputScale * (settings.cursorScale * maximumZoom) * 1.25);
  const crop = menuBarCrop(settings, project);
  return {
    fullCursorCoordinateSize,
    sourceToOutputScale,
    maximumZoom,
    cursorRasterScale,
    menuBarCrop: crop,
    effectiveNaturalSize: menuBarCroppedSize(naturalSize, crop),
    resolvedCursorCoordinateSize: menuBarCroppedSize(fullCursorCoordinateSize, crop),
  };
}

/** `CursorAsset` minus the CGImage: what the sprite pass needs. */
export interface ExportCursorAsset {
  /** Layout `cursorSize` (points). */
  baseSize: Size;
  hotSpot: Point;
  /** The raster's pixel grid (`cgImage.width/height`), or null when
   * rasterization failed (then the CG fallback path draws a vector arrow). */
  rasterPixelSize: Size | null;
}

/** `makeCursorAsset(style:rasterScale:)` sizing (rasterization assumed to
 * succeed — it does for every built-in style). */
export function makeCursorAsset(style: CursorStyle, rasterScale: number): ExportCursorAsset {
  const a = styleAsset(style);
  const imageSize = a.imageSize;
  if (imageSize.width > 0 && imageSize.height > 0) {
    return {
      baseSize: { ...imageSize },
      hotSpot: { ...a.hotSpot },
      rasterPixelSize: rasterPixelSize({
        width: imageSize.width * rasterScale,
        height: imageSize.height * rasterScale,
      }),
    };
  }
  return {
    baseSize: imageSize.width > 0 && imageSize.height > 0 ? imageSize : { width: 20, height: 28 },
    hotSpot: { ...a.hotSpot },
    rasterPixelSize: null,
  };
}

// ── per-frame ───────────────────────────────────────────────────────────────

/** `shouldHideCursor(at:cursorEvents:settings:)` — auto-hide when the pointer
 * moved < 5 recording points over the last `autoHideDelay` seconds. */
export function shouldHideCursor(
  currentTime: number,
  cursorEvents: readonly CursorEvent[],
  settings: Pick<ProjectSettings, "autoHideCursor" | "autoHideDelay">,
): boolean {
  if (!settings.autoHideCursor) return false;
  if (!(cursorEvents.length > 1)) return false;
  const recent = cursorEvents.filter(
    (e) => e.timestamp >= currentTime - settings.autoHideDelay && e.timestamp <= currentTime,
  );
  if (!(recent.length > 1)) return false;
  const first = recent[0];
  const last = recent[recent.length - 1];
  const dist = chypot(last.x - first.x, last.y - first.y);
  return dist < 5;
}

export interface ExportCursorFrame {
  /** `cursorSmoother.interpolateIfFresh(events:at:)` (null when no events). */
  cursorPosition: Point | null;
  /** The cursor sprite pass runs (it may still be auto-hidden inside). */
  drawCursor: boolean;
  /** The ripple pass runs (nested inside the cursor gate). */
  drawRipples: boolean;
}

/**
 * The export loop's cursor gate: `settings.showCursor, let cursorPosition,
 * sourceExtent.width > 0, sourceExtent.height > 0` — `hasSourceFrame` is that
 * extent test. `currentTime` is SOURCE seconds (`timelineSourceTimes[i]`);
 * `cursorEvents` are the chain-processed, menu-bar-shifted events.
 */
export function exportCursorFrame(
  currentTime: number,
  cursorEvents: readonly CursorEvent[],
  settings: Pick<ProjectSettings, "showCursor" | "showClickRipple">,
  hasSourceFrame: boolean,
): ExportCursorFrame {
  const cursorPosition = cursorEvents.length > 0 ? interpolateIfFresh(cursorEvents, currentTime) : null;
  const drawCursor = settings.showCursor && cursorPosition !== null && hasSourceFrame;
  return { cursorPosition, drawCursor, drawRipples: drawCursor && settings.showClickRipple };
}

export type CursorSpriteSettings = Pick<
  ProjectSettings,
  | "autoHideCursor"
  | "autoHideDelay"
  | "cursorScale"
  | "cursorTilt"
  | "cursorStretch"
  | "cursorDrag"
  | "cursorWeight"
>;

export interface CursorSpriteComposite {
  /** Card rect in Y-DOWN output pixels (`viewRect(from: layout.videoRect, …)`). */
  videoRectInViewSpace: Rect;
  /** `CursorOverlayLayout.make(...)` — Y-DOWN output pixels. */
  layout: CursorOverlayLayout;
  /** `layout.imageSpaceRect(in: outputHeight)` — Y-UP. */
  drawRect: Rect;
  /** `drawRect.width / max(1, rasterPixelWidth)` (and height). */
  rasterScaleX: number;
  rasterScaleY: number;
  /** Raster texels (Y-up) → drawRect: scale then translate(drawRect.minX, minY). */
  placeTransform: AffineTransform;
  /** `CursorPhysicsMath.pose(...)` in Y-down view space. */
  pose: Pose;
  /** `pose.yFlipped()` — what the exporter applies in CI space. */
  ciPose: Pose;
  poseIsIdentity: boolean;
  /** Hotspot in CI space: (hotspot.x, H − hotspot.y). */
  tipCI: Point;
  /** `CursorPhysicsMath.affineTransform(pose: ciPose, tip: tipCI, spriteHeight: drawRect.height)`
   * (identity when the pose is identity — the exporter skips it). */
  physicsTransform: AffineTransform;
  /** Raster texel (Y-up, CI) → output (Y-up, CI): place, then physics. */
  spriteTransform: AffineTransform;
  /** Raster texel (Y-DOWN, v from the top row) → output (Y-DOWN). */
  spriteTransformYDown: AffineTransform;
  /** `CGRect(origin: .zero, size: raster).applying(spriteTransform)` — the
   * placed sprite's bounding box in output pixels, Y-up (a scissor rect for
   * the GPU pass). CoreImage's own `positioned.extent` is the INTEGRAL
   * version of this box (outward-rounded, with a ~1e-3 px snap to the nearest
   * integer, CGRect.null for a zero-scale sprite); it only sizes the
   * transparent border that keeps the shadow from clamping edge pixels and
   * never reaches pixels, so it is not ported. */
  spriteBounds: Rect;
  /** Transparent border added before the shadow (px). A GPU pass that blurs
   * with transparent (zero) out-of-bounds sampling needs no border at all. */
  shadowPad: number;
  /** `spriteBounds.insetBy(dx: -pad, dy: -pad)` (Y-up). */
  paddedBounds: Rect;
  /** CIDropShadow parameters (macOS 26+), CI space. */
  dropShadow: { radius: number; opacity: number; offsetX: number; offsetY: number };
  /** manualDropShadow parameters (the explicit twin). */
  shadow: {
    /** CIColorMatrix alpha row w: silhouette alpha multiplier. */
    opacity: number;
    /** CIGaussianBlur inputRadius (a sigma). */
    sigma: number;
    offsetX: number;
    /** CI space (Y-up): negative = down. */
    offsetYUp: number;
    /** Same offset for a Y-down pass. */
    offsetYDown: number;
  };
}

/** `rect.applying(t)` (CGRectApplyAffineTransform): the 4 transformed
 * corners' bounding box. */
function rectBoundingBox(r: Rect, t: AffineTransform): Rect {
  const x0 = minX(r);
  const x1 = maxX(r);
  const y0 = minY(r);
  const y1 = maxY(r);
  const xs = [
    t.a * x0 + t.c * y0 + t.tx,
    t.a * x1 + t.c * y0 + t.tx,
    t.a * x0 + t.c * y1 + t.tx,
    t.a * x1 + t.c * y1 + t.tx,
  ];
  const ys = [
    t.b * x0 + t.d * y0 + t.ty,
    t.b * x1 + t.d * y0 + t.ty,
    t.b * x0 + t.d * y1 + t.ty,
    t.b * x1 + t.d * y1 + t.ty,
  ];
  const lx = Math.min(...xs);
  const hx = Math.max(...xs);
  const ly = Math.min(...ys);
  const hy = Math.max(...ys);
  return { x: lx, y: ly, width: hx - lx, height: hy - ly };
}

/**
 * `renderCursorCI(at:cursorPosition:cursorEvents:cursorAsset:scaledCursorCI:
 * cursorCoordinateSize:layout:onto:outputSize:settings:canvasScale:)` as
 * numbers. Null when the exporter returns the frame untouched (auto-hidden,
 * no coordinate space, or no layout). `layoutVideoRect` is the frame layout's
 * card rect in CI (Y-up) pixels; `cursorCoordinateSize` the resolved (cropped)
 * coordinate space; `rasterPixelSize` the sprite raster's pixel grid.
 */
export function cursorSpriteComposite(
  currentTime: number,
  cursorPosition: Point,
  cursorEvents: readonly CursorEvent[],
  asset: { baseSize: Size; hotSpot: Point; rasterPixelSize: Size },
  cursorCoordinateSize: Size,
  layoutVideoRect: Rect,
  outputSize: Size,
  settings: CursorSpriteSettings,
  canvasScale: number,
): CursorSpriteComposite | null {
  if (shouldHideCursor(currentTime, cursorEvents, settings)) return null;
  const resolvedCursorSpace = cursorCoordinateSize;
  if (!(resolvedCursorSpace.width > 0 && resolvedCursorSpace.height > 0)) return null;

  const videoRectInViewSpace = viewRect(layoutVideoRect, outputSize.height);
  const cursorLayout = makeOverlayLayout(
    cursorPosition,
    resolvedCursorSpace,
    videoRectInViewSpace,
    asset.baseSize,
    asset.hotSpot,
    settings.cursorScale,
  );
  if (cursorLayout === null) return null;

  const drawRect = imageSpaceRect(cursorLayout, outputSize.height);
  const scaleX = rectWidth(drawRect) / smax(1, asset.rasterPixelSize.width);
  const scaleY = rectHeight(drawRect) / smax(1, asset.rasterPixelSize.height);
  const placeTransform = concatTransform(
    scaleTransform(scaleX, scaleY),
    translationTransform(minX(drawRect), minY(drawRect)),
  );

  const p = physicsPose(
    cursorEvents,
    currentTime,
    resolvedCursorSpace,
    videoRectInViewSpace,
    rectHeight(cursorLayout.imageRect),
    settings.cursorTilt,
    settings.cursorStretch,
    settings.cursorDrag,
    settings.cursorWeight,
  );
  const ciPose = yFlipped(p);
  const poseIsIdentity = isIdentity(ciPose);
  const tipCI = { x: cursorLayout.hotspotPoint.x, y: outputSize.height - cursorLayout.hotspotPoint.y };
  const physicsTransform = poseIsIdentity
    ? { ...identityTransform }
    : physicsAffineTransform(ciPose, tipCI, rectHeight(drawRect));
  const spriteTransform = poseIsIdentity
    ? placeTransform
    : concatTransform(placeTransform, physicsTransform);

  const pw = asset.rasterPixelSize.width;
  const ph = asset.rasterPixelSize.height;
  const flipRaster: AffineTransform = { a: 1, b: 0, c: 0, d: -1, tx: 0, ty: ph };
  const flipOutput: AffineTransform = { a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outputSize.height };
  const spriteTransformYDown = concatTransform(concatTransform(flipRaster, spriteTransform), flipOutput);

  const spriteBounds = rectBoundingBox({ x: 0, y: 0, width: pw, height: ph }, spriteTransform);
  const shadowPad =
    (shadowBlurRadius + smax(Math.abs(shadowOffset.width), Math.abs(shadowOffset.height))) * canvasScale + 2;
  const paddedBounds = insetBy(spriteBounds, -shadowPad, -shadowPad);

  return {
    videoRectInViewSpace,
    layout: cursorLayout,
    drawRect,
    rasterScaleX: scaleX,
    rasterScaleY: scaleY,
    placeTransform,
    pose: p,
    ciPose,
    poseIsIdentity,
    tipCI,
    physicsTransform,
    spriteTransform,
    spriteTransformYDown,
    spriteBounds,
    shadowPad,
    paddedBounds,
    dropShadow: {
      radius: shadowBlurRadius * canvasScale,
      opacity: shadowOpacity,
      offsetX: shadowOffset.width * canvasScale,
      offsetY: -shadowOffset.height * canvasScale,
    },
    shadow: {
      opacity: shadowOpacity,
      sigma: shadowBlurRadius * canvasScale * 0.5,
      offsetX: shadowOffset.width * canvasScale,
      offsetYUp: -shadowOffset.height * canvasScale,
      offsetYDown: shadowOffset.height * canvasScale,
    },
  };
}

export interface CursorCGFallback {
  /** Y-UP output pixels (CGContext origin bottom-left). */
  drawRect: Rect;
  /** `ctx.setShadow(offset:blur:color:)` — CG Y-up offset, CG blur (≈ 2σ), black α. */
  shadowOffset: Size;
  shadowBlur: number;
  shadowAlpha: number;
  /** drawFallbackCursor (only when the raster is missing): closed polygon in
   * Y-up pixels, filled white then stroked black α0.9. */
  fallbackPath: Point[] | null;
  fallbackLineWidth: number | null;
}

/**
 * `renderCursor(...)` — the CoreGraphics fallback the exporter uses only when
 * the sprite raster is missing. NOTE (faithful): this path applies NO physics
 * pose. Null when the frame is returned untouched.
 */
export function cursorCGFallback(
  currentTime: number,
  cursorPosition: Point,
  cursorEvents: readonly CursorEvent[],
  asset: { baseSize: Size; hotSpot: Point; hasRaster: boolean },
  cursorCoordinateSize: Size,
  layoutVideoRect: Rect,
  outputSize: Size,
  settings: Pick<ProjectSettings, "autoHideCursor" | "autoHideDelay" | "cursorScale">,
  canvasScale: number,
): CursorCGFallback | null {
  if (shouldHideCursor(currentTime, cursorEvents, settings)) return null;
  const resolvedCursorSpace = cursorCoordinateSize;
  if (!(resolvedCursorSpace.width > 0 && resolvedCursorSpace.height > 0)) return null;
  const videoRectInViewSpace = viewRect(layoutVideoRect, outputSize.height);
  const cursorLayout = makeOverlayLayout(
    cursorPosition,
    resolvedCursorSpace,
    videoRectInViewSpace,
    asset.baseSize,
    asset.hotSpot,
    settings.cursorScale,
  );
  if (cursorLayout === null) return null;
  const drawRect = imageSpaceRect(cursorLayout, outputSize.height);

  let fallbackPath: Point[] | null = null;
  let fallbackLineWidth: number | null = null;
  if (!asset.hasRaster) {
    const rect = drawRect;
    const point = (x: number, y: number): Point => ({
      x: minX(rect) + x * rectWidth(rect),
      y: maxY(rect) - y * rectHeight(rect),
    });
    fallbackPath = [
      point(0.0, 0.0),
      point(0.0, 1.0),
      point(0.35, 0.72),
      point(0.55, 1.0),
      point(0.72, 0.92),
      point(0.52, 0.65),
      point(1.0, 0.62),
    ];
    fallbackLineWidth = smax(1, rectWidth(rect) * 0.08);
  }
  return {
    drawRect,
    shadowOffset: { width: shadowOffset.width * canvasScale, height: -shadowOffset.height * canvasScale },
    shadowBlur: shadowBlurRadius * canvasScale,
    shadowAlpha: shadowOpacity,
    fallbackPath,
    fallbackLineWidth,
  };
}

export interface ClickRippleExport {
  /** `!activeRipples(...).isEmpty`. */
  hasRipple: boolean;
  /** `dragHighlightStrength(runs: dragHighlightRuns(...), at: currentTime)`. */
  dragStrength: number;
  /** The overlay draws (hasRipple || dragStrength > 0.01). */
  draws: boolean;
  /** What renderForExport draws (Y-UP output pixels), null when skipped. */
  draw: RippleExportDraw | null;
}

/**
 * `renderClickRipple(at:cursorEvents:cursorCoordinateSize:onto:outputSize:
 * layout:settings:)`: the skip predicate plus renderForExport's draw list with
 * `videoRect = layout.videoRect` (Y-UP), `sourceSize = cursorCoordinateSize`
 * (resolved/cropped), `rippleSize = settings.clickRippleSize`. The colour is
 * `settings.clickRippleColor` RGB with each op's alpha REPLACING its opacity.
 */
export function renderClickRipple(
  currentTime: number,
  cursorEvents: readonly CursorEvent[],
  cursorCoordinateSize: Size,
  layoutVideoRect: Rect,
  settings: Pick<ProjectSettings, "clickRippleSize">,
): ClickRippleExport {
  const hasRipple = activeRipples(cursorEvents, currentTime, cursorCoordinateSize, layoutVideoRect).length > 0;
  const dragStrength = dragHighlightStrength(dragHighlightRuns(cursorEvents, cursorCoordinateSize), currentTime);
  const draws = hasRipple || dragStrength > 0.01;
  return {
    hasRipple,
    dragStrength,
    draws,
    draw: draws
      ? renderForExport(cursorEvents, currentTime, layoutVideoRect, cursorCoordinateSize, settings.clickRippleSize)
      : null,
  };
}
