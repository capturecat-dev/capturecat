/**
 * Stage hit rects — the canvas-level chrome the Mac's
 * `PreviewInteractionView.HitContext` carries (`cameraRect`, `subtitleRect`,
 * `watermarkRect`), reported by the passes that DREW them, from the very
 * rects they drew with (camera bubble: `exportFrameCamera`'s rect; subtitle:
 * `subtitleRecipe`'s pill; watermark: `watermarkPlacement`). The stage never
 * re-derives them.
 *
 * Each rect lives in the space its pass drew in:
 *   canvas  after the camera warp (the classic bubble, the watermark);
 *   card    before the warp (subtitles; the camera-layout tile) — the stage
 *           maps the pointer through the inverse camera, like annotations.
 * `usable` is the free-placement span of that layout function
 * (`W − 2·edgePad − rect.w`, same for H) in the same px: the Mac's drag
 * divides the pointer delta by exactly this (PreviewInteractionView
 * mouseDragged `.camera/.watermark/.subtitle`).
 */
import type { Rect, Size } from "./layout";

export type StageHitKind = "camera" | "subtitle" | "watermark";
export type StageHitSpace = "canvas" | "card";

export interface StageHitRect {
  /** Y-down px of the render target (FrameInfo.target). */
  rect: Rect;
  space: StageHitSpace;
  usable: Size;
}

export type StageHits = Partial<Record<StageHitKind, StageHitRect>>;

/**
 * What a pass exposes to the frame graph: the rect it drew THIS frame. The
 * graph clears `current` before encoding a frame (a pass that does not draw
 * leaves it null) and collects every recorder after it.
 */
export interface StageHitRecorder {
  readonly kind: StageHitKind;
  current: StageHitRect | null;
}

export function stageHitRecorder(kind: StageHitKind): StageHitRecorder {
  return { kind, current: null };
}

/** Free-placement span of an edge-padded layout (`max(0, …)` like the passes). */
export function usableSpan(target: Size, edgePad: number, rect: Rect): Size {
  return {
    width: Math.max(0, target.width - 2 * edgePad - rect.width),
    height: Math.max(0, target.height - 2 * edgePad - rect.height),
  };
}
