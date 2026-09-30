/**
 * Port of Models/AspectRatio.swift + Models/ExportSettings.swift geometry:
 * the canvas aspect shared by the editor's letterboxed preview and the
 * exporter's output size, the letterbox fit, and the exported pixel size /
 * bitrate. Locked by the `exportOutputGeometry` vectors.
 */
import type { AspectRatio } from "../model/enums";
import type { ExportSettings, Rect, Size } from "../model/types";
import { cround, sInt, smax, smin, srounded } from "./swift";
import { minX, minY, rectHeight, rectWidth } from "./geometry";

/** `AspectRatio.size` (nil for `.auto`). */
export function aspectSize(a: AspectRatio): Size | null {
  switch (a) {
    case "Auto":
      return null;
    case "16:9":
      return { width: 16, height: 9 };
    case "4:3":
      return { width: 4, height: 3 };
    case "1:1":
      return { width: 1, height: 1 };
    case "9:16":
      return { width: 9, height: 16 };
    case "21:9":
      return { width: 21, height: 9 };
    case "4:5":
      return { width: 4, height: 5 };
  }
}

/** `AspectRatio.resolution(fitting:)` */
export function resolutionFitting(a: AspectRatio, width: number): Size {
  const ratio = aspectSize(a);
  if (!ratio) return { width, height: (width * 9) / 16 };
  return { width, height: (width * ratio.height) / ratio.width };
}

/** `AspectRatio.canvasAspect(sourceSize:)` — `.auto` follows the source
 * (16:9 when unknown). */
export function canvasAspect(a: AspectRatio, sourceSize: Size): number {
  const ratio = aspectSize(a);
  if (ratio) return ratio.width / ratio.height;
  if (!(sourceSize.width > 0 && sourceSize.height > 0)) return 16.0 / 9.0;
  return sourceSize.width / sourceSize.height;
}

/** `AspectRatio.letterboxRect(in:aspect:)` — largest rect of `aspect` centred in `bounds`. */
export function letterboxRect(bounds: Rect, aspect: number): Rect {
  // CGRect.width/height are the standardized (absolute) sizes.
  const bw = rectWidth(bounds);
  const bh = rectHeight(bounds);
  if (!(bw > 0 && bh > 0 && aspect > 0)) return bounds;
  let w = bw;
  let h = bw / aspect;
  if (h > bh) {
    w = bh * aspect;
    h = bh;
  }
  return { x: minX(bounds) + (bw - w) / 2, y: minY(bounds) + (bh - h) / 2, width: w, height: h };
}

// ── ExportSettings ──────────────────────────────────────────────────────────

export const minimumQuality = 0.5;
export const maximumQuality = 1.0;

/** `ExportSettings.Resolution.width` */
export function resolutionWidth(r: ExportSettings["resolution"]): number {
  switch (r) {
    case "720p":
      return 1280;
    case "1080p":
      return 1920;
    case "4K":
      return 3840;
    case "Custom":
      return 1920;
  }
}

/** `ExportSettings.outputWidth` */
export function outputWidth(e: Pick<ExportSettings, "resolution" | "customWidth">): number {
  return e.resolution === "Custom" ? e.customWidth : resolutionWidth(e.resolution);
}

/** `ExportSettings.normalizedQuality` */
export function normalizedQuality(e: Pick<ExportSettings, "quality">): number {
  const clamped = smin(smax(e.quality, minimumQuality), maximumQuality);
  return (clamped - minimumQuality) / (maximumQuality - minimumQuality);
}

/** `ExportSettings.qualityPresetName` */
export function qualityPresetName(e: Pick<ExportSettings, "quality">): string {
  const q = normalizedQuality(e);
  if (q < 0.2) return "Draft";
  if (q < 0.45) return "Good";
  if (q < 0.75) return "High";
  return "Master";
}

function sanitizedDimension(value: number): number {
  const clamped = smax(2, value);
  return clamped % 2 === 0 ? clamped : clamped + 1;
}

/** `ExportSettings.resolvedOutputSize(for:sourceSize:)` — the exported pixel
 * size; `.auto` keeps the source's shape (preview == export). */
export function resolvedOutputSize(
  e: Pick<ExportSettings, "resolution" | "customWidth" | "customHeight">,
  aspectRatio: AspectRatio,
  sourceSize: Size,
): Size {
  const width = sanitizedDimension(e.resolution === "Custom" ? e.customWidth : resolutionWidth(e.resolution));
  if (e.resolution === "Custom") {
    return { width, height: sanitizedDimension(e.customHeight) };
  }
  const aspect = canvasAspect(aspectRatio, sourceSize);
  return { width, height: sanitizedDimension(sInt(cround(width / smax(0.01, aspect)))) };
}

/** `ExportSettings.estimatedVideoBitRate(for:sourceSize:)` */
export function estimatedVideoBitRate(
  e: Pick<ExportSettings, "resolution" | "customWidth" | "customHeight" | "fps" | "quality">,
  aspectRatio: AspectRatio,
  sourceSize: Size,
): number {
  const out = resolvedOutputSize(e, aspectRatio, sourceSize);
  const pixelsPerFrame = out.width * out.height;
  const framesPerSecond = smax(1, e.fps);
  const bitsPerPixelPerFrame = 0.08 + Math.pow(normalizedQuality(e), 1.15) * 0.16;
  const targetBitRate = pixelsPerFrame * framesPerSecond * bitsPerPixelPerFrame;
  return smax(3_000_000, sInt(srounded(targetBitRate)));
}
