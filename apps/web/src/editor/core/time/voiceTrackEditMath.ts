/**
 * Port of Views/Editor/VoiceTrackRowNative.swift — `VoiceTrackEditMath`
 * (voice-over clip drag resolution, OUTPUT time), `VoiceOverClip.clamp`, and
 * the `VoiceTrackCommits` output↔source mapping.
 * Locked by the `voiceTrackEditMath` golden vectors.
 */
import type { VoiceOverClip } from "../model/types";
import { smax, smin } from "../math/swift";
import type { SpeedTimeMap } from "./speedTimeMap";
import { nearestCandidate } from "./timelineSnap";

export type VoiceDragMode = "none" | "move" | "resizeLeft" | "resizeRight";

/** `VoiceOverClip.endTime` */
export function voiceClipEnd(c: Pick<VoiceOverClip, "startTime" | "duration">): number {
  return c.startTime + c.duration;
}

/** `VoiceOverClip.clamp(to:)` (returns a copy). */
export function clampVoiceClip(clip: VoiceOverClip, totalDuration: number): VoiceOverClip {
  const c = { ...clip };
  c.sourceStartTime = smax(0, smin(c.sourceStartTime, smax(0, c.sourceDuration - 0.1)));
  c.sourceDuration = smax(c.duration, c.sourceDuration);
  c.startTime = smax(0, smin(c.startTime, totalDuration));
  const maxVisibleDuration = smax(0.1, c.sourceDuration - c.sourceStartTime);
  c.duration = smax(0.1, smin(c.duration, smax(0.1, smin(totalDuration - c.startTime, maxVisibleDuration))));
  c.gain = smax(0, smin(c.gain, 2));
  return c;
}

export class VoiceTrackEditMath {
  readonly totalDuration: number;
  readonly trackWidth: number;
  readonly snapCandidates: readonly number[];
  readonly minDuration: number;

  constructor(init: { totalDuration: number; trackWidth: number; snapCandidates: readonly number[]; minDuration?: number }) {
    this.totalDuration = init.totalDuration;
    this.trackWidth = init.trackWidth;
    this.snapCandidates = init.snapCandidates;
    this.minDuration = init.minDuration ?? 0.25;
  }

  /** Output-time delta for a horizontal drag translation. */
  delta(translationX: number): number {
    if (!(this.trackWidth > 0)) return 0;
    return (translationX / this.trackWidth) * this.totalDuration;
  }

  resolvedClip(initial: VoiceOverClip, mode: VoiceDragMode, delta: number): VoiceOverClip {
    const snapEdge = (time: number, excludedEdges: readonly number[]): number | null => {
      const candidates = this.snapCandidates.filter((c) => !excludedEdges.some((e) => Math.abs(e - c) < 0.0001));
      return nearestCandidate(time, candidates, this.totalDuration, this.trackWidth);
    };
    const next: VoiceOverClip = { ...initial };
    const initialEnd = voiceClipEnd(initial);

    switch (mode) {
      case "none":
        break;
      case "move": {
        const duration = initial.duration;
        const proposedStart = initial.startTime + delta;
        const proposedEnd = proposedStart + duration;
        const candidates = this.snapCandidates.filter(
          (c) => Math.abs(c - initial.startTime) >= 0.0001 && Math.abs(c - initialEnd) >= 0.0001,
        );
        const s = nearestCandidate(proposedStart, candidates, this.totalDuration, this.trackWidth);
        const e = nearestCandidate(proposedEnd, candidates, this.totalDuration, this.trackWidth);
        let adjustedStart: number;
        if (s !== null && e !== null) {
          adjustedStart = Math.abs(s - proposedStart) <= Math.abs(e - proposedEnd) ? s : e - duration;
        } else if (s !== null) {
          adjustedStart = s;
        } else if (e !== null) {
          adjustedStart = e - duration;
        } else {
          adjustedStart = proposedStart;
        }
        next.startTime = smax(0, smin(this.totalDuration - duration, adjustedStart));
        break;
      }
      case "resizeLeft": {
        const snappedStart = snapEdge(initial.startTime + delta, [initial.startTime, initialEnd]) ?? initial.startTime + delta;
        const earliestStart = smax(0, initial.startTime - initial.sourceStartTime);
        const latestStart = initialEnd - this.minDuration;
        const newStart = smin(smax(snappedStart, earliestStart), latestStart);
        const sourceDelta = newStart - initial.startTime;
        next.startTime = newStart;
        next.sourceStartTime = smax(0, initial.sourceStartTime + sourceDelta);
        next.duration = smax(this.minDuration, initialEnd - newStart);
        break;
      }
      case "resizeRight": {
        const snappedEnd = snapEdge(initialEnd + delta, [initial.startTime, initialEnd]) ?? initialEnd + delta;
        const maxEnd = smin(
          this.totalDuration,
          initial.startTime + smax(this.minDuration, initial.sourceDuration - initial.sourceStartTime),
        );
        const newEnd = smax(initial.startTime + this.minDuration, smin(maxEnd, snappedEnd));
        next.duration = smax(this.minDuration, newEnd - initial.startTime);
        break;
      }
    }
    return clampVoiceClip(next, this.totalDuration);
  }
}

/** `VoiceTrackCommits.outputClip(for:)` — a stored (source-time) clip
 * remapped into OUTPUT time for display/editing. */
export function voiceOutputClip(stored: VoiceOverClip, timeMap: SpeedTimeMap): VoiceOverClip {
  const outStart = timeMap.outputTime(stored.startTime);
  const outEnd = timeMap.outputTime(stored.startTime + stored.duration);
  return { ...stored, startTime: outStart, duration: smax(0.01, outEnd - outStart) };
}

/** `VoiceTrackCommits.commit(id:outputValue:)` — an OUTPUT-time edited clip
 * written back as SOURCE time onto the stored clip (returns the new stored clip). */
export function voiceCommit(stored: VoiceOverClip, outputValue: VoiceOverClip, timeMap: SpeedTimeMap): VoiceOverClip {
  const newSourceStart = timeMap.sourceTime(outputValue.startTime);
  const newSourceEnd = timeMap.sourceTime(outputValue.startTime + outputValue.duration);
  return {
    ...stored,
    startTime: newSourceStart,
    duration: smax(0.01, newSourceEnd - newSourceStart),
    sourceStartTime: outputValue.sourceStartTime,
    gain: outputValue.gain,
    label: outputValue.label,
  };
}
