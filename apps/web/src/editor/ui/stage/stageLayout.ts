/**
 * Stage layout — the web twin of `ZoomScrollView` (EditorShellViewController):
 * the letterboxed canvas the user edits on, its aspect, and the sizes the
 * engine renders at.
 *
 * Three rules, all from the Mac:
 *
 * 1. The canvas aspect is the EXPORT's: `ExportSettings.resolvedOutputSize(
 *    for: aspectRatio, sourceSize:)` (the Mac's `canvasAspectProvider`),
 *    re-derived on every aspect / resolution / custom-size / source change —
 *    here through the exact function the web exporter sizes its file with.
 * 2. Preview zoom is pure MAGNIFICATION. NSScrollView magnification leaves
 *    the document view's bounds alone, so `project.previewCanvasSize` — the
 *    reference every point-based setting (padding, corners, shadow, cursor,
 *    annotation / subtitle size, hit radii) is scaled against, and the one
 *    `VideoExporter` reads for `canvasScale` — is the UNMAGNIFIED letterboxed
 *    card. The engine's reference canvas is that size; the zoomed CSS size
 *    only decides how many pixels the stage renders.
 * 3. The backing store never exceeds what the GPU can hold (a 400 % stage on
 *    a Retina display would otherwise ask for > 8192 px textures).
 */
import type { ProjectSettings } from "../../core/model";
import type { AspectRatioId } from "../../engine/contract";
import { letterboxRect, resolvedOutputSize, type Size } from "../../engine/layout";
import type { ViewportSpec } from "../../engine/protocol";
import type { StageViewport } from "../shell/types";

/** Preview magnification bounds (`scroll.minMagnification` / `maxMagnification`). */
export const MIN_PREVIEW_ZOOM = 0.25;
export const MAX_PREVIEW_ZOOM = 4;

/** WebGPU `maxTextureDimension2D` the engine requests (engine/gpu/device.ts). */
export const MAX_BACKING_SIDE = 8192;
/** Backing-store pixel budget (the frame graph's intermediates are this size). */
export const MAX_BACKING_PIXELS = 4096 * 4096;

/**
 * The stage canvas aspect (w/h): the exported file's shape, from the SAME
 * `resolvedOutputSize` the exporter uses. `sourceSize` null = not loaded yet
 * (`.auto` then falls back to 16:9, like the Mac before its player loads).
 */
export function stageCanvasAspect(
  settings: Pick<ProjectSettings, "aspectRatio" | "exportSettings"> | null | undefined,
  sourceSize: Size | null,
): number {
  if (!settings) return 16 / 9;
  const out = resolvedOutputSize(settings.exportSettings, settings.aspectRatio as AspectRatioId, sourceSize ?? { width: 0, height: 0 });
  return out.width > 0 && out.height > 0 ? out.width / out.height : 16 / 9;
}

/**
 * The unmagnified letterboxed canvas inside the stage card — the Mac's
 * `project.previewCanvasSize` (`AspectRatio.letterboxRect(in: bounds, aspect:)`).
 */
export function stageReferenceSize(card: Size, aspect: number): Size {
  const r = letterboxRect({ x: 0, y: 0, width: card.width, height: card.height }, aspect);
  return { width: r.width, height: r.height };
}

/** Clamp a preview zoom to the magnification range. */
export function clampPreviewZoom(zoom: number): number {
  if (!Number.isFinite(zoom)) return 1;
  return Math.min(MAX_PREVIEW_ZOOM, Math.max(MIN_PREVIEW_ZOOM, zoom));
}

/**
 * The effective device-pixel ratio for a stage of `cssWidth × cssHeight`:
 * the display's, lowered only when the backing store would exceed the GPU's
 * texture limit or the pixel budget.
 */
export function backingDpr(cssWidth: number, cssHeight: number, dpr: number): number {
  const w = Math.max(1, cssWidth);
  const h = Math.max(1, cssHeight);
  let d = dpr > 0 ? dpr : 1;
  d = Math.min(d, MAX_BACKING_SIDE / w, MAX_BACKING_SIDE / h);
  if (w * h * d * d > MAX_BACKING_PIXELS) d = Math.sqrt(MAX_BACKING_PIXELS / (w * h));
  return d;
}

/**
 * Stage viewport → the engine's ViewportSpec. The reference canvas is the
 * unmagnified letterboxed card (reported by the stage), falling back to the
 * CSS size ÷ zoom — never the zoomed size, so the preview zoom magnifies
 * point-based sizes instead of re-laying them out, and the exporter (which
 * reads the same reference) is independent of it.
 */
export function engineViewport(v: StageViewport): ViewportSpec {
  const cssWidth = Math.max(1, Math.round(v.cssWidth));
  const cssHeight = Math.max(1, Math.round(v.cssHeight));
  const zoom = v.zoom > 0 ? v.zoom : 1;
  const ref = v.reference;
  const reference =
    ref && ref.width > 0 && ref.height > 0 ? { width: ref.width, height: ref.height } : { width: cssWidth / zoom, height: cssHeight / zoom };
  return { cssWidth, cssHeight, dpr: backingDpr(cssWidth, cssHeight, v.dpr), reference };
}
