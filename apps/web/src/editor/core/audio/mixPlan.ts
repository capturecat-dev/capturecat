/**
 * Port of `Services/ProjectAudioMix.swift` `prepare(for:project:clickTimes:keystrokes:)`
 * plus the audio half of `VideoExporter.export` (reader range, fast-path
 * offset, output length) — WHAT the exported audio track contains, as plain
 * data. `engine/audio/mixer.ts` renders it; playback and export both render
 * the SAME plan (preview == export for audio).
 *
 * The Mac builds an AVMutableComposition: one composition track per recorded
 * audio track (index 0 = system audio volume, every other index = microphone
 * volume, 0 when muted), one per voice-over clip, one for click ticks and one
 * for the rendered key track. `EditTrack` reproduces the composition-track
 * edit semantics the Mac relies on — `insertTimeRange` INSERTS (content at
 * and after the insertion point is pushed later), `insertEmptyTimeRange`
 * pads gaps, `scaleTimeRange` retimes the edit it covers — on a 48 kHz frame
 * grid. Every time the Mac hands AVFoundation goes through
 * `CMTime(seconds:preferredTimescale: 600)`, which TRUNCATES (1 tick = 80
 * frames), so every edit boundary here is an integer frame.
 *
 * Speed regions: recorded audio in a scaled edit is time-stretched with the
 * pitch preserved (`audioTimePitchAlgorithm = .timeDomain`); voice-overs,
 * ticks and keys are never scaled. Cut clips leave silence.
 */
import type { KeystrokeEvent, Project, VideoClipSegment } from "../model/types";
import { effectiveTrimEnd, effectiveTrimStart, effectiveVideoClipSegments, exportedOutputDuration } from "../time/clips";
import { cmTimeValue } from "../math/exportLayout";
import { SpeedTimeMap } from "../time/speedTimeMap";
import { smax, smin } from "../math/swift";
import { SOUND_SAMPLE_RATE, TICK_DURATION, type KeyCue } from "./sounds";

export const MIX_SAMPLE_RATE = SOUND_SAMPLE_RATE;
/** Frames per CMTime tick at timescale 600. */
const FRAMES_PER_TICK = MIX_SAMPLE_RATE / 600;

/** `CMTime(seconds:preferredTimescale: 600)` in 48 kHz frames. */
export function cmFrames(seconds: number): number {
  return cmTimeValue(seconds, 600) * FRAMES_PER_TICK;
}

/** One composition edit: output frames [start, start+dur) play source frames [src, src+srcDur). */
export interface Edit {
  start: number;
  dur: number;
  src: number;
  srcDur: number;
}

/** AVMutableCompositionTrack edit semantics on a frame grid. */
export class EditTrack {
  edits: Edit[] = [];

  get end(): number {
    const last = this.edits[this.edits.length - 1];
    return last ? last.start + last.dur : 0;
  }

  /** `insertTimeRange(src…src+srcDur, at:)` — pushes later content by srcDur. */
  insert(at: number, src: number, srcDur: number): Edit {
    if (srcDur <= 0) return { start: at, dur: 0, src, srcDur: 0 };
    if (at < this.end) {
      const next: Edit[] = [];
      for (const e of this.edits) {
        const eEnd = e.start + e.dur;
        if (eEnd <= at) next.push(e);
        else if (e.start >= at) next.push({ ...e, start: e.start + srcDur });
        else {
          // Split the edit that spans the insertion point.
          const headDur = at - e.start;
          const ratio = e.srcDur / e.dur;
          next.push({ start: e.start, dur: headDur, src: e.src, srcDur: headDur * ratio });
          next.push({
            start: at + srcDur,
            dur: eEnd - at,
            src: e.src + headDur * ratio,
            srcDur: (eEnd - at) * ratio,
          });
        }
      }
      this.edits = next;
    }
    const edit: Edit = { start: at, dur: srcDur, src, srcDur };
    this.edits.push(edit);
    this.edits.sort((a, b) => a.start - b.start);
    return edit;
  }

  /** `scaleTimeRange(at…at+dur, toDuration:)` for the edit just inserted there. */
  scale(edit: Edit, toDur: number): void {
    const delta = toDur - edit.dur;
    if (delta === 0) return;
    const at = edit.start;
    for (const e of this.edits) if (e !== edit && e.start > at) e.start += delta;
    edit.dur = toDur;
  }
}

export interface RecordingTrackMix {
  /** Audio track index in the recording (file order). */
  index: number;
  /** `baseVolume(for:settings:)` as the Float AVAudioMix stores. */
  volume: number;
  /** Frames of this track's audio available on the source timeline. */
  sourceEndFrame: number;
}

export interface VoiceOverMix {
  clipId: string;
  /** `VoiceOverClip.fileName` — the key into `RenderMedia.files`. */
  fileName: string;
  edit: Edit;
  volume: number;
}

export interface AudioMixPlan {
  sampleRate: number;
  /** "fast": the source asset read from trimStart; "composed": the composition. */
  path: "fast" | "composed";
  /** Exported (video) length — `Project.exportedOutputDuration`. */
  totalSeconds: number;
  /** Frames the audio track actually carries (reader range ∩ media). 0 = no audio track. */
  endFrame: number;
  /** Recorded audio tracks with their edits (shared by every track). */
  recording: { tracks: RecordingTrackMix[]; edits: Edit[]; timePitch: boolean };
  voiceOvers: VoiceOverMix[];
  clicks: { edits: Edit[]; volume: number; style: Project["settings"]["clickSoundStyle"]; outputTimes: number[] } | null;
  keys: {
    cues: KeyCue[];
    /** `timeMap.outputDuration` handed to renderTrackWAV. */
    duration: number;
    volume: number;
    style: Project["settings"]["keySoundStyle"];
  } | null;
}

/** Everything about the media the Mac learns from AVFoundation. */
export interface AudioMediaInfo {
  /** Recording asset duration (seconds). */
  assetDuration: number;
  /** One entry per recorded audio track, file order: its end on the source timeline (seconds). */
  recordingTracks: { duration: number }[];
  /** Voice-over fileName → measured duration (seconds); missing/undecodable files are absent. */
  voiceDurations: Record<string, number>;
}

export interface SoundCueInput {
  /** `ClickRippleOverlay.discreteClickTimes` over the exporter's cursor chain (SOURCE seconds). */
  clickTimes: readonly number[];
  /** keys.json events (only read when keySoundEnabled). */
  keystrokes: readonly KeystrokeEvent[];
}

const f32 = Math.fround;

function baseVolume(index: number, settings: Project["settings"]): number {
  if (settings.muteRecordedAudio) return 0;
  const raw = index === 0 ? settings.systemAudioVolume : settings.microphoneVolume;
  return f32(smax(0, smin(1, raw)));
}

function insertScaledSegments(track: EditTrack, timeMap: SpeedTimeMap, clipSegments: readonly VideoClipSegment[]): void {
  const visible =
    clipSegments.length === 0 ? [{ startTime: timeMap.sourceStart, endTime: timeMap.sourceEnd }] : clipSegments;
  for (const seg of timeMap.segments) {
    for (const clip of visible) {
      const sourceStart = smax(seg.sourceStart, clip.startTime);
      const sourceEnd = smin(seg.sourceEnd, clip.endTime);
      const srcDurSeconds = smax(0, sourceEnd - sourceStart);
      if (!(srcDurSeconds > 0.0001)) continue;
      const outputStart = timeMap.outputTime(sourceStart);
      const outputEnd = timeMap.outputTime(sourceEnd);
      const outputDurSeconds = smax(0.001, outputEnd - outputStart);
      const srcStart = cmFrames(sourceStart);
      const srcDur = cmFrames(srcDurSeconds);
      const at = cmFrames(outputStart);
      // insertEmptyTimeRange for gaps is implicit: edits are positioned.
      const edit = track.insert(at, srcStart, srcDur);
      if (Math.abs(outputDurSeconds - srcDurSeconds) > 0.0001) {
        track.scale(edit, cmFrames(outputDurSeconds));
      }
    }
  }
}

/**
 * `ProjectAudioMix.prepare` + VideoExporter's audio reader, for export
 * (`applySpeedScaling: true`). Returns null when the export has no audio track.
 */
export function buildAudioMixPlan(project: Project, cues: SoundCueInput, media: AudioMediaInfo): AudioMixPlan | null {
  const settings = project.settings;
  // VideoExporter's own video map (trimEnd falls back to the asset duration).
  const trimStart = effectiveTrimStart(project);
  const exportTrimEnd = effectiveTrimEnd(project) > 0 ? effectiveTrimEnd(project) : media.assetDuration;
  const exportMap = new SpeedTimeMap(trimStart, exportTrimEnd, project.speedRegions);
  const totalSeconds = exportedOutputDuration(project, exportMap);
  const readerFrames = cmFrames(totalSeconds);

  const mixClicks = settings.clickSoundEnabled && cues.clickTimes.length > 0;
  const mixKeys = settings.keySoundEnabled && cues.keystrokes.length > 0;
  const voiceOverClips = project.voiceOverClips.filter((c) => media.voiceDurations[c.fileName] !== undefined);
  const hasSpeedRegions = project.speedRegions.length > 0;
  const clipSegments = project.videoClipSegments.length === 0 ? [] : effectiveVideoClipSegments(project);
  const hasIndependentVideoClips = clipSegments.length > 0;

  const recordingTracks: RecordingTrackMix[] = media.recordingTracks.map((t, index) => ({
    index,
    volume: baseVolume(index, settings),
    sourceEndFrame: Math.round(t.duration * MIX_SAMPLE_RATE),
  }));

  // Fast path: the source asset itself, read from CMTime(trimStart, 600).
  if (voiceOverClips.length === 0 && !hasSpeedRegions && !hasIndependentVideoClips && !mixClicks && !mixKeys) {
    if (recordingTracks.length === 0) return null;
    const src = cmFrames(trimStart);
    const edits: Edit[] = [{ start: 0, dur: readerFrames, src, srcDur: readerFrames }];
    const mediaEnd = Math.max(...recordingTracks.map((t) => t.sourceEndFrame - src));
    const endFrame = Math.max(0, Math.min(readerFrames, mediaEnd));
    return {
      sampleRate: MIX_SAMPLE_RATE,
      path: "fast",
      totalSeconds,
      endFrame,
      recording: { tracks: recordingTracks, edits, timePitch: false },
      voiceOvers: [],
      clicks: null,
      keys: null,
    };
  }

  // Composed path.
  const mapSourceStart = effectiveTrimStart(project);
  const mapSourceEnd = effectiveTrimEnd(project);
  const timeMap = new SpeedTimeMap(mapSourceStart, mapSourceEnd, project.speedRegions);
  const trackEnds: number[] = [];

  const recordingTrack = new EditTrack();
  insertScaledSegments(recordingTrack, timeMap, clipSegments);
  for (const t of recordingTracks) {
    // A recorded track ends where its last inserted media ends.
    let end = 0;
    for (const e of recordingTrack.edits) {
      const ratio = e.dur > 0 ? e.srcDur / e.dur : 1;
      const avail = Math.min(e.dur, Math.max(0, (t.sourceEndFrame - e.src) / ratio));
      if (avail > 0) end = Math.max(end, e.start + avail);
    }
    trackEnds.push(end);
  }

  const voiceOvers: VoiceOverMix[] = [];
  for (const clip of voiceOverClips) {
    const measured = media.voiceDurations[clip.fileName];
    const measuredSourceDuration = Number.isFinite(measured) ? measured : clip.sourceDuration;
    const safeSourceStart = smax(0, smin(clip.sourceStartTime, smax(0.1, measuredSourceDuration) - 0.1));
    const maxVisibleDuration = smax(
      0.1,
      smin(measuredSourceDuration - safeSourceStart, clip.sourceDuration - safeSourceStart),
    );
    const safeDuration = smax(0.1, smin(clip.duration, smin(maxVisibleDuration, smax(0.1, project.duration - clip.startTime))));
    const outputStartSeconds = timeMap.outputTime(clip.startTime);
    const track = new EditTrack();
    const edit = track.insert(cmFrames(outputStartSeconds), cmFrames(safeSourceStart), cmFrames(safeDuration));
    voiceOvers.push({
      clipId: clip.id,
      fileName: clip.fileName,
      edit,
      volume: f32(smax(0, smin(2, settings.voiceOverVolume * clip.gain))),
    });
    trackEnds.push(track.end);
  }

  const visible =
    clipSegments.length === 0 ? [{ startTime: mapSourceStart, endTime: mapSourceEnd }] : clipSegments;
  const inVisible = (t: number) => visible.some((c) => t >= c.startTime && t <= c.endTime);

  let clicks: AudioMixPlan["clicks"] = null;
  if (mixClicks) {
    const track = new EditTrack();
    const tickFrames = cmFrames(TICK_DURATION);
    const outputTimes: number[] = [];
    let lastOutput = -1.0;
    for (const sourceTime of [...cues.clickTimes].sort((a, b) => a - b)) {
      if (!(sourceTime >= mapSourceStart && sourceTime <= mapSourceEnd && inVisible(sourceTime))) continue;
      const outputTime = timeMap.outputTime(sourceTime);
      if (!(outputTime - lastOutput >= 0.05)) continue;
      lastOutput = outputTime;
      outputTimes.push(outputTime);
      track.insert(cmFrames(outputTime), 0, tickFrames);
    }
    clicks = {
      edits: track.edits,
      volume: f32(smax(0, smin(1, settings.clickSoundVolume))),
      style: settings.clickSoundStyle,
      outputTimes,
    };
    trackEnds.push(track.end);
  }

  let keys: AudioMixPlan["keys"] = null;
  if (mixKeys) {
    const mapped: KeyCue[] = [];
    for (const event of cues.keystrokes) {
      if (event.category === "scroll") continue;
      if (!(event.timestamp >= mapSourceStart && event.timestamp <= mapSourceEnd && inVisible(event.timestamp))) continue;
      mapped.push({ outputTime: timeMap.outputTime(event.timestamp), seedTimestamp: event.timestamp, category: event.category });
    }
    if (mapped.length > 0) {
      keys = {
        cues: mapped,
        duration: timeMap.outputDuration,
        volume: f32(smax(0, smin(1, settings.keySoundVolume))),
        style: settings.keySoundStyle,
      };
      // The key WAV is inserted whole at 0: Int((duration + 0.06) × 48000) frames.
      trackEnds.push(Math.max(1, Math.trunc((timeMap.outputDuration + 0.06) * MIX_SAMPLE_RATE)));
    }
  }

  const hasTracks = recordingTracks.length > 0 || voiceOvers.length > 0 || mixClicks || keys !== null;
  if (!hasTracks) return null;
  const endFrame = Math.max(0, Math.min(readerFrames, Math.max(0, ...trackEnds)));
  return {
    sampleRate: MIX_SAMPLE_RATE,
    path: "composed",
    totalSeconds,
    endFrame,
    recording: { tracks: recordingTracks, edits: recordingTrack.edits, timePitch: hasSpeedRegions },
    voiceOvers,
    clicks,
    keys,
  };
}
