/**
 * Port of Models/CursorEvent.swift `CursorOverlayLayout` — where the cursor
 * sprite lands, shared by the preview compositor and the exporter:
 * `make(cursorPosition:coordinateSize:videoRect:cursorSize:hotSpot:cursorScale:)`,
 * `resolveCoordinateSize(recordedSize:fallbackSourceSize:)`,
 * `viewRect(from:canvasHeight:)`, `imageSpaceRect(in:)`, `center`, and the
 * sprite shadow constants.
 *
 * Spaces: `make` works in whatever space `videoRect` is in; both renderers pass
 * a Y-DOWN view rect (the exporter converts its Y-up layout rect with
 * `viewRect(from:canvasHeight:)` first). `imageSpaceRect` flips a Y-down rect
 * into CoreImage's Y-up space (and `viewRect` is the same flip the other way —
 * the formula is its own inverse).
 *
 * Shadow constants are PREVIEW-CANVAS points (CALayer shadowRadius/Offset);
 * the exporter multiplies every spatial value by `canvasScale` (see
 * ./exportCursor.ts for the exact GPU parameters).
 *
 * Locked to Swift by the `cursorOverlayLayout` golden vectors.
 */
import type { Point, Rect, Size } from "../model/types";
import { maxY, midX, midY, minX, minY, rectHeight, rectWidth } from "./geometry";
import { smax, smin } from "./swift";

/** CALayer-style shadow offset (Y-down view points): 1pt DOWN. */
export const shadowOffset: Size = Object.freeze({ width: 0, height: 1 });
/** CALayer shadowRadius, preview points (a CoreImage sigma is half of it). */
export const shadowBlurRadius = 2;
export const shadowOpacity = 0.3;

export interface CursorOverlayLayout {
  imageRect: Rect;
  /** Where the hotspot lands, in the same space as `imageRect`. */
  hotspotPoint: Point;
}

/** `layout.center` — (imageRect.midX, imageRect.midY). */
export function center(layout: CursorOverlayLayout): Point {
  return { x: midX(layout.imageRect), y: midY(layout.imageRect) };
}

/** `layout.imageSpaceRect(in: canvasHeight)`. */
export function imageSpaceRect(layout: CursorOverlayLayout, canvasHeight: number): Rect {
  const r = layout.imageRect;
  return { x: minX(r), y: canvasHeight - maxY(r), width: rectWidth(r), height: rectHeight(r) };
}

/** `CursorOverlayLayout.resolveCoordinateSize(recordedSize:fallbackSourceSize:)`:
 * the recorded size when valid, else half the video's natural size (the
 * Retina point-size guess), each side at least 1. */
export function resolveCoordinateSize(recordedSize: Size, fallbackSourceSize: Size): Size {
  if (recordedSize.width > 0 && recordedSize.height > 0) return recordedSize;
  return {
    width: smax(1, fallbackSourceSize.width / 2),
    height: smax(1, fallbackSourceSize.height / 2),
  };
}

/** `CursorOverlayLayout.viewRect(from:canvasHeight:)`. */
export function viewRect(imageRect: Rect, canvasHeight: number): Rect {
  return {
    x: minX(imageRect),
    y: canvasHeight - maxY(imageRect),
    width: rectWidth(imageRect),
    height: rectHeight(imageRect),
  };
}

/** `CursorOverlayLayout.make(...)` — null when any size is non-positive. */
export function make(
  cursorPosition: Point,
  coordinateSize: Size,
  videoRect: Rect,
  cursorSize: Size,
  hotSpot: Point,
  cursorScale: number,
): CursorOverlayLayout | null {
  const displayWidth = coordinateSize.width;
  const displayHeight = coordinateSize.height;
  if (
    !(
      displayWidth > 0 &&
      displayHeight > 0 &&
      rectWidth(videoRect) > 0 &&
      rectHeight(videoRect) > 0 &&
      cursorSize.width > 0 &&
      cursorSize.height > 0
    )
  ) {
    return null;
  }

  const normalizedX = smax(0, smin(1, cursorPosition.x / displayWidth));
  const normalizedY = smax(0, smin(1, cursorPosition.y / displayHeight));
  const cursorPointToViewScale = smin(
    rectWidth(videoRect) / smax(1, displayWidth),
    rectHeight(videoRect) / smax(1, displayHeight),
  );
  const renderedScale = cursorScale * cursorPointToViewScale;
  const cursorWidth = cursorSize.width * renderedScale;
  const cursorHeight = cursorSize.height * renderedScale;
  const hotspotX = minX(videoRect) + rectWidth(videoRect) * normalizedX;
  const hotspotY = minY(videoRect) + rectHeight(videoRect) * normalizedY;

  return {
    imageRect: {
      x: hotspotX - hotSpot.x * renderedScale,
      y: hotspotY - hotSpot.y * renderedScale,
      width: cursorWidth,
      height: cursorHeight,
    },
    hotspotPoint: { x: hotspotX, y: hotspotY },
  };
}
