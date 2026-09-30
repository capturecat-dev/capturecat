/**
 * Port of Services/SpeedTimeMap.swift — SOURCE time (original recording) ↔
 * OUTPUT time (after trim + per-segment playback speed).
 *
 * Locked to Swift by the `speedTimeMap` golden vectors.
 */
import type { Project, VideoSpeedRegion } from "../model/types";
import { smax, smin } from "../math/swift";
import { effectiveTrimEnd, effectiveTrimStart } from "./clips";

export interface SpeedSegment {
  readonly sourceStart: number;
  readonly sourceEnd: number;
  readonly outputStart: number;
  readonly outputEnd: number;
  readonly speed: number;
}

type SpeedRegionLike = Pick<VideoSpeedRegion, "startTime" | "endTime" | "speed">;

export class SpeedTimeMap {
  readonly segments: readonly SpeedSegment[];
  readonly sourceStart: number;
  readonly sourceEnd: number;

  constructor(sourceStart: number, sourceEnd: number, regions: readonly SpeedRegionLike[]) {
    this.sourceStart = sourceStart;
    this.sourceEnd = sourceEnd;

    // Clip and sort regions to [sourceStart, sourceEnd]
    const clipped: Array<[number, number, number]> = [];
    for (const region of regions) {
      const start = smax(region.startTime, sourceStart);
      const end = smin(region.endTime, sourceEnd);
      if (!(end > start + 0.0001)) continue;
      const safeSpeed = smax(0.1, region.speed);
      clipped.push([start, end, safeSpeed]);
    }
    clipped.sort((a, b) => (a[0] < b[0] ? -1 : b[0] < a[0] ? 1 : 0));

    // Build piecewise segments covering the full range, filling gaps with speed=1
    const result: SpeedSegment[] = [];
    let cursor = sourceStart;
    let outputCursor = 0;

    for (const [start, end, speed] of clipped) {
      // Skip any overlap with previously consumed source range
      const safeStart = smax(cursor, start);
      const safeEnd = smax(safeStart, end);
      if (safeEnd <= safeStart) continue;

      if (safeStart > cursor) {
        const gapDur = safeStart - cursor;
        result.push({
          sourceStart: cursor,
          sourceEnd: safeStart,
          outputStart: outputCursor,
          outputEnd: outputCursor + gapDur,
          speed: 1.0,
        });
        outputCursor += gapDur;
      }

      const segDur = safeEnd - safeStart;
      const outDur = segDur / speed;
      result.push({
        sourceStart: safeStart,
        sourceEnd: safeEnd,
        outputStart: outputCursor,
        outputEnd: outputCursor + outDur,
        speed,
      });
      outputCursor += outDur;
      cursor = safeEnd;
    }

    if (cursor < sourceEnd) {
      const gapDur = sourceEnd - cursor;
      result.push({
        sourceStart: cursor,
        sourceEnd,
        outputStart: outputCursor,
        outputEnd: outputCursor + gapDur,
        speed: 1.0,
      });
    }

    if (result.length === 0) {
      result.push({
        sourceStart,
        sourceEnd,
        outputStart: 0,
        outputEnd: smax(0, sourceEnd - sourceStart),
        speed: 1.0,
      });
    }

    this.segments = result;
  }

  /** `SpeedTimeMap(trimmedOutputOf: project)` — the project's effective trim
   * window and its speed regions (every OUTPUT-time consumer's map). */
  static trimmedOutputOf(project: TrimmedMapProject): SpeedTimeMap {
    const trimStart = effectiveTrimStart(project);
    return new SpeedTimeMap(trimStart, smax(trimStart, effectiveTrimEnd(project)), project.speedRegions);
  }

  get outputDuration(): number {
    return this.segments.length > 0 ? this.segments[this.segments.length - 1].outputEnd : 0;
  }

  /** Output (exported) time → source (original recording) time. */
  sourceTime(outputTime: number): number {
    const segs = this.segments;
    if (segs.length === 0) return this.sourceStart + outputTime;
    if (outputTime <= segs[0].outputStart) return segs[0].sourceStart;
    const last = segs[segs.length - 1];
    if (outputTime >= last.outputEnd) return last.sourceEnd;
    for (const seg of segs) {
      if (outputTime >= seg.outputStart && outputTime <= seg.outputEnd) {
        const local = outputTime - seg.outputStart;
        return seg.sourceStart + local * seg.speed;
      }
    }
    return last.sourceEnd;
  }

  /** Source → output time. */
  outputTime(sourceTime: number): number {
    const segs = this.segments;
    if (segs.length === 0) return sourceTime - this.sourceStart;
    if (sourceTime <= segs[0].sourceStart) return segs[0].outputStart;
    const last = segs[segs.length - 1];
    if (sourceTime >= last.sourceEnd) return last.outputEnd;
    for (const seg of segs) {
      if (sourceTime >= seg.sourceStart && sourceTime <= seg.sourceEnd) {
        const local = sourceTime - seg.sourceStart;
        return seg.outputStart + local / seg.speed;
      }
    }
    return last.outputEnd;
  }

  /** Speed in effect at a source time (1.0 outside every segment). */
  speedAtSource(sourceTime: number): number {
    for (const seg of this.segments) {
      if (sourceTime >= seg.sourceStart && sourceTime <= seg.sourceEnd) return seg.speed;
    }
    return 1.0;
  }
}

export type TrimmedMapProject = Pick<Project, "duration" | "trimStart" | "trimEnd" | "speedRegions">;
