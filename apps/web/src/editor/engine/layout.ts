/**
 * Card layout math — literal ports of the Mac exporter's static geometry.
 *
 * Every function here names its Swift original. They are PURE (no DOM, no
 * GPU) and are candidates to move into `editor/core/math` behind golden
 * vectors once the core port lands; until then this is the single TS copy
 * both the preview and the web exporter consume (they share the passes, so
 * they cannot fork).
 *
 * Coordinate conventions:
 *  - `frameLayoutYUp` is the literal Y-UP port of `VideoExporter.frameLayout`
 *    (CoreImage space, origin bottom-left).
 *  - Everything handed to the GPU is Y-DOWN pixels (origin top-left); the
 *    single flip is `rectYUpToYDown`.
 */
import type { AspectRatioId, RenderExportSettings, RenderSettings, VideoPlacement } from "./contract";
import { cmTimeValue } from "../core/math/exportLayout";
import {
  bezelCornerRadius,
  bezelRect,
  isPhoneAspect,
  screenCornerRadius,
} from "../core/math/deviceFrameLayout";
import { staticLayout } from "../core/math/exportStaticLayout";

export interface Size {
  width: number;
  height: number;
}
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

// ── AspectRatio.swift ───────────────────────────────────────────────────────

const ASPECT_SIZES: Record<AspectRatioId, Size | null> = {
  Auto: null,
  "16:9": { width: 16, height: 9 },
  "4:3": { width: 4, height: 3 },
  "1:1": { width: 1, height: 1 },
  "9:16": { width: 9, height: 16 },
  "21:9": { width: 21, height: 9 },
  "4:5": { width: 4, height: 5 },
};

/** `AspectRatio.canvasAspect(sourceSize:)` */
export function canvasAspect(aspect: AspectRatioId, sourceSize: Size): number {
  const r = ASPECT_SIZES[aspect];
  if (r) return r.width / r.height;
  if (!(sourceSize.width > 0 && sourceSize.height > 0)) return 16 / 9;
  return sourceSize.width / sourceSize.height;
}

/** `AspectRatio.letterboxRect(in:aspect:)` */
export function letterboxRect(bounds: Rect, aspect: number): Rect {
  if (!(bounds.width > 0 && bounds.height > 0 && aspect > 0)) return bounds;
  let w = bounds.width;
  let h = bounds.width / aspect;
  if (h > bounds.height) {
    w = bounds.height * aspect;
    h = bounds.height;
  }
  return { x: bounds.x + (bounds.width - w) / 2, y: bounds.y + (bounds.height - h) / 2, width: w, height: h };
}

// ── ExportSettings.swift ────────────────────────────────────────────────────

const RESOLUTION_WIDTH = { "720p": 1280, "1080p": 1920, "4K": 3840, Custom: 1920 } as const;

/** `ExportSettings.sanitizedDimension` */
function sanitizedDimension(value: number): number {
  const clamped = Math.max(2, Math.trunc(value));
  return clamped % 2 === 0 ? clamped : clamped + 1;
}

/** `ExportSettings.resolvedOutputSize(for:sourceSize:)` */
export function resolvedOutputSize(e: RenderExportSettings, aspect: AspectRatioId, sourceSize: Size): Size {
  const width = sanitizedDimension(e.resolution === "Custom" ? e.customWidth : RESOLUTION_WIDTH[e.resolution]);
  if (e.resolution === "Custom") return { width, height: sanitizedDimension(e.customHeight) };
  const a = canvasAspect(aspect, sourceSize);
  // Swift: Int(round(width / max(0.01, aspect))) — round half away from zero.
  const h = swiftRound(width / Math.max(0.01, a));
  return { width, height: sanitizedDimension(h) };
}

/** `ExportSettings.normalizedQuality` */
export function normalizedQuality(e: RenderExportSettings): number {
  const q = Math.min(Math.max(e.quality, 0.5), 1);
  return (q - 0.5) / 0.5;
}

/** `ExportSettings.estimatedVideoBitRate(for:sourceSize:)` */
export function estimatedVideoBitRate(e: RenderExportSettings, outputSize: Size): number {
  const pixelsPerFrame = outputSize.width * outputSize.height;
  const fps = Math.max(1, e.fps);
  const bpp = 0.08 + Math.pow(normalizedQuality(e), 1.15) * 0.16;
  return Math.max(3_000_000, swiftRound(pixelsPerFrame * fps * bpp));
}

/** Swift `.rounded()` (schoolbook: half away from zero). */
export function swiftRound(v: number): number {
  return v < 0 ? -Math.round(-v) : Math.round(v);
}

// ── VideoExporter.exportFrameTimes ──────────────────────────────────────────

/**
 * Output frame times in seconds. The Mac wraps each in
 * `CMTime(seconds:preferredTimescale: 600)`; for the fps values the app
 * offers (24/25/30/50/60) i/fps is an exact multiple of 1/600, so the float
 * here is the same instant.
 */
export function exportFrameCount(duration: number, fps: number): number {
  const safeFPS = Math.max(1, Math.trunc(fps));
  return Math.max(1, Math.ceil(Math.max(0, duration) * safeFPS));
}
export function exportFrameTime(index: number, fps: number): number {
  return index / Math.max(1, Math.trunc(fps));
}
/**
 * `CMTime(seconds: t, preferredTimescale: 600)` — the export's source-time
 * quantum. CoreMedia TRUNCATES toward zero (measured: 0.8333333333333333 s →
 * 499/600, not 500), so a source time landing a hair under a frame boundary
 * reads the PREVIOUS frame — the barcode in parity fixture 12 proves it.
 */
export function cmTime600(seconds: number): number {
  return cmTimeValue(seconds, 600) / 600;
}

// ── PlacementMath.swift ─────────────────────────────────────────────────────

const PLACEMENT_FRACTIONS: Record<VideoPlacement, [number, number]> = {
  "Top Left": [0, 0],
  Top: [0.5, 0],
  "Top Right": [1, 0],
  Left: [0, 0.5],
  Center: [0.5, 0.5],
  Right: [1, 0.5],
  "Bottom Left": [0, 1],
  Bottom: [0.5, 1],
  "Bottom Right": [1, 1],
};

export function placementIsCustom(s: RenderSettings): boolean {
  return s.videoCustomX !== null && s.videoCustomY !== null;
}

/** `PlacementMath.alignment(for:)` — Y-DOWN fractions. */
export function placementAlignment(s: RenderSettings): { x: number; y: number } {
  if (s.videoCustomX !== null && s.videoCustomY !== null) {
    const lo = -1;
    const hi = 2;
    return {
      x: Math.min(hi, Math.max(lo, s.videoCustomX)),
      y: Math.min(hi, Math.max(lo, s.videoCustomY)),
    };
  }
  const f = PLACEMENT_FRACTIONS[s.videoPlacement] ?? [0.5, 0.5];
  return { x: f[0], y: f[1] };
}

/** `PlacementMath.customOrigin(fraction:canvas:video:)` — Y-DOWN. */
export function placementCustomOrigin(f: { x: number; y: number }, canvas: Size, video: Size) {
  return { x: canvas.width * f.x - video.width / 2, y: canvas.height * f.y - video.height / 2 };
}

// ── VideoExporter.frameLayout ───────────────────────────────────────────────

export interface FrameLayout {
  contentRect: Rect;
  videoRect: Rect;
  videoScale: number;
}

/** Literal Y-UP port of `VideoExporter.frameLayout(sourceSize:outputSize:settings:canvasScale:)`. */
export function frameLayoutYUp(sourceSize: Size, outputSize: Size, s: RenderSettings, canvasScale = 1): FrameLayout {
  const requested = Math.max(0, s.backgroundPadding * canvasScale);
  const padding = Math.min(requested, Math.min(outputSize.width, outputSize.height) * 0.35);
  const contentWidth = Math.max(1, outputSize.width - padding * 2);
  const contentHeight = Math.max(1, outputSize.height - padding * 2);
  // alignmentFractions(for:) — PlacementMath is Y-down; flip exactly once.
  const f = placementAlignment(s);
  const alignment = { x: f.x, y: 1 - f.y };
  const contentRect: Rect = {
    x: padding * (0.5 + alignment.x),
    y: padding * (0.5 + alignment.y),
    width: contentWidth,
    height: contentHeight,
  };
  const sourceWidth = Math.max(1, sourceSize.width);
  const sourceHeight = Math.max(1, sourceSize.height);
  const videoScale = Math.min(contentRect.width / sourceWidth, contentRect.height / sourceHeight);
  const videoWidth = sourceWidth * videoScale;
  const videoHeight = sourceHeight * videoScale;
  let videoX = contentRect.x + (contentRect.width - videoWidth) * alignment.x;
  let videoY = contentRect.y + (contentRect.height - videoHeight) * alignment.y;
  if (placementIsCustom(s)) {
    const origin = placementCustomOrigin(f, outputSize, { width: videoWidth, height: videoHeight });
    videoX = origin.x;
    videoY = outputSize.height - origin.y - videoHeight;
  }
  return {
    contentRect,
    videoRect: { x: videoX, y: videoY, width: videoWidth, height: videoHeight },
    videoScale,
  };
}

export function rectYUpToYDown(r: Rect, canvasHeight: number): Rect {
  return { x: r.x, y: canvasHeight - r.y - r.height, width: r.width, height: r.height };
}

/**
 * The exporter's canvas scale: spatial settings are in reference-canvas
 * points. On the Mac the reference is `project.previewCanvasSize` (the live
 * editor canvas), or the output size itself for headless exports.
 */
export function canvasScaleFor(target: Size, reference: Size | null): number {
  const ref = reference && reference.width > 0 && reference.height > 0 ? reference : target;
  return Math.min(target.width / ref.width, target.height / ref.height);
}

// ── Resolved card geometry (everything the card + shadow passes need) ───────

/** Mask shapes. "rect" = plain rectangle coverage; "none" = no mask at all (crop only). */
export type ShapeKind = "rect" | "roundedRect" | "squircle";

export interface CardGeometry {
  target: Size;
  canvasScale: number;
  /** Y-DOWN pixels. */
  contentRect: Rect;
  videoRect: Rect;
  videoScale: number;
  /** Window-clip mask (inner radius, circular corners) — `cachedWindowMask`. */
  inner: { kind: ShapeKind | "none"; radius: number };
  /** Outer frame-clip mask (`cachedOuterMask`) — nil for .rectangle or radius 0. */
  outer: { kind: ShapeKind | "none"; radius: number };
  /**
   * Source pixels removed from the TOP of the recording (Hidden menu bar:
   * `naturalSize.height × menuBarCrop`). The layout uses the shrunken size and
   * the frame is bottom-aligned in the video rect, so the strip spills above
   * it and is cropped away (`compositeFrame`). 0 otherwise.
   */
  sourceCropTop: number;
  /**
   * Framed device take (iPhone/iPad bezel): the video rect is the SCREEN
   * (shrunk for bezel room), `outer` is its continuous-corner screen mask and
   * the shadow hugs the bezel. Null for every other take.
   */
  device: null | {
    /** Screen (= videoRect), Y-down px. */
    screenRect: Rect;
    screenCornerRadius: number;
    /** Titanium body, Y-down px. */
    bezelRect: Rect;
    bezelCornerRadius: number;
    /** Portrait-phone aspect: Dynamic Island + side buttons + glass margin. */
    isPhone: boolean;
  };
  /** `makeFrameShadow` inputs, resolved; null when the guard fails. */
  shadow: null | {
    rect: Rect;
    shape: ShapeKind;
    cornerRadius: number;
    /** CIGaussianBlur radius == sigma == shadowRadius / 2 (CG radius ≈ 2σ). */
    sigma: number;
    /** Y-DOWN pixels the blurred shadow moves (down by radius / 3). */
    offsetY: number;
    /** Premultiplied black alpha before the blur: shadowOpacity * 0.45. */
    alpha: number;
  };
}

/**
 * Mirrors the static pre-computation block of `VideoExporter.export` (the
 * `staticLayout`, `outerCornerRadius`, `innerCornerRadius`, `cachedWindowMask`,
 * `cachedOuterMask` and `cardStaticOverlay` → `makeFrameShadow` inputs),
 * including the Hidden-menu-bar crop (`effectiveNaturalSize`) and framed
 * device takes (bezel room via core `staticLayout`, squircle screen mask,
 * shadow hugging the bezel).
 */
export function cardGeometry(
  sourceSize: Size,
  target: Size,
  s: RenderSettings,
  reference: Size | null,
): CardGeometry {
  const canvasScale = canvasScaleFor(target, reference);
  // Hidden menu bar: the layout sees `effectiveNaturalSize`.
  const crop = s.menuBarCrop ?? 0;
  const effective = { width: sourceSize.width, height: sourceSize.height * (1 - crop) };
  const device = s.deviceFrameActive === true;
  const layout = frameLayoutYUp(effective, target, s, canvasScale);
  // `staticLayout`: device takes reserve bezel room (core, golden-locked).
  const st = staticLayout(layout, device, s, canvasScale);
  const up = st.layout;
  const outerCornerRadius = st.outerCornerRadius;
  const innerCornerRadius = st.innerCornerRadius;
  const videoRect = rectYUpToYDown(up.videoRect, target.height);
  const shadowRadius = Math.max(0, s.shadowRadius * canvasScale);
  const shadowOpacity = Math.max(0, s.shadowOpacity);
  const outerShape: ShapeKind = s.frameShape === "Squircle" ? "squircle" : "roundedRect";
  const common = {
    target,
    canvasScale,
    contentRect: rectYUpToYDown(up.contentRect, target.height),
    videoRect,
    videoScale: up.videoScale,
    sourceCropTop: sourceSize.height * crop,
  };
  if (device) {
    const size = { width: videoRect.width, height: videoRect.height };
    const bezel = bezelRect(videoRect);
    const bezelRadius = bezelCornerRadius(size);
    return {
      ...common,
      // The window mask is the continuous-corner SCREEN (squircle); there is
      // no frame clip (the bezel IS the frame). Coverage = inner × outer, so
      // the screen squircle rides the rasterised `outer` slot.
      inner: { kind: "none", radius: 0 },
      outer: { kind: innerCornerRadius > 0 ? "squircle" : "none", radius: innerCornerRadius },
      device: {
        screenRect: videoRect,
        screenCornerRadius: screenCornerRadius(size),
        bezelRect: bezel,
        bezelCornerRadius: bezelRadius,
        isPhone: isPhoneAspect(size),
      },
      shadow:
        shadowRadius > 0 && shadowOpacity > 0
          ? {
              rect: bezel,
              shape: "squircle",
              cornerRadius: bezelRadius,
              sigma: shadowRadius / 2,
              offsetY: shadowRadius / 3,
              alpha: shadowOpacity * 0.45,
            }
          : null,
    };
  }
  return {
    ...common,
    inner: { kind: innerCornerRadius > 0 ? "roundedRect" : "none", radius: innerCornerRadius },
    outer: { kind: outerCornerRadius > 0 ? outerShape : "none", radius: outerCornerRadius },
    device: null,
    shadow:
      shadowRadius > 0 && shadowOpacity > 0
        ? {
            rect: videoRect,
            // makeFrameShadow masks with frameShape even when the radius is 0
            // (.rectangle → plain rect path).
            shape: s.frameShape === "Rectangle" || outerCornerRadius <= 0 ? "rect" : outerShape,
            cornerRadius: outerCornerRadius,
            sigma: shadowRadius / 2,
            offsetY: shadowRadius / 3,
            alpha: shadowOpacity * 0.45,
          }
        : null,
  };
}
