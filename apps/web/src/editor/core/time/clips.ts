/**
 * Clip / trim model — ports of Project.swift's
 * `effectiveTrimStart`, `effectiveTrimEnd`, `trimmedDuration`,
 * `effectiveVideoClipSegments` (incl. `stableLegacyClipID`),
 * `visibleVideoClip(containing:tolerance:)`, `hasVisibleVideo(at:)`,
 * and the exported-duration cap (`Project.exportedOutputDuration`, which
 * VideoExporter.export applies as "Cap export at the last visible clip").
 *
 * All times are SOURCE seconds except where a name says OUTPUT.
 * Locked to Swift by the `projectClips` and `exportedDuration` vectors.
 */
import type { Project, VideoClipSegment } from "../model/types";
import { fnv1a64, formatFixed, seqMax, smax, smin, uuidStringFromBytes } from "../math/swift";
import type { SpeedTimeMap } from "./speedTimeMap";

export type TrimProject = Pick<Project, "duration" | "trimStart" | "trimEnd">;
export type ClipProject = TrimProject & Pick<Project, "id" | "splitPoints" | "videoClipSegments">;

/** Trim start clamped to [0, duration]. */
export function effectiveTrimStart(p: TrimProject): number {
  return smax(0, smin(p.trimStart, p.duration));
}

/** Trim end clamped to valid range, or the full duration when unset (0). */
export function effectiveTrimEnd(p: TrimProject): number {
  const end = p.trimEnd > 0 ? p.trimEnd : p.duration;
  return smax(effectiveTrimStart(p), smin(end, p.duration));
}

/** The effective duration after trimming. */
export function trimmedDuration(p: TrimProject): number {
  return effectiveTrimEnd(p) - effectiveTrimStart(p);
}

/** Source ranges of the visible clips, sorted by start. Mirrors
 * `Project.effectiveVideoClipSegments` exactly, including the deterministic
 * legacy clip ids derived from split points. */
export function effectiveVideoClipSegments(p: ClipProject): VideoClipSegment[] {
  const trimStart = effectiveTrimStart(p);
  const trimEnd = effectiveTrimEnd(p);
  let base: VideoClipSegment[];
  if (p.videoClipSegments.length === 0) {
    const cuts = p.splitPoints.filter((t) => t > trimStart + 0.01 && t < trimEnd - 0.01);
    cuts.sort((a, b) => (a < b ? -1 : b < a ? 1 : 0));
    const boundaries = [trimStart, ...cuts, trimEnd];
    base = [];
    for (let index = 0; index < boundaries.length - 1; index++) {
      base.push({
        id: stableLegacyClipID(p.id, index, boundaries[index], boundaries[index + 1]),
        startTime: boundaries[index],
        endTime: boundaries[index + 1],
      });
    }
  } else {
    base = p.videoClipSegments;
  }

  const out: VideoClipSegment[] = [];
  for (const clip of base) {
    const start = smax(trimStart, smin(clip.startTime, p.duration));
    const end = smax(start, smin(clip.endTime, trimEnd));
    if (!(end > start + 0.01)) continue;
    out.push({ id: clip.id, startTime: start, endTime: end });
  }
  out.sort((a, b) => (a.startTime < b.startTime ? -1 : b.startTime < a.startTime ? 1 : 0));
  return out;
}

/** First visible clip whose [start−tol, end+tol] contains `sourceTime`. */
export function visibleVideoClip(
  p: ClipProject,
  sourceTime: number,
  tolerance = 1.0 / 30.0,
  clips: readonly VideoClipSegment[] = effectiveVideoClipSegments(p),
): VideoClipSegment | null {
  for (const clip of clips) {
    if (sourceTime >= clip.startTime - tolerance && sourceTime <= clip.endTime + tolerance) return clip;
  }
  return null;
}

export function hasVisibleVideo(
  p: ClipProject,
  sourceTime: number,
  tolerance = 1.0 / 30.0,
  clips?: readonly VideoClipSegment[],
): boolean {
  return visibleVideoClip(p, sourceTime, tolerance, clips) !== null;
}

/**
 * Exported length in OUTPUT seconds for `timeMap`: the map's output duration,
 * capped at the last visible clip's OUTPUT-time end (a moved/resized clip
 * shorter than the trim range must not pad the export with BG-only frames).
 * SHARED semantics with VideoExporter.export's frame count.
 */
export function exportedOutputDuration(p: ClipProject, timeMap: SpeedTimeMap): number {
  const ends = effectiveVideoClipSegments(p).map((c) => timeMap.outputTime(c.endTime));
  const lastVisibleOutput = seqMax(ends) ?? timeMap.outputDuration;
  return smax(0.0001, smin(timeMap.outputDuration, lastVisibleOutput));
}

/**
 * The exporter's SOURCE window: `trimEnd` falls back to the asset's real
 * duration when the project's effective trim end is 0 (VideoExporter.export:
 * `project.effectiveTrimEnd > 0 ? project.effectiveTrimEnd : fullDuration`).
 */
export function exportSourceWindow(p: TrimProject, assetDuration: number): { start: number; end: number } {
  const end = effectiveTrimEnd(p);
  return { start: effectiveTrimStart(p), end: end > 0 ? end : assetDuration };
}

/** Project.stableLegacyClipID — deterministic UUID for split-point clips. */
export function stableLegacyClipID(projectID: string, index: number, startTime: number, endTime: number): string {
  // Swift interpolates `projectID.uuidString`, which is always uppercase.
  const key = `${projectID.toUpperCase()}|${index}|${formatFixed(startTime, 6)}|${formatFixed(endTime, 6)}`;
  const first = fnv1a64(key);
  const second = fnv1a64(`clip|${key}`);
  const bytes = new Uint8Array(16);
  for (let offset = 0; offset < 8; offset++) {
    const shift = BigInt((7 - offset) * 8);
    bytes[offset] = Number((first >> shift) & 0xffn);
    bytes[offset + 8] = Number((second >> shift) & 0xffn);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return uuidStringFromBytes(bytes);
}
