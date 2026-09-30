/**
 * Timeline filmstrip — the port of the Mac's thumbnail strip:
 *
 *   TimelineThumbnailer.generate (Services/TimelineThumbnailer.swift), called by
 *   TimelineViewController.loadThumbnails with `targetCount: 40` over
 *   `project.duration` (the whole recording, in source time):
 *     stride = duration / 40, request i at CMTime(seconds: (i + 0.5)·stride,
 *     preferredTimescale: 600) (truncated), AVAssetImageGenerator with
 *     maximumSize (0, 96) px, ±0.5 s tolerance (keyframe snapping allowed),
 *     each thumbnail stamped with its REQUESTED time, sorted by time.
 *   TimelineThumbnailer.thumbnail(at:in:) — nearest by |time − t|, first wins.
 *   VideoTrackRowNative.drawVideoFilmstrip — tiles from the clip rect's left
 *     edge; each tile probes the source time under its centre (a linear map of
 *     the clip's SOURCE span across its drawn rect, so trimmed, split, sped-up
 *     and live-dragged clips all tile like the Mac), crops device-source
 *     segments to their content rect, and advances by height × aspect. Zooming
 *     the timeline widens the rect, so more tiles re-probe nearer thumbnails.
 */
import type { ProjectSourceSegment } from "../model/types";
import { smax } from "../math/swift";

/** loadThumbnails — `targetCount: 40`. */
export const FILMSTRIP_TARGET_COUNT = 40;
/** `generator.maximumSize = CGSize(width: 0, height: 96)` px = 48 pt on the Mac's 2× displays. */
export const FILMSTRIP_THUMB_HEIGHT_POINTS = 48;
/** `requestedTimeToleranceBefore/After = 0.5 s`. */
export const FILMSTRIP_TIME_TOLERANCE = 0.5;

/** Thumbnail pixel height for a display: the Mac's 96 px at 2×, scaled with devicePixelRatio. */
export function filmstripPixelHeight(devicePixelRatio: number): number {
  const dpr = Number.isFinite(devicePixelRatio) && devicePixelRatio > 0 ? devicePixelRatio : 1;
  return Math.max(1, Math.ceil(FILMSTRIP_THUMB_HEIGHT_POINTS * dpr));
}

/**
 * The requested (= stamped) thumbnail times: CMTime(seconds: (i + 0.5)·stride,
 * preferredTimescale: 600).seconds — truncated to 1/600 s. [] when there is
 * nothing to generate (`guard duration > 0, targetCount > 0`).
 */
export function filmstripRequestTimes(duration: number, targetCount = FILMSTRIP_TARGET_COUNT): number[] {
  if (!(duration > 0) || !(targetCount > 0)) return [];
  const stride = duration / targetCount;
  const out: number[] = [];
  for (let i = 0; i < targetCount; i++) out.push(Math.trunc((i + 0.5) * stride * 600) / 600);
  return out;
}

/**
 * Which decoded frame stands in for a requested time — the web's emulation of
 * AVAssetImageGenerator's "cheapest frame within tolerance": the sync frame
 * nearest the request when one lies within ±tolerance (a single-packet
 * decode), else the first frame at or after `t − tolerance` (decoding stops
 * as soon as the window is reached), else the frame on screen at `t`.
 *
 * `pts` are every frame's presentation times ascending; `keyPts` the sync
 * frames' ascending. Returns a presentation time from `pts` (NaN when empty).
 */
export function filmstripFrameTime(
  requested: number,
  pts: ArrayLike<number>,
  keyPts: ArrayLike<number>,
  tolerance = FILMSTRIP_TIME_TOLERANCE,
): number {
  if (pts.length === 0) return Number.NaN;
  const lo = requested - tolerance;
  const hi = requested + tolerance;
  let bestKey = Number.NaN;
  let bestDistance = Number.POSITIVE_INFINITY;
  for (let i = lowerBound(keyPts, lo); i < keyPts.length && keyPts[i] <= hi; i++) {
    const d = Math.abs(keyPts[i] - requested);
    if (d < bestDistance) {
      bestDistance = d;
      bestKey = keyPts[i];
    }
  }
  if (Number.isFinite(bestKey)) return bestKey;
  const first = lowerBound(pts, lo);
  if (first < pts.length && pts[first] <= hi) return pts[first];
  // A gap in the media around the request: the frame on screen at `requested`.
  return pts[Math.max(0, first - 1)];
}

/** First index with a[i] >= v. */
function lowerBound(a: ArrayLike<number>, v: number): number {
  let l = 0;
  let h = a.length;
  while (l < h) {
    const m = (l + h) >> 1;
    if (a[m] < v) l = m + 1;
    else h = m;
  }
  return l;
}

/** TimelineThumbnailer.thumbnail(at:in:) — nearest time, the FIRST of equals wins; −1 when empty. */
export function nearestThumbnailIndex(times: ArrayLike<number>, time: number): number {
  if (times.length === 0) return -1;
  let best = 0;
  let bestDistance = Math.abs(times[0] - time);
  for (let i = 1; i < times.length; i++) {
    const d = Math.abs(times[i] - time);
    if (d < bestDistance) {
      best = i;
      bestDistance = d;
    }
  }
  return best;
}

/** VideoTrackRowNative.videoDeviceContentRect(at:) — the first device segment covering `time`. */
export function deviceContentRectAt(
  segments: readonly Pick<ProjectSourceSegment, "startTime" | "duration" | "kind" | "contentX" | "contentY" | "contentWidth" | "contentHeight">[] | undefined,
  time: number,
): { x: number; y: number; width: number; height: number } | null {
  if (!segments) return null;
  const s = segments.find((seg) => seg.kind === "device" && time >= seg.startTime && time <= seg.startTime + seg.duration);
  return s ? { x: s.contentX, y: s.contentY, width: s.contentWidth, height: s.contentHeight } : null;
}

export interface FilmstripThumb {
  /** Requested source time the thumbnail is stamped with. */
  time: number;
  /** Pixel size of the decoded thumbnail. */
  width: number;
  height: number;
}

export interface FilmstripTile {
  /** Tile origin x and width (same units as the rect; y/height = the rect's). */
  x: number;
  width: number;
  /** Source time the tile probed. */
  time: number;
  /** Index into the thumbnails. */
  index: number;
  /** Pixel sub-rect of the thumbnail to draw (device-source crop), or null for the whole frame. */
  crop: { x: number; y: number; width: number; height: number } | null;
}

/**
 * `CGImage.cropping(to:)` of a normalised content rect: the pixel rect made
 * integral (floor origin, ceil far edge) and intersected with the image;
 * null when nothing is left.
 */
function cropRect(
  n: { x: number; y: number; width: number; height: number },
  w: number,
  h: number,
): { x: number; y: number; width: number; height: number } | null {
  const px = n.x * w;
  const py = n.y * h;
  const pw = n.width * w;
  const ph = n.height * h;
  if (!(pw > 0) || !(ph > 0)) return null;
  const x0 = Math.max(0, Math.floor(px));
  const y0 = Math.max(0, Math.floor(py));
  const x1 = Math.min(w, Math.ceil(px + pw));
  const y1 = Math.min(h, Math.ceil(py + ph));
  if (!(x1 > x0) || !(y1 > y0)) return null;
  return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
}

/**
 * VideoTrackRowNative.drawVideoFilmstrip's tiling for one clip rect. `stopX`
 * ends the walk early (tiles past the visible range are never drawn — the
 * layout before it is unchanged, since every tile depends only on the ones
 * to its left).
 */
export function layoutFilmstrip(
  rect: { x: number; width: number; height: number },
  sourceStart: number,
  sourceEnd: number,
  thumbs: readonly FilmstripThumb[],
  sourceSegments?: Parameters<typeof deviceContentRectAt>[0],
  stopX = Number.POSITIVE_INFINITY,
): FilmstripTile[] {
  const out: FilmstripTile[] = [];
  const first = thumbs[0];
  if (!first || !(rect.height > 0) || !(rect.width > 0)) return out;
  const aspectOf = (t: FilmstripThumb) => (t.height > 0 ? t.width / t.height : 16 / 9);
  const baseAspect = aspectOf(first);
  const span = smax(0.0001, sourceEnd - sourceStart);
  const times = thumbs.map((t) => t.time);
  const maxX = Math.min(rect.x + rect.width, stopX);
  let x = rect.x;
  while (x < maxX) {
    const probeWidth = smax(12, rect.height * baseAspect);
    const fraction = (x - rect.x + probeWidth / 2) / rect.width;
    const time = sourceStart + fraction * span;
    const index = nearestThumbnailIndex(times, time);
    const thumb = thumbs[index];
    let aspect = aspectOf(thumb);
    let crop: FilmstripTile["crop"] = null;
    const normalized = deviceContentRectAt(sourceSegments, time);
    if (normalized) {
      crop = cropRect(normalized, thumb.width, thumb.height);
      if (crop) {
        const ph = normalized.height * thumb.height;
        aspect = ph > 0 ? (normalized.width * thumb.width) / ph : aspect;
      }
    }
    const tileWidth = smax(10, rect.height * aspect);
    out.push({ x, width: tileWidth, time, index, crop });
    x += tileWidth;
  }
  return out;
}
