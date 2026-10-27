/**
 * Port of Services/CameraCutoutMath.swift — the geometry of the two camera
 * looks (docs/camera-cutout.md §3) and the mask-track rules both renderers
 * share (§2): mask resolution, staleness.
 *
 *  - Cutout: the camera (× person mask) aspect-filled into the bubble rect B
 *    and clipped to B with square corners. Nothing else.
 *  - Pop-out card: a rounded gradient card C (B minus a headroom band at the
 *    top) behind the cut-out person, whose clip is B with only the two BOTTOM
 *    corners rounded — so the head rises above the card's top edge.
 *
 * Every rect is Y-DOWN (the web convention); the CoreImage exporter flips
 * with the frame height like every other camera rect.
 *
 * Locked by the golden-vector unit `cameraCutoutGeometry`.
 */
import type { CameraLook } from "../model/enums";
import type { Rect, Size } from "../model/types";
import { minX, minY, rectHeight, rectWidth } from "./geometry";
import { smax, smin } from "./swift";

/** Pop-out: the band above the card the head rises into, × B.height. */
export const popOutHeadroomFraction = 0.22;
/** Pop-out: card corner radius × min(C.width, C.height). */
export const popOutCornerFraction = 0.16;
/** Pop-out card fill: vertical sRGB gradient, top → bottom, opaque. */
export const popOutCardTop = { red: 1.0, green: 0.58, blue: 0.34 } as const;
export const popOutCardBottom = { red: 0.42, green: 0.33, blue: 0.96 } as const;

/** Staleness (§2): |sourceDuration − camera duration| ≤ this. */
export const maskDurationTolerance = 0.05;

export interface CameraCutoutGeometry {
  /** The camera image aspect-filled into B (the mask is scaled to the same rect). */
  personRect: Rect;
  /** The person clip: B. */
  clipRect: Rect;
  /** Radius of the clip's two BOTTOM corners (0 for the cutout). */
  clipBottomCornerRadius: number;
  /** Pop-out card (null for the cutout). */
  cardRect: Rect | null;
  /** Card corner radius, all four corners (0 for the cutout). */
  cardCornerRadius: number;
}

/**
 * `personRect(bubbleRect:cameraAspect:)` — the rect `compositeCamera` fills
 * the camera into: fillScale = max(B.width / a, B.height / 1), size
 * (a·fillScale, fillScale), centred on B (the exporter's own formula with
 * camExtent = (0, 0, a, 1), so the two can never disagree).
 */
export function personRect(bubbleRect: Rect, cameraAspect: number): Rect {
  const bw = rectWidth(bubbleRect);
  const bh = rectHeight(bubbleRect);
  const fillScale = smax(bw / cameraAspect, bh / 1);
  const w = cameraAspect * fillScale;
  const h = 1 * fillScale;
  return {
    x: minX(bubbleRect) - (w - bw) / 2,
    y: minY(bubbleRect) - (h - bh) / 2,
    width: w,
    height: h,
  };
}

/**
 * `geometry(look:bubbleRect:cameraAspect:yAxisIsUp:)` — Y-down by default;
 * `yAxisIsUp` (the exporter's CoreImage space) is the same geometry flipped
 * about B: the card keeps B's BOTTOM (minY in Y-up) and gives up its top.
 */
export function cutoutGeometry(look: CameraLook, bubbleRect: Rect, cameraAspect: number, yAxisIsUp = false): CameraCutoutGeometry {
  const person = personRect(bubbleRect, cameraAspect);
  if (look === "cutout") {
    return { personRect: person, clipRect: bubbleRect, clipBottomCornerRadius: 0, cardRect: null, cardCornerRadius: 0 };
  }
  const headroom = popOutHeadroomFraction * rectHeight(bubbleRect);
  const card: Rect = {
    x: minX(bubbleRect),
    y: yAxisIsUp ? minY(bubbleRect) : minY(bubbleRect) + headroom,
    width: rectWidth(bubbleRect),
    height: rectHeight(bubbleRect) - headroom,
  };
  const r = popOutCornerFraction * smin(card.width, card.height);
  return { personRect: person, clipRect: bubbleRect, clipBottomCornerRadius: r, cardRect: card, cardCornerRadius: r };
}

/**
 * `personClipMaskRect(_:yAxisIsUp:)` — the pop-out person clip's generator
 * rect: B extended UP by r, so once cropped back to B only the bottom two
 * corners are rounded. Y-down: (x, y − r, w, h + r); Y-up: (x, y, w, h + r).
 */
export function personClipMaskRect(g: CameraCutoutGeometry, yAxisIsUp: boolean): Rect {
  const b = g.clipRect;
  const r = g.clipBottomCornerRadius;
  return yAxisIsUp
    ? { x: minX(b), y: minY(b), width: rectWidth(b), height: rectHeight(b) + r }
    : { x: minX(b), y: minY(b) - r, width: rectWidth(b), height: rectHeight(b) + r };
}

/** `sizeFactor(rect:baseWidth:)` — B.width ÷ the base bubble's width (1 when unknown). */
export function sizeFactor(rect: Rect, baseWidth: number): number {
  return baseWidth > 0 ? rectWidth(rect) / baseWidth : 1;
}

/** `cardShadowRadius` — the bubble shadow's radius (export σ = this × canvasScale × sizeFactor). */
export const cardShadowRadius = 6;
/** `cardShadowExportAlpha` — the exporter bubble shadow's black alpha. */
export const cardShadowExportAlpha = 0.45;

/** The bubble's own share of a cross-fade: 1 − cutout − popOut, floored at 0. */
export function bubbleWeight(w: { cutout: number; popOut: number }): number {
  return smax(0, 1 - w.cutout - w.popOut);
}

/**
 * Pop-out card shadow in EXPORT terms (§3, "the bubble's shadow"): the
 * exporter's bubble shadow (`cameraShapeShadowImage`: black at alpha 0.45,
 * CIGaussianBlur σ = 6 × canvasScale at the base bubble) scaled with the
 * bubble like the baked assets are — σ = cardShadowRadius × canvasScale ×
 * sizeFactor (exportFrameCamera's `looks.shadowSigma`) — on the card's
 * rounded rect, no offset.
 */
export const popOutShadowAlpha = cardShadowExportAlpha;

/**
 * §2 staleness: a mask is usable only for the camera file it was made from —
 * same byte size, duration within 0.05 s. A missing or stale mask renders
 * every look as the plain bubble.
 */
export function maskIsFresh(
  header: { sourceByteSize: number; sourceDuration: number },
  camera: { byteSize: number | null; duration: number | null },
): boolean {
  if (camera.byteSize === null || camera.duration === null) return false;
  return header.sourceByteSize === camera.byteSize && Math.abs(header.sourceDuration - camera.duration) <= maskDurationTolerance;
}
