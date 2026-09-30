/**
 * Messages between the main thread (TimelineMediaClient) and the timeline
 * media worker (timelineMedia.worker.ts). The worker owns its OWN mediabunny
 * inputs and WebCodecs decoders — it never shares, waits on or competes for
 * the render engine's decoder (engine/worker.ts) or the playback audio.
 */
import type { PeakEnvelope } from "../../../core/audio/waveformPeaks";

export interface FilmstripRequest {
  type: "filmstrip";
  id: number;
  /** Absolute media URL (http(s) or blob:). */
  url: string;
  /** Persistent cache identity (content hash / URL without its presigned query); null = memory only. */
  cacheKey: string | null;
  /** project.duration (source seconds) — the Mac thumbnails the whole recording. */
  duration: number;
  count: number;
  heightPx: number;
}

export interface EnvelopeRequest {
  type: "envelope";
  id: number;
  url: string;
  cacheKey: string | null;
  /** "all": every audio track in file order (the recording); "first": track 0 (a voice-over file). */
  tracks: "all" | "first";
  /** Honour iTunSMPB priming (AVAudioRecorder m4a voice-overs), like the playback reader. */
  gapless: boolean;
}

export type MediaWorkerRequest =
  | FilmstripRequest
  | EnvelopeRequest
  | { type: "cancel"; id: number }
  /** Playback running: the worker spaces its decodes out so it never competes with the engine. */
  | { type: "pace"; playing: boolean };

export type MediaWorkerResponse =
  /** One decoded thumbnail; `indices` are every request slot it stands in for (keyframe snapping can share one). */
  | { type: "thumb"; id: number; indices: number[]; bitmap: ImageBitmap }
  | { type: "filmstripDone"; id: number; fromCache: boolean; ms: number; decoded: number }
  /** One envelope per requested track; null = that track has no decodable audio. */
  | { type: "envelope"; id: number; tracks: (PeakEnvelope | null)[]; fromCache: boolean; ms: number }
  | { type: "error"; id: number; message: string };
