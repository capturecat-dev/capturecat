/**
 * TimelineSnap (Views/Editor/TimelineSnap.swift) + the ruler's time format
 * (TimelineCanvasView.formatRulerTime) and the block drag resolution
 * (TimelineCanvasView.resolvedTimes) — byte-for-byte ports.
 *
 * This is timeline INTERACTION math (where an edge lands under the pointer),
 * not preview/export math, so it lives with the timeline UI. If a render path
 * ever needs it, move it to editor/core and lock it with golden vectors.
 */

export function majorInterval(pixelsPerSecond: number): number {
  const candidates = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300];
  for (const interval of candidates) {
    if (pixelsPerSecond * interval >= 72) return interval;
  }
  return 300;
}

export function minorInterval(duration: number, trackWidth: number): number {
  if (!(duration > 0) || !(trackWidth > 0)) return 0;
  return Math.max(0.1, majorInterval(trackWidth / duration) / 5);
}

export function snapToGrid(time: number, duration: number, trackWidth: number): number {
  const interval = minorInterval(duration, trackWidth);
  if (!(interval > 0)) return time;
  return Math.round(time / interval) * interval;
}

export function snapThreshold(duration: number, trackWidth: number): number {
  if (!(duration > 0) || !(trackWidth > 0)) return 0;
  // 16px of grab — edges actually land on candidates during a normal drag.
  return Math.max((duration * 16) / trackWidth, minorInterval(duration, trackWidth) * 0.35);
}

export const clampTime = (time: number, duration: number) => Math.max(0, Math.min(duration, time));

export function nearestCandidate(
  time: number,
  candidates: readonly number[],
  duration: number,
  trackWidth: number,
): number | null {
  const threshold = snapThreshold(duration, trackWidth);
  if (!(threshold > 0)) return null;
  let best: number | null = null;
  let bestDistance = Infinity;
  for (const candidate of candidates) {
    const distance = Math.abs(candidate - time);
    if (distance <= threshold && distance < bestDistance) {
      bestDistance = distance;
      best = clampTime(candidate, duration);
    }
  }
  return best;
}

export function magneticSnap(time: number, candidates: readonly number[], duration: number, trackWidth: number): number {
  return nearestCandidate(time, candidates, duration, trackWidth) ?? snapToGrid(time, duration, trackWidth);
}

/** Which edge of a resolved block rests on a candidate (the yellow guide). */
export function snappedEdge(
  start: number,
  end: number,
  candidates: readonly number[],
  checkStart: boolean,
  checkEnd: boolean,
): number | null {
  const eps = 0.0005;
  if (checkStart && candidates.some((c) => Math.abs(c - start) < eps)) return start;
  if (checkEnd && candidates.some((c) => Math.abs(c - end) < eps)) return end;
  return null;
}

/** TimelineCanvasView.formatRulerTime — "00:01", "0:00.5", "1:02:03". */
export function formatRulerTime(seconds: number, showsFraction: boolean): string {
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad2 = (n: number) => String(n).padStart(2, "0");
  if (showsFraction) {
    const tenths = Math.round((seconds - Math.floor(seconds)) * 10);
    if (tenths > 0 && tenths < 10) return `${m}:${pad2(s)}.${tenths}`;
  }
  if (h > 0) return `${h}:${pad2(m)}:${pad2(s)}`;
  return `${pad2(m)}:${pad2(s)}`;
}

/** TimeInterval.formattedTimecode — the transport readout ("0:03", "1:02:03"). */
export function formatTimecode(seconds: number): string {
  const total = Math.floor(Math.max(0, seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad2 = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad2(m)}:${pad2(s)}` : `${m}:${pad2(s)}`;
}

/** scrubBubbleText — compact "0:02.4". */
export function formatScrub(seconds: number): string {
  const total = Math.max(0, seconds);
  const minutes = Math.floor(total / 60);
  const rest = total - minutes * 60;
  return `${minutes}:${rest.toFixed(1).padStart(4, "0")}`;
}

// ── Block drag resolution (TimelineCanvasView.resolvedTimes) ─────────────

export type DragMode = "move" | "resizeLeft" | "resizeRight";

export interface BlockDragInput {
  mode: DragMode;
  initialStart: number;
  initialEnd: number;
  /** Pointer translation in TRACK px. */
  translationX: number;
  trackWidth: number;
  duration: number;
  snapCandidates: readonly number[];
  otherSpans: ReadonlyArray<readonly [number, number]>;
  /** Legacy-overlap grace (EFFECTS lane only). */
  usesLegacyGrace: boolean;
  minDuration: number;
}

export function resolveBlockDrag(d: BlockDragInput): { start: number; end: number } {
  const delta = (d.translationX / Math.max(d.trackWidth, 1)) * d.duration;
  const total = d.duration;
  const blockers = d.usesLegacyGrace
    ? d.otherSpans.filter((o) => !(o[0] < d.initialEnd - 0.0001 && o[1] > d.initialStart + 0.0001))
    : d.otherSpans;

  const snapEdge = (time: number, excluded: number[]) =>
    nearestCandidate(
      time,
      d.snapCandidates.filter((c) => !excluded.some((e) => Math.abs(e - c) < 0.0001)),
      total,
      d.trackWidth,
    );

  if (d.mode === "move") {
    const duration = d.initialEnd - d.initialStart;
    const proposedStart = d.initialStart + delta;
    const proposedEnd = proposedStart + duration;
    const candidates = d.snapCandidates.filter(
      (c) => Math.abs(c - d.initialStart) >= 0.0001 && Math.abs(c - d.initialEnd) >= 0.0001,
    );
    const sStart = nearestCandidate(proposedStart, candidates, total, d.trackWidth);
    const sEnd = nearestCandidate(proposedEnd, candidates, total, d.trackWidth);
    let adjustedStart: number;
    if (sStart != null && sEnd != null) {
      adjustedStart = Math.abs(sStart - proposedStart) <= Math.abs(sEnd - proposedEnd) ? sStart : sEnd - duration;
    } else if (sStart != null) adjustedStart = sStart;
    else if (sEnd != null) adjustedStart = sEnd - duration;
    else adjustedStart = proposedStart;
    let newStart = Math.max(0, Math.min(total - duration, adjustedStart));
    for (const other of blockers) {
      if (newStart < other[1] && newStart + duration > other[0]) {
        const leftPos = other[0] - duration;
        const rightPos = other[1];
        newStart =
          Math.abs(adjustedStart - leftPos) <= Math.abs(adjustedStart - rightPos)
            ? Math.max(0, leftPos)
            : Math.min(total - duration, rightPos);
      }
    }
    return { start: newStart, end: newStart + duration };
  }

  if (d.mode === "resizeLeft") {
    const snapped = snapEdge(d.initialStart + delta, [d.initialStart, d.initialEnd]) ?? d.initialStart + delta;
    let newStart = Math.max(0, Math.min(d.initialEnd - d.minDuration, snapped));
    let block = -Infinity;
    for (const o of blockers) if (o[0] < d.initialEnd && o[1] > newStart) block = Math.max(block, o[1]);
    if (block > -Infinity) {
      newStart = d.usesLegacyGrace
        ? Math.min(Math.max(newStart, block), d.initialEnd - d.minDuration)
        : Math.max(newStart, block);
    }
    return { start: newStart, end: d.initialEnd };
  }

  const snapped = snapEdge(d.initialEnd + delta, [d.initialStart, d.initialEnd]) ?? d.initialEnd + delta;
  let newEnd = Math.max(d.initialStart + d.minDuration, Math.min(total, snapped));
  let block = Infinity;
  for (const o of blockers) if (o[1] > d.initialStart && o[0] < newEnd) block = Math.min(block, o[0]);
  if (block < Infinity) newEnd = Math.max(d.initialStart + d.minDuration, Math.min(newEnd, block));
  return { start: d.initialStart, end: newEnd };
}
