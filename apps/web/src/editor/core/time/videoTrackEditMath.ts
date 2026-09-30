/**
 * Port of Views/Editor/VideoTrackEditMath.swift — the VIDEO track's drag
 * resolution (whole-track trim/slip + multi-clip move/resize). All times are
 * OUTPUT time. Locked by the `videoTrackEditMath` golden vectors.
 */
import { smax, smin } from "../math/swift";
import { nearestCandidate } from "./timelineSnap";

export type VideoDragMode = "none" | "move" | "resizeLeft" | "resizeRight";
export type TrackSide = "left" | "right";

/** A clip span in OUTPUT time. */
export interface ClipSpan {
  id: string;
  outputStart: number;
  outputEnd: number;
}

export interface VideoTrackEditMathInit {
  duration: number;
  trackWidth: number;
  snapCandidates: readonly number[];
  regionStart: number;
  regionEnd: number;
  minDuration?: number;
}

export class VideoTrackEditMath {
  readonly duration: number;
  readonly trackWidth: number;
  readonly snapCandidates: readonly number[];
  readonly regionStart: number;
  readonly regionEnd: number;
  readonly minDuration: number;

  constructor(init: VideoTrackEditMathInit) {
    this.duration = init.duration;
    this.trackWidth = init.trackWidth;
    this.snapCandidates = init.snapCandidates;
    this.regionStart = init.regionStart;
    this.regionEnd = init.regionEnd;
    this.minDuration = init.minDuration ?? 0.5;
  }

  private filtered(excludedEdges: readonly number[]): number[] {
    return this.snapCandidates.filter((c) => !excludedEdges.some((e) => Math.abs(e - c) < 0.0001));
  }

  private nearest(time: number, candidates: readonly number[]): number | null {
    return nearestCandidate(time, candidates, this.duration, this.trackWidth);
  }

  /** Whole-track drag. resizeLeft/Right deliberately do NOT clamp to
   * [0, duration]: overshoot restores trimmed head/tail material on commit. */
  resolvedTimes(
    mode: VideoDragMode,
    delta: number,
    dragInitialStart: number,
    dragInitialEnd: number,
  ): { start: number; end: number } {
    switch (mode) {
      case "resizeLeft": {
        const snappedStart =
          this.nearest(dragInitialStart + delta, this.filtered([dragInitialStart, dragInitialEnd])) ??
          dragInitialStart + delta;
        const newStart = smin(dragInitialEnd - this.minDuration, snappedStart);
        return { start: newStart, end: dragInitialEnd };
      }
      case "resizeRight": {
        const snappedEnd =
          this.nearest(dragInitialEnd + delta, this.filtered([dragInitialStart, dragInitialEnd])) ??
          dragInitialEnd + delta;
        const newEnd = smax(dragInitialStart + this.minDuration, snappedEnd);
        return { start: dragInitialStart, end: newEnd };
      }
      case "move": {
        const clipDuration = dragInitialEnd - dragInitialStart;
        const maxStart = smax(0, this.duration - clipDuration);
        const proposedStart = dragInitialStart + delta;
        const proposedEnd = proposedStart + clipDuration;
        const candidates = this.snapCandidates.filter(
          (c) => Math.abs(c - dragInitialStart) >= 0.0001 && Math.abs(c - dragInitialEnd) >= 0.0001,
        );
        const s = this.nearest(proposedStart, candidates);
        const e = this.nearest(proposedEnd, candidates);
        let adjustedStart: number;
        if (s !== null && e !== null) {
          adjustedStart = Math.abs(s - proposedStart) <= Math.abs(e - proposedEnd) ? s : e - clipDuration;
        } else if (s !== null) {
          adjustedStart = s;
        } else if (e !== null) {
          adjustedStart = e - clipDuration;
        } else {
          adjustedStart = proposedStart;
        }
        const newStart = smin(smax(0, adjustedStart), maxStart);
        return { start: newStart, end: smin(this.duration, newStart + clipDuration) };
      }
      case "none":
        return { start: this.regionStart, end: this.regionEnd };
    }
  }

  /** Neighbors clamp a clip's travel. */
  moveBounds(clip: ClipSpan, clips: readonly ClipSpan[]): { lower: number; upper: number } {
    const index = clips.findIndex((c) => c.id === clip.id);
    const previousEnd = index > 0 ? clips[index - 1].outputEnd : 0;
    const nextStart = index >= 0 && index < clips.length - 1 ? clips[index + 1].outputStart : this.duration;
    return { lower: previousEnd, upper: nextStart - (clip.outputEnd - clip.outputStart) };
  }

  resizeBounds(clip: ClipSpan, side: TrackSide, clips: readonly ClipSpan[]): { lower: number; upper: number } {
    const index = clips.findIndex((c) => c.id === clip.id);
    if (side === "left") {
      const previousEnd = index > 0 ? clips[index - 1].outputEnd : 0;
      return { lower: smax(0, previousEnd), upper: clip.outputEnd - this.minDuration };
    }
    const nextStart = index >= 0 && index < clips.length - 1 ? clips[index + 1].outputStart : this.duration;
    return { lower: clip.outputStart + this.minDuration, upper: smin(this.duration, nextStart) };
  }

  snapClipMoveStart(
    outputStart: number,
    proposedOutputEnd: number,
    clipDuration: number,
    excludedEdges: readonly number[],
  ): number {
    const candidates = this.filtered(excludedEdges);
    const s = this.nearest(outputStart, candidates);
    const e = this.nearest(proposedOutputEnd, candidates);
    if (s !== null && e !== null) {
      return Math.abs(s - outputStart) <= Math.abs(e - proposedOutputEnd) ? s : e - clipDuration;
    }
    if (s !== null) return s;
    if (e !== null) return e - clipDuration;
    return outputStart;
  }

  snapClipEdge(outputTime: number, excludedEdges: readonly number[]): number {
    return this.nearest(outputTime, this.filtered(excludedEdges)) ?? outputTime;
  }

  resolvedClipMoveOutputStart(
    clip: ClipSpan,
    clips: readonly ClipSpan[],
    proposedOutputStart: number,
    snapsToCandidates = true,
  ): number {
    const bounds = this.moveBounds(clip, clips);
    if (!(bounds.upper >= bounds.lower)) return clip.outputStart;
    const clipDuration = clip.outputEnd - clip.outputStart;
    const proposedEnd = proposedOutputStart + clipDuration;
    const resolved = snapsToCandidates
      ? this.snapClipMoveStart(proposedOutputStart, proposedEnd, clipDuration, [clip.outputStart, clip.outputEnd])
      : proposedOutputStart;
    return smin(smax(resolved, bounds.lower), bounds.upper);
  }

  resolvedClipEdgeOutput(
    clip: ClipSpan,
    clips: readonly ClipSpan[],
    side: TrackSide,
    proposedOutput: number,
    snapsToCandidates = true,
  ): number {
    const bounds = this.resizeBounds(clip, side, clips);
    const resolved = snapsToCandidates
      ? this.snapClipEdge(proposedOutput, [clip.outputStart, clip.outputEnd])
      : proposedOutput;
    return smin(smax(resolved, bounds.lower), bounds.upper);
  }
}
