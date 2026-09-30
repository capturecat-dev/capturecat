/**
 * The timeline's media producer — the web twin of
 * TimelineViewController.restartLoadersIfNeeded + loadThumbnails /
 * loadAudioSamples / loadVoiceWaveforms:
 *
 *   filmstrip   40 thumbnails of the recording (TimelineThumbnailer), decoded
 *               in the timeline media worker at the Mac's 48 pt height ×
 *               devicePixelRatio; reloaded when the recording, its duration
 *               or the display's pixel ratio changes. Thumbnails stream in
 *               as they decode (the Mac shows the strip once all 40 land).
 *   recording   every audio track's peak envelope (decoded once per file);
 *               the 180-bucket trim-window waveform is re-derived from it on
 *               every trim change without decoding again.
 *   voice       each voice-over FILE's envelope; every clip lacking a
 *               waveform — including clips a voice-over recording adds
 *               while the editor is open — gets its 72 buckets from it.
 *               A file whose URL cannot be resolved yet is retried.
 *
 * Nothing is persisted into project.json (the Mac keeps waveforms in memory
 * only); decoded media is cached per file in IndexedDB (mediaCache.ts).
 */
import { useEffect, useMemo, useState, useSyncExternalStore } from "react";

import type { PeakEnvelope } from "../../../core/audio/waveformPeaks";
import type { Project } from "../../../core/model";
import { FILMSTRIP_TARGET_COUNT, filmstripPixelHeight, filmstripRequestTimes } from "../../../core/time/filmstrip";
import type { MediaUrls } from "../../../state/cloud";
import type { TimelineSnapshot, TimelineThumbnailImage } from "../types";
import { applyTimelineMedia, EMPTY_TIMELINE_MEDIA, type TimelineMediaSnapshot } from "./applyTimelineMedia";
import { absoluteUrl, mediaIdentity } from "./mediaIdentity";
import { TimelineMediaClient, type FilmstripJob } from "./timelineMediaClient";

export interface TimelineMediaInputs {
  /** project.json reference → fetchable URL (LoadedEditorProject.mediaUrl). */
  mediaUrl: ((ref: string | null | undefined) => string | undefined) | null;
  /** Cloud media table (content hashes for the cache identity), when cloud-loaded. */
  cloud?: Pick<MediaUrls, "media" | "sources">;
  videoRef: string | null;
  /** project.duration (source seconds). */
  duration: number;
  /** Distinct voice-over file names the project references. */
  voiceFiles: readonly string[];
  devicePixelRatio: number;
  playing: boolean;
}

/** Retry cadence for a voice file whose URL is not resolvable yet (a fresh recording uploading). */
const VOICE_RETRY_MS = 2000;
const VOICE_MAX_ATTEMPTS = 30;
/** Thumbnail arrivals are published at most this often (one timeline redraw each). */
const PUBLISH_MS = 60;

interface VoiceEntry {
  identity: string;
  job: { cancel(): void } | null;
}

export class TimelineMediaStore {
  private client: TimelineMediaClient | null = null;
  private listeners = new Set<() => void>();
  private snapshot: TimelineMediaSnapshot = EMPTY_TIMELINE_MEDIA;
  private publishTimer: ReturnType<typeof setTimeout> | null = null;
  private inputs: TimelineMediaInputs | null = null;

  // filmstrip
  private filmIdentity = "";
  private filmJob: FilmstripJob | null = null;
  private filmTimes: number[] = [];
  private filmSlots: (ImageBitmap | null)[] = [];
  private shownBitmaps = new Set<ImageBitmap>();
  // recording audio
  private recIdentity = "";
  private recJob: { cancel(): void } | null = null;
  private recording: (PeakEnvelope | null)[] | null = null;
  // voice files
  private voiceEntries = new Map<string, VoiceEntry>();
  private voiceEnvelopes = new Map<string, PeakEnvelope | null>();
  private voiceAttempts = new Map<string, number>();
  private voiceRetry: ReturnType<typeof setTimeout> | null = null;

  /** Diagnostics for the perf harness (DEV): last job timings. */
  readonly stats = { filmstrip: null as null | { fromCache: boolean; ms: number; decoded: number }, recording: null as null | { fromCache: boolean; ms: number } };

  subscribe = (cb: () => void) => {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  };

  getSnapshot = () => this.snapshot;

  private ensureClient(): TimelineMediaClient {
    if (!this.client) this.client = new TimelineMediaClient();
    return this.client;
  }

  update(inputs: TimelineMediaInputs): void {
    this.inputs = inputs;
    const client = this.ensureClient();
    client.setPlaying(inputs.playing);
    this.updateFilmstrip(inputs, client);
    this.updateRecording(inputs, client);
    this.updateVoices(inputs, client);
  }

  private resolve(inputs: TimelineMediaInputs, ref: string | null): { url: string; identity: string; cacheKey: string | null } | null {
    if (!ref || !inputs.mediaUrl) return null;
    const raw = inputs.mediaUrl(ref);
    if (!raw) return null;
    const url = absoluteUrl(raw);
    const cacheKey = mediaIdentity(inputs.cloud, ref, url);
    return { url, cacheKey, identity: cacheKey ?? url };
  }

  // ── filmstrip ──

  private updateFilmstrip(inputs: TimelineMediaInputs, client: TimelineMediaClient): void {
    const media = this.resolve(inputs, inputs.videoRef);
    const heightPx = filmstripPixelHeight(inputs.devicePixelRatio);
    const identity = media && inputs.duration > 0 ? `${media.identity}|${inputs.duration}|${heightPx}` : "";
    if (identity === this.filmIdentity) return;
    this.filmIdentity = identity;
    this.filmJob?.cancel();
    this.filmJob = null;
    if (!media || !identity) {
      this.replaceThumbnails([], []);
      return;
    }
    const times = filmstripRequestTimes(inputs.duration, FILMSTRIP_TARGET_COUNT);
    // Keep the previous strip on screen until the new one's first frame lands (dpr change, re-open).
    let first = true;
    const slots: (ImageBitmap | null)[] = times.map(() => null);
    const job = client.filmstrip(
      { url: media.url, cacheKey: media.cacheKey, duration: inputs.duration, count: FILMSTRIP_TARGET_COUNT, heightPx },
      (indices, bitmap) => {
        if (this.filmJob !== job) return bitmap.close();
        for (const i of indices) if (i >= 0 && i < slots.length) slots[i] = bitmap;
        if (first) {
          first = false;
          this.replaceThumbnails(times, slots);
        }
        this.shownBitmaps.add(bitmap);
        this.schedulePublish();
      },
    );
    this.filmJob = job;
    void job.done.then((r) => {
      if (this.filmJob !== job) return;
      this.stats.filmstrip = r;
      // Nothing decoded (no video track / undecodable): drop the previous strip too.
      if (first) this.replaceThumbnails([], []);
      this.publishNow();
    });
  }

  private replaceThumbnails(times: number[], slots: (ImageBitmap | null)[]): void {
    const keep = new Set(slots.filter((b): b is ImageBitmap => b !== null));
    for (const b of this.shownBitmaps) if (!keep.has(b)) b.close();
    this.shownBitmaps = keep;
    this.filmTimes = times;
    this.filmSlots = slots;
    this.schedulePublish();
  }

  // ── recording waveform ──

  private updateRecording(inputs: TimelineMediaInputs, client: TimelineMediaClient): void {
    const media = this.resolve(inputs, inputs.videoRef);
    const identity = media ? media.identity : "";
    if (identity === this.recIdentity) return;
    this.recIdentity = identity;
    this.recJob?.cancel();
    this.recJob = null;
    this.recording = null;
    this.schedulePublish();
    if (!media) return;
    const job = client.envelope({ url: media.url, cacheKey: media.cacheKey, tracks: "all", gapless: false });
    this.recJob = job;
    void job.done.then((r) => {
      if (this.recJob !== job) return;
      this.recJob = null;
      this.stats.recording = r ? { fromCache: r.fromCache, ms: r.ms } : null;
      this.recording = r ? r.tracks : [];
      this.publishNow();
    });
  }

  // ── voice-over files ──

  private updateVoices(inputs: TimelineMediaInputs, client: TimelineMediaClient): void {
    const wanted = new Set(inputs.voiceFiles);
    for (const [name, entry] of this.voiceEntries) {
      if (wanted.has(name)) continue;
      entry.job?.cancel();
      this.voiceEntries.delete(name);
    }
    for (const name of [...this.voiceEnvelopes.keys()]) if (!wanted.has(name)) this.voiceEnvelopes.delete(name);
    for (const name of [...this.voiceAttempts.keys()]) if (!wanted.has(name)) this.voiceAttempts.delete(name);

    // A file that is not resolvable yet (a fresh take still uploading) or that
    // failed to decode is retried on a timer, a bounded number of times.
    const retryLater = (name: string) => {
      const attempts = (this.voiceAttempts.get(name) ?? 0) + 1;
      this.voiceAttempts.set(name, attempts);
      if (attempts < VOICE_MAX_ATTEMPTS && !this.voiceRetry) {
        this.voiceRetry = setTimeout(() => {
          this.voiceRetry = null;
          if (this.inputs && this.client) this.updateVoices(this.inputs, this.client);
        }, VOICE_RETRY_MS);
      }
    };

    for (const name of wanted) {
      const media = this.resolve(inputs, name);
      if (!media) {
        retryLater(name);
        continue;
      }
      const existing = this.voiceEntries.get(name);
      if (existing && existing.identity === media.identity) continue;
      if (!existing && this.voiceEnvelopes.get(name) === null && (this.voiceAttempts.get(name) ?? 0) >= VOICE_MAX_ATTEMPTS) continue;
      existing?.job?.cancel();
      const entry: VoiceEntry = { identity: media.identity, job: null };
      this.voiceEntries.set(name, entry);
      const job = client.envelope({ url: media.url, cacheKey: media.cacheKey, tracks: "first", gapless: true });
      entry.job = job;
      void job.done.then((r) => {
        if (this.voiceEntries.get(name) !== entry) return;
        entry.job = null;
        const env = r?.tracks[0] ?? null;
        this.voiceEnvelopes.set(name, env);
        if (!env) {
          // Missing / undecodable (the Mac: no file → no waveform). Forget the
          // entry so the retry timer asks again.
          this.voiceEntries.delete(name);
          retryLater(name);
        }
        this.publishNow();
      });
    }
  }

  // ── publishing ──

  private schedulePublish(): void {
    if (this.publishTimer) return;
    this.publishTimer = setTimeout(() => this.publishNow(), PUBLISH_MS);
  }

  private publishNow(): void {
    if (this.publishTimer) clearTimeout(this.publishTimer);
    this.publishTimer = null;
    const thumbnails: TimelineThumbnailImage[] = [];
    this.filmSlots.forEach((bitmap, i) => {
      if (bitmap) thumbnails.push({ time: this.filmTimes[i], image: bitmap, width: bitmap.width, height: bitmap.height });
    });
    this.snapshot = {
      version: this.snapshot.version + 1,
      thumbnails,
      recording: this.recording,
      voice: new Map(this.voiceEnvelopes),
    };
    for (const l of this.listeners) l();
  }

  /** Cancels everything and frees the bitmaps; a later `update` starts over. */
  dispose(): void {
    this.filmJob?.cancel();
    this.recJob?.cancel();
    for (const e of this.voiceEntries.values()) e.job?.cancel();
    if (this.publishTimer) clearTimeout(this.publishTimer);
    if (this.voiceRetry) clearTimeout(this.voiceRetry);
    this.publishTimer = null;
    this.voiceRetry = null;
    this.client?.dispose();
    this.client = null;
    for (const b of this.shownBitmaps) b.close();
    this.shownBitmaps.clear();
    this.filmIdentity = "";
    this.filmJob = null;
    this.filmTimes = [];
    this.filmSlots = [];
    this.recIdentity = "";
    this.recJob = null;
    this.recording = null;
    this.voiceEntries.clear();
    this.voiceEnvelopes.clear();
    this.voiceAttempts.clear();
    this.snapshot = { ...EMPTY_TIMELINE_MEDIA, version: this.snapshot.version + 1 };
    for (const l of this.listeners) l();
  }
}

function useDevicePixelRatio(): number {
  const [dpr, setDpr] = useState(() => (typeof window === "undefined" ? 1 : window.devicePixelRatio || 1));
  useEffect(() => {
    let mq: MediaQueryList | null = null;
    const listen = () => {
      mq?.removeEventListener("change", listen);
      setDpr(window.devicePixelRatio || 1);
      mq = window.matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
      mq.addEventListener("change", listen);
    };
    listen();
    return () => mq?.removeEventListener("change", listen);
  }, []);
  return dpr;
}

/**
 * The editor page's hook: decodes the open project's timeline media and
 * returns `timeline` with its assets + voice waveforms filled in.
 */
export function useTimelineMedia(
  timeline: TimelineSnapshot,
  project: Project | null | undefined,
  loaded: { mediaUrl(ref: string | null | undefined): string | undefined; cloud?: Pick<MediaUrls, "media" | "sources"> } | null,
  playing: boolean,
): TimelineSnapshot {
  const [store] = useState(() => new TimelineMediaStore());
  const dpr = useDevicePixelRatio();
  const videoRef = project?.videoURL ?? null;
  const duration = project?.duration ?? 0;
  const voiceKey = project ? [...new Set(project.voiceOverClips.map((c) => c.fileName))].join("\n") : "";

  useEffect(() => {
    store.update({
      mediaUrl: loaded ? (ref) => loaded.mediaUrl(ref) : null,
      cloud: loaded?.cloud,
      videoRef,
      duration,
      voiceFiles: voiceKey ? voiceKey.split("\n") : [],
      devicePixelRatio: dpr,
      playing,
    });
  }, [store, loaded, videoRef, duration, voiceKey, dpr, playing]);

  useEffect(() => () => store.dispose(), [store]);

  // DEV-only handle for the perf/screenshot harness.
  useEffect(() => {
    if (!import.meta.env.DEV || typeof window === "undefined") return;
    (window as unknown as { __timelineMedia?: TimelineMediaStore }).__timelineMedia = store;
    return () => {
      delete (window as unknown as { __timelineMedia?: TimelineMediaStore }).__timelineMedia;
    };
  }, [store]);

  const media = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  return useMemo(() => applyTimelineMedia(timeline, project, media), [timeline, project, media]);
}
