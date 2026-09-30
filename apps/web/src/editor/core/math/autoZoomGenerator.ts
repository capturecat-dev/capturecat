/**
 * Port of Services/AutoZoomGenerator.swift (`enum AutoZoomGenerator`) — ALL of
 * it: the Tuning table, extractInteractions, typingBursts, dwells, Cluster
 * (startTime / endTime / centroid / spread), cluster, qualifies, depth,
 * clampFocal, frame, applyRhythm, clip and generateZoomRegions.
 *
 * Turns recorded interaction data (60 Hz cursor samples with pressed state +
 * keystroke times) into a calm camera plan of auto `ZoomRegion`s:
 * interactions → clusters → qualify → frame → rhythm (merge / pan / cooldown)
 * → clip around the user's manual blocks. `core/edit/autoZoom.ts` is the
 * applier (AutoZoomApplier) that feeds it from a project.
 *
 * Locked to the REAL Swift by `core/vectors/autoZoom.test.ts`: golden cases
 * recorded from the Mac binary's MCP `auto_zoom` tool (which runs
 * AutoZoomApplier → this generator) over synthetic cursor/keystroke data.
 *
 * Swift semantics kept on purpose:
 * - every `min`/`max` is `smin`/`smax` (Swift comparison semantics);
 * - `hypot` is Darwin libm (`chypot`), not Math.hypot;
 * - `sorted { $0.startTime < $1.startTime }` is STABLE (Swift's sort is a
 *   stable merge sort; so is Array.prototype.sort — `stableSortByStart`);
 * - `Sequence.max()` scans first-wins (`seqMax`);
 * - ZoomRegion / Interaction / Cluster are Swift VALUE types: every place the
 *   Swift copies a struct (`var last = result[...]`, `for var region in`,
 *   `var piece = region`) copies here too, so no aliasing leaks across steps;
 * - `ZoomRegion.duration` is `endTime - startTime` (recomputed on every read).
 *
 * Coordinates: interaction points and focal points are 0…1 of the frame,
 * Y-DOWN; cursor samples are recording points (screenSize space).
 */
import type { CursorEvent, KeystrokeEvent, Point, Size, ZoomRegion } from "../model/types";
import { newUUID } from "../model/defaults";
import { discreteClicks } from "./clickRippleOverlay";
import { chypot } from "./libm";
import { seqMax, smax, smin } from "./swift";

/** `AutoZoomGenerator.Tuning` — one table, shared by generator + harness. */
export const AutoZoomTuning = {
  /** Zoom starts this long BEFORE the first interaction of a cluster. */
  leadIn: 0.35,
  /** Calm release: hold after the last interaction before zooming out. */
  release: 0.9,
  /** A zoom shorter than this reads as a glitch — extend, then merge. */
  minDuration: 1.8,
  /** Separate zooms need this much air between them (else merge or pan). */
  cooldown: 1.0,
  /** Interactions within this many seconds chain into one cluster. */
  clusterTimeGap: 2.0,
  /** ...and within this fraction of the screen diagonal of the centroid. */
  clusterRadius: 0.22,
  /** Focal distance (fraction of frame, max axis) below which two close
   * clusters MERGE into one region. */
  mergeFocalDistance: 0.1,
  /** ...and below which they become a contiguous PAN instead of a
   * zoom-out/zoom-in (the ~25%-of-frame hysteresis). */
  panFocalDistance: 0.25,
  /** Gap below which panning is preferred over a full out/in cycle. */
  panMaxGap: 2.5,
  /** Dwell: cursor stays inside this fraction of the diagonal… */
  dwellRadius: 0.025,
  /** …for at least this long to count as deliberate hovering… */
  dwellMinDuration: 0.8,
  /** …but longer than this is a parked cursor (idle), not attention. */
  dwellMaxDuration: 4.0,
  /** Typing burst: ≥ this many keys with < `typingMaxKeyGap` between. */
  typingMinKeys: 3,
  typingMaxKeyGap: 1.5,
  /** Depth bounds and spread thresholds (fraction of screen diagonal). */
  minZoom: 1.3,
  maxZoom: 2.75,
  tightSpread: 0.06,
  broadSpread: 0.18,
  /** Focal keeps this margin inside the visible-viewport clamp. */
  edgeMargin: 0.02,
  /** A region clipped against manual blocks below this length is dropped. */
  minClippedDuration: 1.2,
} as const;

const T = AutoZoomTuning;

// MARK: - Interactions

/** `AutoZoomGenerator.InteractionKind`. */
export type InteractionKind = "click" | "typing" | "dwell";

/** `AutoZoomGenerator.Interaction`. */
export interface Interaction {
  startTime: number;
  endTime: number;
  /** Normalized 0…1 screen position (Y-down). */
  point: Point;
  kind: InteractionKind;
}

/** `ZoomRegion.duration` — `endTime - startTime`. */
export function zoomRegionDuration(r: Pick<ZoomRegion, "startTime" | "endTime">): number {
  return r.endTime - r.startTime;
}

/** Swift `sorted { $0.startTime < $1.startTime }` / in-place `sort` — STABLE. */
export function stableSortByStart<R extends { startTime: number }>(items: readonly R[]): R[] {
  return items
    .map((item, index) => ({ item, index }))
    .sort((a, b) => {
      if (a.item.startTime < b.item.startTime) return -1;
      if (b.item.startTime < a.item.startTime) return 1;
      return a.index - b.index;
    })
    .map((e) => e.item);
}

/** Value-type copy of a ZoomRegion (Swift struct assignment). */
function copyRegion(r: ZoomRegion): ZoomRegion {
  return { ...r, focalPoint: { x: r.focalPoint.x, y: r.focalPoint.y } };
}

/** `ZoomRegion(startTime:endTime:zoomLevel:focalPoint:isAuto: true)` — every
 * other optional nil (omitted on encode), a fresh UUID. */
function autoRegion(
  startTime: number,
  endTime: number,
  zoomLevel: number,
  focalPoint: Point,
  makeId: () => string,
): ZoomRegion {
  return { id: makeId(), startTime, endTime, zoomLevel, focalPoint: { x: focalPoint.x, y: focalPoint.y }, isAuto: true };
}

/**
 * `AutoZoomGenerator.generateZoomRegions(from:videoDuration:screenSize:zoomLevel:keystrokes:existingRegions:)`.
 * `existingRegions` are the user's MANUAL blocks (any effect spans that must
 * stay untouched) — generated regions are clipped out of them. `makeId` mints
 * each new region's UUID (Swift's `UUID()` default argument).
 */
export function generateZoomRegions(
  cursorEvents: readonly CursorEvent[],
  videoDuration: number,
  screenSize: Size,
  zoomLevel = 2.0,
  keystrokes: readonly KeystrokeEvent[] = [],
  existingRegions: readonly ZoomRegion[] = [],
  makeId: () => string = newUUID,
): ZoomRegion[] {
  if (!(videoDuration > 0 && screenSize.width > 0 && screenSize.height > 0)) return [];

  const interactions = extractInteractions(cursorEvents, keystrokes, screenSize);
  if (interactions.length === 0) return [];

  const clusters = cluster(interactions);
  const qualified = clusters.filter(qualifies);
  if (qualified.length === 0) return [];

  let regions = qualified.map((c) => frame(c, zoomLevel, videoDuration, makeId));
  regions = applyRhythm(regions, videoDuration);
  regions = clip(regions, existingRegions, makeId);
  return regions;
}

/** `AutoZoomGenerator.extractInteractions` — clicks + typing bursts + dwells,
 * normalized and (stably) time-sorted. */
export function extractInteractions(
  cursorEvents: readonly CursorEvent[],
  keystrokes: readonly KeystrokeEvent[],
  screenSize: Size,
): Interaction[] {
  const interactions: Interaction[] = [];

  const normalize = (x: number, y: number): Point => ({
    x: smax(0, smin(1, x / screenSize.width)),
    y: smax(0, smin(1, y / screenSize.height)),
  });

  // Discrete clicks — same extraction as ripples/click sounds, so a
  // drag-select never counts as a click to zoom at.
  const clicks = discreteClicks(cursorEvents, screenSize);
  for (const click of clicks) {
    interactions.push({
      startTime: click.timestamp,
      endTime: click.timestamp,
      point: normalize(click.x, click.y),
      kind: "click",
    });
  }

  // Typing bursts, anchored at the click that focused the field; fallback:
  // cursor position at the burst start (or the first sample).
  for (const burst of typingBursts(keystrokes)) {
    let anchor: Point;
    const click = lastWhere(clicks, (c) => c.timestamp <= burst.start);
    if (click !== undefined) {
      anchor = normalize(click.x, click.y);
    } else {
      const sample = lastWhere(cursorEvents, (e) => e.timestamp <= burst.start) ?? cursorEvents[0];
      if (sample === undefined) continue;
      anchor = normalize(sample.x, sample.y);
    }
    interactions.push({ startTime: burst.start, endTime: burst.end, point: anchor, kind: "typing" });
  }

  // Dwells: the cursor arrives somewhere and hovers.
  interactions.push(...dwells(cursorEvents, screenSize));

  return stableSortByStart(interactions);
}

/** Swift `Array.last(where:)`. */
function lastWhere<E>(items: readonly E[], predicate: (e: E) => boolean): E | undefined {
  for (let i = items.length - 1; i >= 0; i--) if (predicate(items[i])) return items[i];
  return undefined;
}

/** `AutoZoomGenerator.typingBursts(in:)` — bursts of ≥ typingMinKeys real
 * keys (scroll + modifier excluded) with gaps ≤ typingMaxKeyGap. */
export function typingBursts(keystrokes: readonly KeystrokeEvent[]): { start: number; end: number }[] {
  const keys = stableSortByStartKey(keystrokes.filter((k) => k.category !== "scroll" && k.category !== "modifier"));
  const bursts: { start: number; end: number }[] = [];
  let start: number | null = null;
  let last = 0;
  let count = 0;
  for (const key of keys) {
    if (start === null || key.timestamp - last > T.typingMaxKeyGap) {
      if (start !== null && count >= T.typingMinKeys) bursts.push({ start, end: last });
      start = key.timestamp;
      count = 0;
    }
    last = key.timestamp;
    count += 1;
  }
  if (start !== null && count >= T.typingMinKeys) bursts.push({ start, end: last });
  return bursts;
}

/** `keys.sorted { $0.timestamp < $1.timestamp }` (stable). */
function stableSortByStartKey(keys: readonly KeystrokeEvent[]): KeystrokeEvent[] {
  return keys
    .map((item, index) => ({ item, index }))
    .sort((a, b) => {
      if (a.item.timestamp < b.item.timestamp) return -1;
      if (b.item.timestamp < a.item.timestamp) return 1;
      return a.index - b.index;
    })
    .map((e) => e.item);
}

/** `AutoZoomGenerator.dwells(in:screenSize:)` — hover segments: the cursor
 * stays within dwellRadius·diagonal of the segment anchor for
 * dwellMinDuration…dwellMaxDuration after having MOVED there. */
export function dwells(events: readonly CursorEvent[], screenSize: Size): Interaction[] {
  if (!(events.length > 1)) return [];
  const diagonal = chypot(screenSize.width, screenSize.height);
  const radius = diagonal * T.dwellRadius;

  const result: Interaction[] = [];
  let anchorIndex = 0;
  let hasMovedSinceStart = false;

  const close = (endIndex: number) => {
    const anchor = events[anchorIndex];
    const end = events[endIndex];
    const duration = end.timestamp - anchor.timestamp;
    // Only a dwell if the cursor travelled here first — the very first
    // segment of a recording (cursor untouched from t=0) is idle.
    if (hasMovedSinceStart && duration >= T.dwellMinDuration && duration <= T.dwellMaxDuration) {
      let sumX = 0;
      let sumY = 0;
      for (let i = anchorIndex; i <= endIndex; i++) {
        sumX += events[i].x;
        sumY += events[i].y;
      }
      const n = endIndex - anchorIndex + 1;
      result.push({
        startTime: anchor.timestamp,
        endTime: end.timestamp,
        point: {
          x: smax(0, smin(1, sumX / n / screenSize.width)),
          y: smax(0, smin(1, sumY / n / screenSize.height)),
        },
        kind: "dwell",
      });
    }
  };

  for (let i = 1; i < events.length; i++) {
    const anchor = events[anchorIndex];
    const distance = chypot(events[i].x - anchor.x, events[i].y - anchor.y);
    if (distance > radius) {
      close(i - 1);
      anchorIndex = i;
      hasMovedSinceStart = true;
    }
  }
  close(events.length - 1);
  return result;
}

// MARK: - Clustering

/** `AutoZoomGenerator.Cluster`. */
export interface Cluster {
  interactions: Interaction[];
}

/** `Cluster.startTime` — `interactions.first?.startTime ?? 0`. */
export function clusterStartTime(c: Cluster): number {
  return c.interactions.length > 0 ? c.interactions[0].startTime : 0;
}

/** `Cluster.endTime` — `interactions.map(\.endTime).max() ?? 0`. */
export function clusterEndTime(c: Cluster): number {
  return seqMax(c.interactions.map((i) => i.endTime)) ?? 0;
}

/** `Cluster.centroid` — `(0.5, 0.5)` when empty. */
export function clusterCentroid(c: Cluster): Point {
  if (c.interactions.length === 0) return { x: 0.5, y: 0.5 };
  const n = c.interactions.length;
  let sx = 0;
  let sy = 0;
  for (const i of c.interactions) sx = sx + i.point.x;
  for (const i of c.interactions) sy = sy + i.point.y;
  return { x: sx / n, y: sy / n };
}

/** `Cluster.spread` — max pairwise distance between interaction points. */
export function clusterSpread(c: Cluster): number {
  let maxDistance = 0.0;
  for (const a of c.interactions) {
    for (const b of c.interactions) {
      maxDistance = smax(maxDistance, chypot(a.point.x - b.point.x, a.point.y - b.point.y));
    }
  }
  return maxDistance;
}

/** `AutoZoomGenerator.cluster(_:)` — chain interactions into clusters (time
 * gap AND distance-to-centroid), then fuse clusters whose gap is below the
 * cooldown. */
export function cluster(interactions: readonly Interaction[]): Cluster[] {
  if (interactions.length === 0) return [];
  const clusters: Cluster[] = [{ interactions: [interactions[0]] }];

  for (let k = 1; k < interactions.length; k++) {
    const interaction = interactions[k];
    const current = clusters[clusters.length - 1];
    const timeGap = interaction.startTime - clusterEndTime(current);
    const centroid = clusterCentroid(current);
    const distance = chypot(interaction.point.x - centroid.x, interaction.point.y - centroid.y);
    if (timeGap <= T.clusterTimeGap && distance <= T.clusterRadius) {
      // `current` is owned by `clusters` (built here), so appending in place
      // is the Swift copy-append-writeback without the O(n²) copies.
      current.interactions.push(interaction);
    } else {
      clusters.push({ interactions: [interaction] });
    }
  }

  // Fuse clusters closer in time than the cooldown — never two separate
  // zoom decisions within a second of each other.
  const fused: Cluster[] = [];
  for (const c of clusters) {
    const last = fused.length > 0 ? fused[fused.length - 1] : undefined;
    if (last !== undefined && clusterStartTime(c) - clusterEndTime(last) < T.cooldown) {
      fused[fused.length - 1] = { interactions: [...last.interactions, ...c.interactions] };
    } else {
      fused.push(c);
    }
  }
  return fused;
}

/** `AutoZoomGenerator.qualifies(_:)` — a lone transient click never zooms: a
 * cluster needs 2+ interactions, a typing burst, or a dwell. */
export function qualifies(c: Cluster): boolean {
  return c.interactions.length >= 2 || c.interactions.some((i) => i.kind === "typing" || i.kind === "dwell");
}

// MARK: - Framing

/** `AutoZoomGenerator.depth(spread:hasTyping:baseZoom:)`. */
export function depth(spread: number, hasTyping: boolean, baseZoom: number): number {
  let level: number;
  if (spread < T.tightSpread) {
    level = baseZoom + (hasTyping ? 0.5 : 0.4);
  } else if (spread > T.broadSpread) {
    level = baseZoom - 0.5;
  } else {
    level = baseZoom;
  }
  return smax(T.minZoom, smin(T.maxZoom, level));
}

/** `AutoZoomGenerator.clampFocal(_:zoomLevel:)` — focal kept in
 * [0.5/z + margin, 1 − 0.5/z − margin] on each axis; centre when empty. */
export function clampFocal(focal: Point, zoomLevel: number): Point {
  const halfVisible = 0.5 / smax(1.0, zoomLevel);
  const lower = halfVisible + T.edgeMargin;
  const upper = 1 - halfVisible - T.edgeMargin;
  if (!(lower < upper)) return { x: 0.5, y: 0.5 };
  return { x: smax(lower, smin(upper, focal.x)), y: smax(lower, smin(upper, focal.y)) };
}

/** `AutoZoomGenerator.frame(cluster:baseZoom:videoDuration:)`. */
export function frame(
  c: Cluster,
  baseZoom: number,
  videoDuration: number,
  makeId: () => string = newUUID,
): ZoomRegion {
  const hasTyping = c.interactions.some((i) => i.kind === "typing");
  const zoomLevel = depth(clusterSpread(c), hasTyping, baseZoom);
  const focal = clampFocal(clusterCentroid(c), zoomLevel);

  let start = smax(0, clusterStartTime(c) - T.leadIn);
  let end = smin(videoDuration, clusterEndTime(c) + T.release);
  if (end - start < T.minDuration) {
    end = smin(videoDuration, start + T.minDuration);
    if (end - start < T.minDuration) {
      start = smax(0, end - T.minDuration);
    }
  }
  return autoRegion(start, end, zoomLevel, focal, makeId);
}

// MARK: - Rhythm (anti ping-pong + pan hysteresis)

/** `AutoZoomGenerator.applyRhythm(_:videoDuration:)` — time-sorted regions →
 * merged / panned / spaced-out plan. */
export function applyRhythm(regions: readonly ZoomRegion[], videoDuration: number): ZoomRegion[] {
  if (regions.length === 0) return [];
  const sorted = stableSortByStart(regions);
  const result: ZoomRegion[] = [copyRegion(sorted[0])];

  for (let k = 1; k < sorted.length; k++) {
    const region = copyRegion(sorted[k]);
    const last = copyRegion(result[result.length - 1]);
    const gap = region.startTime - last.endTime;
    const focalDistance = smax(
      Math.abs(region.focalPoint.x - last.focalPoint.x),
      Math.abs(region.focalPoint.y - last.focalPoint.y),
    );

    if (gap < T.cooldown || (gap < T.panMaxGap && focalDistance <= T.panFocalDistance)) {
      if (focalDistance <= T.mergeFocalDistance) {
        // Same subject — one region, duration-weighted focal.
        const lastDuration = zoomRegionDuration(last);
        const regionDuration = zoomRegionDuration(region);
        const total = lastDuration + regionDuration;
        last.focalPoint = {
          x: (last.focalPoint.x * lastDuration + region.focalPoint.x * regionDuration) / total,
          y: (last.focalPoint.y * lastDuration + region.focalPoint.y * regionDuration) / total,
        };
        last.endTime = smax(last.endTime, region.endTime);
        last.zoomLevel = smax(last.zoomLevel, region.zoomLevel);
        result[result.length - 1] = last;
      } else {
        // Nearby subject — PAN: contiguous blocks, matched depth so the move
        // is lateral, not a pump.
        region.startTime = last.endTime;
        region.zoomLevel = last.zoomLevel;
        region.focalPoint = clampFocal(region.focalPoint, region.zoomLevel);
        if (zoomRegionDuration(region) < T.minDuration) {
          region.endTime = smin(videoDuration, region.startTime + T.minDuration);
        }
        if (zoomRegionDuration(region) > 0.1) result.push(region);
      }
    } else {
      result.push(region);
    }
  }
  return result;
}

// MARK: - Respecting manual regions

/** `AutoZoomGenerator.clip(_:around:)` — clips generated regions out of the
 * spans held by the user's manual blocks (with cooldown air on both sides);
 * fragments shorter than minClippedDuration are dropped. A region that
 * survives whole keeps its identity; a clipped piece is a NEW region. */
export function clip(
  regions: readonly ZoomRegion[],
  manual: readonly ZoomRegion[],
  makeId: () => string = newUUID,
): ZoomRegion[] {
  if (manual.length === 0) return regions.map(copyRegion);
  const result: ZoomRegion[] = [];
  for (const region of regions) {
    let spans: [number, number][] = [[region.startTime, region.endTime]];
    for (const block of manual) {
      const blockStart = block.startTime - T.cooldown;
      const blockEnd = block.endTime + T.cooldown;
      const next: [number, number][] = [];
      for (const [start, end] of spans) {
        if (end <= blockStart || start >= blockEnd) {
          next.push([start, end]);
        } else {
          if (start < blockStart) next.push([start, blockStart]);
          if (end > blockEnd) next.push([blockEnd, end]);
        }
      }
      spans = next;
    }
    for (const [start, end] of spans) {
      if (!(end - start >= T.minClippedDuration)) continue;
      let piece = copyRegion(region);
      if (!(start === region.startTime && end === region.endTime)) {
        piece = autoRegion(start, end, region.zoomLevel, region.focalPoint, makeId);
      }
      result.push(piece);
    }
  }
  return result;
}
