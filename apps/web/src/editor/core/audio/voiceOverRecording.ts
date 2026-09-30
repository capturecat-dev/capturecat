/**
 * Voice-over recording — the pure decisions of the Mac's record flow, shared
 * by the web recorder (record/voiceOverRecorder.ts), the session controller
 * (state/voiceOver.ts) and the timeline's live block:
 *
 *   EditorPlaybackController.startVoiceOverRecording
 *     the clip starts at the playhead, clamped to the trim window (SOURCE s)
 *   EditorPlaybackController.stopVoiceOverRecording
 *     duration = min(file duration, max(0.1, project.duration − start));
 *     kept only when > 0.1 s; `VoiceOverClip(fileName:startTime:duration:
 *     sourceDuration:)` — sourceStartTime 0, gain 1, label "Voice Over"
 *   EditorPlaybackController.startVoiceOverMetering
 *     one meter level every 45 ms, the newest 240 kept
 *   VoiceOverRecorder
 *     `voiceover-<UUID>.m4a`, AAC 48 kHz mono 192 kbps; the meter is
 *     `pow(10, averagePower / 20)` clamped to 0…1 (a linear RMS level)
 *   TimelineVoiceRowModel.make + voiceLiveRect
 *     the live block exists once the playhead is past the start; its width
 *     is `max(0.1, current − start)` (OUTPUT s); no samples yet → 24 × 0.08
 *
 * No DOM, no WebAudio: runs in vitest.
 */
import { smax, smin } from "../math/swift";
import { newVoiceOverClip, type Project, type VoiceOverClip } from "../model";
import { effectiveTrimEnd, effectiveTrimStart } from "../time/clips";
import type { SpeedTimeMap } from "../time/speedTimeMap";

/** VoiceOverRecorder settings (AVSampleRateKey / AVNumberOfChannelsKey / AVEncoderBitRateKey). */
export const VOICE_OVER_SAMPLE_RATE = 48_000;
export const VOICE_OVER_CHANNELS = 1;
export const VOICE_OVER_AAC_BITRATE = 192_000;

/** startVoiceOverMetering: `Task.sleep(for: .milliseconds(45))`, 240-sample window. */
export const VOICE_OVER_METER_INTERVAL_MS = 45;
export const VOICE_OVER_METER_CAP = 240;

/** Clips at or under this length are dropped (VoiceOverRecorder + stopVoiceOverRecording). */
export const VOICE_OVER_MIN_DURATION = 0.1;

/** The live block's waveform before the first meter sample (`[Float](repeating: 0.08, count: 24)`). */
export const LIVE_PLACEHOLDER_SAMPLES: readonly number[] = Object.freeze(new Array<number>(24).fill(0.08));

/** The Mac's error copy (presentVoiceOverError → CCAlert "Voice Over"). */
export const VOICE_OVER_ALERT_TITLE = "Voice Over";
export const VOICE_OVER_PERMISSION_MESSAGE = "Microphone access is required to record a voice over.";
export const VOICE_OVER_START_FAILED_MESSAGE = "Unable to start voice-over recording.";

export type VoiceOverFileExtension = "m4a" | "wav";

/** `voiceover-\(UUID().uuidString).m4a` (the web writes `.wav` only when it cannot encode AAC). */
export function voiceOverFileName(uuid: string, ext: VoiceOverFileExtension = "m4a"): string {
  return `voiceover-${uuid.toUpperCase()}.${ext}`;
}

/** `min(max(currentTime, project.effectiveTrimStart), project.effectiveTrimEnd)` — SOURCE seconds. */
export function voiceOverRecordingStart(project: Project, currentSource: number): number {
  return smin(smax(currentSource, effectiveTrimStart(project)), effectiveTrimEnd(project));
}

export interface FinishedVoiceOver {
  fileName: string;
  /** SOURCE seconds — the value `voiceOverRecordingStart` returned. */
  clipStart: number;
  /** The written file's duration (seconds). */
  finalizedDuration: number;
  /** Clip id (default: a fresh UUID, like `VoiceOverClip(id: UUID())`). */
  id?: string;
}

/**
 * The clip `stopVoiceOverRecording` appends, or null when the take is too
 * short to keep (the Mac deletes the file then).
 */
export function recordedVoiceOverClip(project: Project, take: FinishedVoiceOver): VoiceOverClip | null {
  if (!(take.finalizedDuration > VOICE_OVER_MIN_DURATION)) return null;
  const clipDuration = smin(take.finalizedDuration, smax(0.1, project.duration - take.clipStart));
  if (!(clipDuration > VOICE_OVER_MIN_DURATION)) return null;
  return newVoiceOverClip(take.fileName, take.clipStart, clipDuration, {
    id: take.id,
    sourceDuration: take.finalizedDuration,
  });
}

/**
 * AVAudioRecorder's `averagePower` → `pow(10, power / 20)`, clamped to 0…1:
 * the RMS amplitude of the most recent samples.
 */
export function meterLevel(samples: ArrayLike<number>, from = 0, to = samples.length): number {
  const a = Math.max(0, from);
  const b = Math.min(samples.length, to);
  if (b <= a) return 0;
  let sum = 0;
  for (let i = a; i < b; i++) {
    const v = samples[i];
    sum += v * v;
  }
  const rms = Math.sqrt(sum / (b - a));
  return Number.isFinite(rms) ? Math.max(0, Math.min(1, rms)) : 0;
}

/** `liveVoiceOverSamples.append(level)`, then drop the oldest past 240. */
export function appendMeterSample(samples: readonly number[], level: number, cap = VOICE_OVER_METER_CAP): number[] {
  const next = [...samples, level];
  return next.length > cap ? next.slice(next.length - cap) : next;
}

export interface LiveVoiceBlock {
  /** OUTPUT seconds. */
  start: number;
  /** OUTPUT seconds: start + max(0.1, current − start) (voiceLiveRect). */
  end: number;
  samples: ArrayLike<number>;
}

/**
 * The timeline's "Recording Voice Over" block for a recording that started
 * at `startSource` with the playhead now at `currentSource` (both SOURCE
 * seconds), or null while the gate is closed.
 */
export function liveVoiceBlock(
  project: Project,
  map: SpeedTimeMap,
  rec: { startSource: number; currentSource: number; samples: ArrayLike<number> },
): LiveVoiceBlock | null {
  if (!(rec.currentSource > rec.startSource) || !(project.duration > 0)) return null;
  const start = map.outputTime(rec.startSource);
  const current = map.outputTime(rec.currentSource);
  return {
    start,
    end: start + smax(0.1, current - start),
    samples: rec.samples.length > 0 ? rec.samples : LIVE_PLACEHOLDER_SAMPLES,
  };
}

/**
 * Where the recorded PCM lines up with the timeline. The file's first sample
 * must be the moment the timeline left the clip start: samples captured
 * before it are dropped; if the microphone delivered its first sample after
 * it, the gap is filled with silence. Frames are sample indices on the
 * capture clock; returns how many leading frames of `chunkStart…` to skip
 * (≥ 0) or how many silent frames to write first (< 0 → pad = −value).
 */
export function alignFirstChunk(chunkStartFrame: number, anchorFrame: number): { skip: number; pad: number } {
  const delta = Math.round(anchorFrame - chunkStartFrame);
  return delta >= 0 ? { skip: delta, pad: 0 } : { skip: 0, pad: -delta };
}
