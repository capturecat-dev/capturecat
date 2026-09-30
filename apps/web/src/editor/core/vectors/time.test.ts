import { describe, it } from "vitest";
import { checkUnit } from "./harness";
import { SpeedTimeMap } from "../time/speedTimeMap";
import {
  effectiveTrimEnd,
  effectiveTrimStart,
  effectiveVideoClipSegments,
  exportedOutputDuration,
  exportSourceWindow,
  hasVisibleVideo,
  trimmedDuration,
  visibleVideoClip,
} from "../time/clips";
import {
  clampTime,
  magneticSnap,
  majorInterval,
  minorInterval,
  nearestCandidate,
  snap,
  snappedEdge,
  snapThreshold,
} from "../time/timelineSnap";
import { VideoTrackEditMath, type ClipSpan } from "../time/videoTrackEditMath";
import { VoiceTrackEditMath, voiceCommit, voiceOutputClip } from "../time/voiceTrackEditMath";

describe("time golden vectors", () => {
  it("speedTimeMap", () => {
    checkUnit("speedTimeMap", (i) => {
      const map = new SpeedTimeMap(i.sourceStart, i.sourceEnd, i.regions);
      return {
        segments: map.segments,
        outputDuration: map.outputDuration,
        sourceForOutput: i.outputQueries.map((t: number) => map.sourceTime(t)),
        outputForSource: i.sourceQueries.map((t: number) => map.outputTime(t)),
        speedAtSource: i.sourceQueries.map((t: number) => map.speedAtSource(t)),
      };
    });
  });

  it("projectClips", () => {
    checkUnit("projectClips", (i) => {
      const p = i.project;
      const clips = effectiveVideoClipSegments(p);
      return {
        effectiveTrimStart: effectiveTrimStart(p),
        effectiveTrimEnd: effectiveTrimEnd(p),
        trimmedDuration: trimmedDuration(p),
        effectiveVideoClipSegments: clips,
        queries: i.queries.map((q: { t: number; tolerance: number | null }) => {
          const tol = q.tolerance ?? undefined;
          const found = visibleVideoClip(p, q.t, tol);
          return {
            t: q.t,
            tolerance: q.tolerance,
            clipID: found ? found.id : null,
            has: hasVisibleVideo(p, q.t, tol),
          };
        }),
      };
    });
  });

  it("exportedDuration", () => {
    checkUnit("exportedDuration", (i) => {
      const p = i.project;
      const win = exportSourceWindow(p, i.assetDuration);
      const map = new SpeedTimeMap(win.start, win.end, p.speedRegions);
      return {
        exportSourceStart: win.start,
        exportSourceEnd: win.end,
        exportMapOutputDuration: map.outputDuration,
        totalSeconds: exportedOutputDuration(p, map),
        trimmedMapOutputDuration: SpeedTimeMap.trimmedOutputOf(p).outputDuration,
      };
    });
  });

  it("timelineSnap", () => {
    checkUnit("timelineSnap", (i) => ({
      majorInterval: majorInterval(i.pixelsPerSecond),
      minorInterval: minorInterval(i.duration, i.trackWidth),
      snap: snap(i.time, i.duration, i.trackWidth),
      snapThreshold: snapThreshold(i.duration, i.trackWidth),
      nearestCandidate: nearestCandidate(i.time, i.candidates, i.duration, i.trackWidth),
      magneticSnap: magneticSnap(i.time, i.candidates, i.duration, i.trackWidth),
      snappedEdge: snappedEdge(i.start, i.end, i.candidates, i.checkStart, i.checkEnd),
      clamp: clampTime(i.time, i.duration),
    }));
  });

  it("videoTrackEditMath", () => {
    checkUnit("videoTrackEditMath", (i) => {
      const math = new VideoTrackEditMath({
        duration: i.duration,
        trackWidth: i.trackWidth,
        snapCandidates: i.snapCandidates,
        regionStart: i.regionStart,
        regionEnd: i.regionEnd,
      });
      const clips: ClipSpan[] = i.clips;
      const clip = clips[i.clipIndex];
      const clipDuration = clip.outputEnd - clip.outputStart;
      return {
        resolvedTimes: math.resolvedTimes(i.mode, i.delta, i.dragInitialStart, i.dragInitialEnd),
        moveBounds: math.moveBounds(clip, clips),
        resizeBounds: math.resizeBounds(clip, i.side, clips),
        snapClipMoveStart: math.snapClipMoveStart(i.proposed, i.proposed + clipDuration, clipDuration, i.excluded),
        snapClipEdge: math.snapClipEdge(i.proposed, i.excluded),
        resolvedClipMoveOutputStart: math.resolvedClipMoveOutputStart(clip, clips, i.proposed, i.snapsToCandidates),
        resolvedClipEdgeOutput: math.resolvedClipEdgeOutput(clip, clips, i.side, i.proposed, i.snapsToCandidates),
      };
    });
  });

  it("voiceTrackEditMath", () => {
    checkUnit("voiceTrackEditMath", (i) => {
      const math = new VoiceTrackEditMath({
        totalDuration: i.totalDuration,
        trackWidth: i.trackWidth,
        snapCandidates: i.snapCandidates,
      });
      const resolved = math.resolvedClip(i.clip, i.mode, i.delta);
      const map = new SpeedTimeMap(i.map.sourceStart, i.map.sourceEnd, i.map.regions);
      return {
        delta: math.delta(i.translationX),
        resolvedClip: resolved,
        outputClip: voiceOutputClip(i.clip, map),
        committed: voiceCommit(i.clip, resolved, map),
      };
    });
  });
});
