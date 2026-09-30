/**
 * Decoded timeline media → TimelineSnapshot: the web twin of
 * TimelineViewController.canvasVideoAssets() (thumbnails, the recording's
 * merged trim-window waveform, sourceSegments, trim window) and
 * canvasVoiceAssets() (each voice clip's 72-bucket waveform).
 *
 * Pure (no React, no worker): the snapshot selector stays a selector, and
 * any waveform/assets another producer already set are kept — a clip that
 * arrives WITH a waveform is never overwritten; one without gets backfilled.
 * Bucketing is memoised per envelope + window, so re-deriving the snapshot on
 * every edit costs nothing until the trim / clip window actually changes.
 */
import {
  recordingWaveform,
  voiceClipWaveform,
  voiceWaveformSignature,
  type PeakEnvelope,
} from "../../../core/audio/waveformPeaks";
import type { Project } from "../../../core/model";
import { effectiveTrimEnd, effectiveTrimStart } from "../../../core/time/clips";
import type { TimelineAssets, TimelineSnapshot, TimelineThumbnailImage, VoiceClip } from "../types";

export interface TimelineMediaSnapshot {
  /** Bumps whenever anything below changes. */
  version: number;
  /** Decoded filmstrip thumbnails, ascending by (requested) time. */
  thumbnails: readonly TimelineThumbnailImage[];
  /** The recording's audio tracks (file order); null = not decoded yet. */
  recording: readonly (PeakEnvelope | null)[] | null;
  /** Voice-over file name → its first track's envelope (null = missing / undecodable). */
  voice: ReadonlyMap<string, PeakEnvelope | null>;
}

export const EMPTY_TIMELINE_MEDIA: TimelineMediaSnapshot = {
  version: 0,
  thumbnails: [],
  recording: null,
  voice: new Map(),
};

const recordingMemo = new WeakMap<readonly (PeakEnvelope | null)[], { key: string; value: Float32Array }>();
const voiceMemo = new WeakMap<PeakEnvelope, Map<string, Float32Array>>();

/** loadAudioSamples' output for the current trim window (memoised). */
export function recordingSamples(project: Pick<Project, "trimStart" | "trimEnd" | "duration">, tracks: readonly (PeakEnvelope | null)[]): Float32Array {
  const key = `${project.trimStart}|${project.trimEnd}|${project.duration}`;
  const hit = recordingMemo.get(tracks);
  if (hit && hit.key === key) return hit.value;
  const value = recordingWaveform(project, tracks.filter((t): t is PeakEnvelope => t !== null));
  recordingMemo.set(tracks, { key, value });
  return value;
}

/** loadVoiceWaveforms' output for one clip (memoised per envelope + clip signature). */
export function voiceSamples(clip: Project["voiceOverClips"][number], env: PeakEnvelope): Float32Array {
  const signature = voiceWaveformSignature(clip);
  let byClip = voiceMemo.get(env);
  if (!byClip) voiceMemo.set(env, (byClip = new Map()));
  const hit = byClip.get(signature);
  if (hit) return hit;
  const value = voiceClipWaveform(clip, env);
  if (byClip.size > 32) byClip.delete(byClip.keys().next().value!);
  byClip.set(signature, value);
  return value;
}

export function applyTimelineMedia(
  snap: TimelineSnapshot,
  project: Project | null | undefined,
  media: TimelineMediaSnapshot,
): TimelineSnapshot {
  if (!project) return snap;
  const prev = snap.assets;
  const audio = media.recording ? recordingSamples(project, media.recording) : null;
  const assets: TimelineAssets = {
    ...prev,
    version: (prev?.version ?? 0) + media.version,
    thumbnails: media.thumbnails.length > 0 ? media.thumbnails : prev?.thumbnails,
    sourceSegments: project.sourceSegments,
    audioSamples: audio && audio.length > 0 ? audio : prev?.audioSamples,
    trimSourceStart: effectiveTrimStart(project),
    trimSourceEnd: effectiveTrimEnd(project),
  };

  let voice = snap.voice;
  if (voice && voice.clips.some((c) => !c.waveform || c.waveform.length === 0)) {
    const byId = new Map(project.voiceOverClips.map((c) => [c.id, c] as const));
    let changed = false;
    const clips = voice.clips.map((c): VoiceClip => {
      if (c.waveform && c.waveform.length > 0) return c;
      const stored = byId.get(c.id);
      const env = stored ? media.voice.get(stored.fileName) : undefined;
      if (!stored || !env) return c;
      const samples = voiceSamples(stored, env);
      if (samples.length === 0) return c;
      changed = true;
      return { ...c, waveform: samples };
    });
    if (changed) voice = { ...voice, clips };
  }
  return { ...snap, assets, voice };
}
