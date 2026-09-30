/**
 * Port of `VideoSliceMath` (Views/Editor/VideoTrackRowNative.swift) — the
 * slice tool's geometry, shared by the canvas (hover/click target) and the
 * edit (`isSliceableOutputTime`) so a click resolves to the SAME split time.
 * All times are OUTPUT seconds. Unit-tested (videoSliceMath.test.ts); the
 * Swift twin is exercised by `--videotrack-math-test`.
 */
import { smax, smin } from "../math/swift";
import type { ClipSpan } from "./videoTrackEditMath";

/** A cut must leave at least this much on both sides. */
export const MIN_SLICE_DURATION = 0.2;
/** Cursor distance (pt) within which the cut snaps onto the playhead. */
export const PLAYHEAD_SNAP_DISTANCE = 12;

export interface SliceTarget {
  outputTime: number;
  x: number;
  snappedToPlayhead: boolean;
}

/** `VideoSliceMath.resolvedTarget(atX:trackWidth:outputDuration:playheadOutputTime:)` */
export function resolvedSliceTarget(x: number, trackWidth: number, outputDuration: number, playheadOutputTime: number): SliceTarget {
  const clampedX = smax(0, smin(trackWidth, x));
  if (!(trackWidth > 0 && outputDuration > 0)) return { outputTime: 0, x: clampedX, snappedToPlayhead: false };
  const rawOutputTime = smax(0, smin(1, clampedX / trackWidth)) * outputDuration;
  const playheadX = trackWidth * (playheadOutputTime / outputDuration);
  if (Math.abs(clampedX - playheadX) <= PLAYHEAD_SNAP_DISTANCE) {
    return { outputTime: playheadOutputTime, x: playheadX, snappedToPlayhead: true };
  }
  return { outputTime: rawOutputTime, x: clampedX, snappedToPlayhead: false };
}

/** `VideoSliceMath.isSliceable(_:trimStartOutput:trimEndOutput:clipSpans:)` */
export function isSliceable(outputTime: number, trimStartOutput: number, trimEndOutput: number, clipSpans: readonly ClipSpan[]): boolean {
  if (!(outputTime > trimStartOutput + MIN_SLICE_DURATION && outputTime < trimEndOutput - MIN_SLICE_DURATION)) return false;
  return clipSpans.some((c) => outputTime - c.outputStart >= MIN_SLICE_DURATION && c.outputEnd - outputTime >= MIN_SLICE_DURATION);
}
