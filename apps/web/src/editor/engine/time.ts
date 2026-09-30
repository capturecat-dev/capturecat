/**
 * OUTPUT ↔ SOURCE time for the engine — the exporter's own mapping:
 *
 *   SpeedTimeMap(trimStart, trimEnd-or-asset-duration, speedRegions)
 *   output duration capped at the last visible clip's output end
 *   a frame shows video only inside a visible clip (cut spans → background)
 *
 * All three come from `editor/core/time`, locked to Swift by the
 * speedTimeMap / projectClips / exportedDuration golden vectors — preview
 * and export share this one TimeMap. A project the core model cannot parse
 * falls back to the trim-only map (and the editor surfaces the parse error).
 */
import type { Project } from "../core/model";
import {
  effectiveVideoClipSegments,
  exportedOutputDuration,
  exportSourceWindow,
  hasVisibleVideo as coreHasVisibleVideo,
} from "../core/time/clips";
import { SpeedTimeMap } from "../core/time/speedTimeMap";
import type { RenderProject } from "./contract";

export interface TimeMap {
  /** Output (timeline/export) duration in seconds. */
  readonly outputDuration: number;
  /** Source (recording) seconds for an output time. */
  sourceTime(outputTime: number): number;
  /** Output seconds for a source time. */
  outputTime(sourceTime: number): number;
  /** Whether a video frame is visible at this source time (`Project.hasVisibleVideo`). */
  hasVisibleVideo(sourceTime: number): boolean;
  /** The Swift map itself (null on the trim-only fallback). */
  readonly speedMap: SpeedTimeMap | null;
}

/** `Project.effectiveTrimStart / effectiveTrimEnd`, against the real media duration. */
export function effectiveTrim(project: RenderProject, mediaDuration: number) {
  const duration = project.duration > 0 ? Math.min(project.duration, mediaDuration) : mediaDuration;
  const start = Math.max(0, Math.min(project.trimStart, duration));
  const endRaw = project.trimEnd > 0 ? project.trimEnd : duration;
  const end = Math.max(start, Math.min(endRaw, duration));
  return { start, end };
}

export function createTimeMap(project: RenderProject, mediaDuration: number, core: Project | null = null): TimeMap {
  if (core) {
    const window = exportSourceWindow(core, mediaDuration);
    const map = new SpeedTimeMap(window.start, window.end, core.speedRegions);
    const clips = effectiveVideoClipSegments(core);
    const outputDuration = exportedOutputDuration(core, map);
    return {
      outputDuration,
      speedMap: map,
      sourceTime: (t) => map.sourceTime(Math.max(0, Math.min(outputDuration, t))),
      outputTime: (s) => map.outputTime(s),
      hasVisibleVideo: (s) => coreHasVisibleVideo(core, s, 1.0 / 30.0, clips),
    };
  }
  const { start, end } = effectiveTrim(project, mediaDuration);
  const outputDuration = Math.max(0.0001, end - start);
  return {
    outputDuration,
    speedMap: null,
    sourceTime: (t) => start + Math.max(0, Math.min(outputDuration, t)),
    outputTime: (s) => Math.max(0, Math.min(outputDuration, s - start)),
    hasVisibleVideo: (s) => s >= start - 1e-9 && s <= end + 1e-9,
  };
}
