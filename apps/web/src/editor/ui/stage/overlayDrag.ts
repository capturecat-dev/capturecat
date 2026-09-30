/**
 * Camera bubble / subtitle pill / watermark drags — the web twin of
 * PreviewInteractionView's `.camera`, `.subtitle` and `.watermark` modes
 * (mouseDown hit order, mouseDragged fraction math, mouseUp magnetism).
 *
 * The hit rects are NOT derived here: the engine reports the rects its passes
 * drew (engine/stageHits.ts, FrameInfo.hits), each in the space it was drawn
 * in, with the free-placement span (`usable`) of the layout function that
 * placed it. The Mac divides the pointer delta by that span:
 *
 *   camera     usable = W − 24·cameraFit − rect.w   (ReactiveCameraLayout, padding 12·fit)
 *   watermark  usable = W − 40 − rect.w             (edgePad 20)
 *   subtitle   usable = W − 40 − rect.w             (edgePad 20, the pill)
 *
 * — here in engine px, which is the same ratio (pointer delta and span are
 * both scaled by canvasScale). Pure: no DOM, no store.
 */
import { fraction as cornerFraction } from "../../core/math/reactiveCameraLayout";
import { CameraPosition, SubtitlePosition, type ProjectSettings } from "../../core/model";
import type { Size } from "../../engine/layout";
import type { StageHitKind, StageHitRect, StageHits } from "../../engine/stageHits";
import { insetRect, rectContains } from "./stageGeometry";
import type { Pt } from "./stageMapping";

export type OverlayKind = StageHitKind;

/** Mouse-down order — watermark > camera > subtitle (the compositor's z-order). */
export const OVERLAY_ORDER: readonly OverlayKind[] = ["watermark", "camera", "subtitle"];

/** Hit slop in points (`insetBy(dx: -4)` / none / `insetBy(dx: -6)`). */
export const OVERLAY_HIT_OUTSET: Readonly<Record<OverlayKind, number>> = { watermark: 4, camera: 0, subtitle: 6 };

/** Camera corner magnetism (mouseUp `.camera`). */
export const CAMERA_CORNER_MAGNET = 0.06;
/** Watermark edge magnetism (mouseUp `.watermark`). */
export const WATERMARK_EDGE_MAGNET = 0.04;
/** Subtitle anchor magnetism (mouseUp `.subtitle`). */
export const SUBTITLE_ANCHOR_MAGNET = 0.06;

export const OVERLAY_LABEL: Readonly<Record<OverlayKind, string>> = {
  camera: "Move Camera",
  subtitle: "Move Subtitles",
  watermark: "Move Watermark",
};

export interface OverlayHit {
  kind: OverlayKind;
  hit: StageHitRect;
}

/**
 * The topmost overlay under the pointer. `canvasPoint` is the pointer in
 * engine canvas px; `cardPoint` the same pointer through the inverse camera
 * (card-space hits: subtitles, the camera-layout tile). `u` = px per point.
 */
export function overlayHitTest(hits: StageHits | undefined, canvasPoint: Pt, cardPoint: Pt, u: number): OverlayHit | null {
  if (!hits) return null;
  for (const kind of OVERLAY_ORDER) {
    const hit = hits[kind];
    if (!hit) continue;
    const slop = OVERLAY_HIT_OUTSET[kind] * u;
    const p = hit.space === "canvas" ? canvasPoint : cardPoint;
    if (rectContains(insetRect(hit.rect, -slop, -slop), p)) return { kind, hit };
  }
  return null;
}

/** The fraction a drag starts from (mouseDown: custom, else the enum's). */
export function overlayInitialFraction(kind: OverlayKind, s: ProjectSettings): Pt {
  switch (kind) {
    case "camera":
      return s.cameraCustomX != null && s.cameraCustomY != null ? { x: s.cameraCustomX, y: s.cameraCustomY } : cornerFraction(s.cameraPosition);
    case "watermark":
      return { x: s.watermarkX, y: s.watermarkY };
    case "subtitle":
      if (s.subtitleCustomX != null && s.subtitleCustomY != null) return { x: s.subtitleCustomX, y: s.subtitleCustomY };
      return subtitleAnchorFraction(s.subtitlePosition);
  }
}

function subtitleAnchorFraction(p: SubtitlePosition): Pt {
  switch (p) {
    case SubtitlePosition.top:
      return { x: 0.5, y: 0 };
    case SubtitlePosition.center:
      return { x: 0.5, y: 0.5 };
    default:
      return { x: 0.5, y: 1 };
  }
}

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));

/**
 * mouseDragged: the new fraction for a pointer delta (px, in the hit's
 * space) over the hit's usable span. Null = no write (`guard usableW > 0 ||
 * usableH > 0`).
 */
export function overlayDragFraction(kind: OverlayKind, initial: Pt, delta: Pt, usable: Size): Pt | null {
  const uw = usable.width;
  const uh = usable.height;
  if (!(uw > 0 || uh > 0)) return null;
  let dx: number;
  let dy: number;
  if (kind === "camera") {
    dx = delta.x / Math.max(1, uw);
    dy = delta.y / Math.max(1, uh);
  } else {
    dx = uw > 0 ? delta.x / uw : 0;
    dy = uh > 0 ? delta.y / uh : 0;
  }
  return { x: clamp01(initial.x + dx), y: clamp01(initial.y + dy) };
}

/** The settings a drag writes (custom fraction fields). */
export function overlayDragPatch(kind: OverlayKind, f: Pt): Partial<ProjectSettings> {
  switch (kind) {
    case "camera":
      return { cameraCustomX: f.x, cameraCustomY: f.y };
    case "watermark":
      return { watermarkX: f.x, watermarkY: f.y };
    case "subtitle":
      return { subtitleCustomX: f.x, subtitleCustomY: f.y };
  }
}

/**
 * mouseUp magnetism → the settings patch (undefined value = remove the key,
 * i.e. back to the enum), or null when nothing snaps.
 */
export function overlayReleasePatch(kind: OverlayKind, s: ProjectSettings): Partial<ProjectSettings> | null {
  switch (kind) {
    case "camera": {
      // Corner magnetism collapses back to the clean enum (allCases order).
      const x = s.cameraCustomX;
      const y = s.cameraCustomY;
      if (x == null || y == null) return null;
      for (const corner of [CameraPosition.topLeft, CameraPosition.topRight, CameraPosition.bottomLeft, CameraPosition.bottomRight]) {
        const f = cornerFraction(corner);
        if (Math.abs(f.x - x) < CAMERA_CORNER_MAGNET && Math.abs(f.y - y) < CAMERA_CORNER_MAGNET) {
          return { cameraPosition: corner, cameraCustomX: undefined, cameraCustomY: undefined };
        }
      }
      return null;
    }
    case "watermark": {
      let x = s.watermarkX;
      let y = s.watermarkY;
      if (Math.abs(x) < WATERMARK_EDGE_MAGNET) x = 0;
      if (Math.abs(x - 1) < WATERMARK_EDGE_MAGNET) x = 1;
      if (Math.abs(y) < WATERMARK_EDGE_MAGNET) y = 0;
      if (Math.abs(y - 1) < WATERMARK_EDGE_MAGNET) y = 1;
      return x !== s.watermarkX || y !== s.watermarkY ? { watermarkX: x, watermarkY: y } : null;
    }
    case "subtitle": {
      const x = s.subtitleCustomX;
      const y = s.subtitleCustomY;
      if (x == null || y == null || !(Math.abs(x - 0.5) < SUBTITLE_ANCHOR_MAGNET)) return null;
      const anchors: [SubtitlePosition, number][] = [
        [SubtitlePosition.top, 0],
        [SubtitlePosition.center, 0.5],
        [SubtitlePosition.bottom, 1],
      ];
      for (const [anchor, fy] of anchors) {
        if (Math.abs(y - fy) < SUBTITLE_ANCHOR_MAGNET) {
          return { subtitlePosition: anchor, subtitleCustomX: undefined, subtitleCustomY: undefined };
        }
      }
      return null;
    }
  }
}

/** Applies a settings patch to a draft (undefined = delete the key: `encodeIfPresent` omits it). */
export function applySettingsPatch(settings: ProjectSettings, patch: Partial<ProjectSettings>): void {
  const s = settings as unknown as Record<string, unknown>;
  for (const [key, value] of Object.entries(patch)) {
    if (value === undefined) delete s[key];
    else s[key] = value;
  }
}
