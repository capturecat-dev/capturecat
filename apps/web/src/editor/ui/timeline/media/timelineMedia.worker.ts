/// <reference lib="webworker" />
/**
 * Timeline media worker — decodes the VIDEO row's filmstrip thumbnails and
 * the waveform envelopes (recording + voice-over files) OFF the main thread,
 * with its OWN mediabunny inputs and WebCodecs decoders: nothing here touches
 * the render engine's demuxer/decoder (engine/worker.ts) or the playback
 * audio readers, so generating never stalls a frame the engine is waiting on.
 *
 * Jobs run one at a time (the filmstrip first — the client queues it first).
 * While the editor is playing (`pace`), decodes are spaced out so this worker
 * never competes with playback for the hardware decoder or a CPU core.
 *
 * Results are cached per media identity in IndexedDB (mediaCache.ts): WebP
 * thumbnails + their request times, and the per-track PeakEnvelopes.
 */
import {
  ALL_FORMATS,
  AudioSampleSink,
  BlobSource,
  CanvasSink,
  EncodedPacketSink,
  Input,
  UrlSource,
  type InputAudioTrack,
  type Source,
} from "mediabunny";

import { ENVELOPE_BLOCK_FRAMES, PeakEnvelopeBuilder, type PeakEnvelope } from "../../../core/audio/waveformPeaks";
import { filmstripFrameTime, filmstripRequestTimes } from "../../../core/time/filmstrip";
import { trackTimeline } from "../../../engine/audio/pcm";
import { readGapless } from "../../../engine/audio/projectAudio";
import { cacheGet, cachePut } from "./mediaCache";
import type { EnvelopeRequest, FilmstripRequest, MediaWorkerRequest, MediaWorkerResponse } from "./protocol";

declare const self: DedicatedWorkerGlobalScope;

/** Cache schema version — bump when the stored shape or the math changes. */
const CACHE_VERSION = 1;
/** Gap between thumbnail decodes while the editor plays (ms); idle decodes back-to-back. */
const PLAYING_GAP_MS = 60;
/** Audio: yield to the message loop (cancel / pace) every N decoded samples. */
const AUDIO_YIELD_EVERY = 64;

let playing = false;
const cancelled = new Set<number>();
let queue: Promise<void> = Promise.resolve();

const post = (msg: MediaWorkerResponse, transfer: Transferable[] = []) => self.postMessage(msg, transfer);
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

async function pace(): Promise<void> {
  await sleep(playing ? PLAYING_GAP_MS : 0);
}

async function sourceFor(url: string): Promise<Source> {
  if (url.startsWith("blob:") || url.startsWith("data:")) {
    const blob = await (await fetch(url)).blob();
    return new BlobSource(blob);
  }
  // Never retry forever (the default backoff does) — a dead URL fails the job.
  return new UrlSource(url, { getRetryDelay: (attempts) => (attempts < 2 ? 0.5 : null) });
}

// ── Filmstrip ──────────────────────────────────────────────────────────────

interface FilmstripCacheValue {
  times: number[];
  /** One encoded frame per distinct decode; `slots[i]` = index into `frames` for request i (−1 = none). */
  frames: Blob[];
  slots: number[];
}

async function filmstrip(req: FilmstripRequest): Promise<void> {
  const t0 = performance.now();
  const key = req.cacheKey ? `film:v${CACHE_VERSION}:${req.cacheKey}:${req.count}:${req.heightPx}:${req.duration}` : null;
  if (key) {
    const hit = await cacheGet<FilmstripCacheValue>(key);
    if (hit && hit.frames.length > 0) {
      for (let f = 0; f < hit.frames.length; f++) {
        if (cancelled.has(req.id)) return;
        const indices = hit.slots.flatMap((s, i) => (s === f ? [i] : []));
        const bitmap = await createImageBitmap(hit.frames[f]);
        post({ type: "thumb", id: req.id, indices, bitmap }, [bitmap]);
      }
      post({ type: "filmstripDone", id: req.id, fromCache: true, ms: performance.now() - t0, decoded: 0 });
      return;
    }
  }

  const times = filmstripRequestTimes(req.duration, req.count);
  if (times.length === 0) {
    post({ type: "filmstripDone", id: req.id, fromCache: false, ms: performance.now() - t0, decoded: 0 });
    return;
  }
  const input = new Input({ formats: ALL_FORMATS, source: await sourceFor(req.url) });
  try {
    const track = await input.getPrimaryVideoTrack();
    if (!track) throw new Error("no video track");
    if (!(await track.canDecode())) throw new Error("this browser cannot decode the recording's video");

    // Frame index from packet METADATA (no sample data read): every PTS + the sync frames.
    const packets = new EncodedPacketSink(track);
    const pts: number[] = [];
    const keyPts: number[] = [];
    for await (const p of packets.packets(undefined, undefined, { metadataOnly: true })) {
      pts.push(p.timestamp);
      if (p.type === "key") keyPts.push(p.timestamp);
      if (cancelled.has(req.id)) return;
    }
    pts.sort((a, b) => a - b);
    keyPts.sort((a, b) => a - b);

    // Distinct decode targets, ascending (keyframe snapping often shares one).
    const targets = times.map((t) => filmstripFrameTime(t, pts, keyPts));
    const distinct = [...new Set(targets.filter((t) => Number.isFinite(t)))].sort((a, b) => a - b);
    const sink = new CanvasSink(track, { height: req.heightPx });
    const frames: Blob[] = [];
    const slots = new Array<number>(times.length).fill(-1);
    let decoded = 0;
    for (const target of distinct) {
      if (cancelled.has(req.id)) return;
      await pace();
      const wrapped = await sink.getCanvas(target);
      if (!wrapped) continue;
      decoded++;
      const canvas = wrapped.canvas as OffscreenCanvas;
      const indices = targets.flatMap((t, i) => (t === target ? [i] : []));
      const bitmap = await createImageBitmap(canvas);
      post({ type: "thumb", id: req.id, indices, bitmap }, [bitmap]);
      if (key) {
        const blob = await canvas.convertToBlob({ type: "image/webp", quality: 0.9 }).catch(() => null);
        if (blob) {
          for (const i of indices) slots[i] = frames.length;
          frames.push(blob);
        }
      }
    }
    post({ type: "filmstripDone", id: req.id, fromCache: false, ms: performance.now() - t0, decoded });
    if (key && frames.length > 0) await cachePut(key, { times, frames, slots } satisfies FilmstripCacheValue);
  } finally {
    input.dispose();
  }
}

// ── Waveform envelopes ─────────────────────────────────────────────────────

interface EnvelopeCacheValue {
  tracks: (PeakEnvelope | null)[];
}

async function decodeEnvelope(
  track: InputAudioTrack,
  gapless: { priming: number; validFrames: number } | null,
  id: number,
): Promise<PeakEnvelope | null> {
  if (!(await track.canDecode())) return null;
  const rate = track.sampleRate;
  const { duration, priming } = await trackTimeline(track, gapless);
  const totalFrames = Math.round(duration * rate);
  const builder = new PeakEnvelopeBuilder(rate, track.numberOfChannels, ENVELOPE_BLOCK_FRAMES, totalFrames);
  const sink = new AudioSampleSink(track);
  let planes: Float32Array[] = [];
  let n = 0;
  for await (const sample of sink.samples()) {
    try {
      const frames = sample.numberOfFrames;
      const channels = sample.numberOfChannels;
      if (planes.length !== channels || planes[0].length < frames) {
        planes = Array.from({ length: channels }, () => new Float32Array(Math.max(frames, 4096)));
      }
      for (let c = 0; c < channels; c++) sample.copyTo(planes[c], { planeIndex: c, format: "f32-planar" });
      // Same placement as the playback reader (engine/audio/pcm.ts append).
      const start = Math.round(sample.timestamp * rate) - priming;
      builder.pushFloat(start, frames, planes);
    } finally {
      sample.close();
    }
    if (++n % AUDIO_YIELD_EVERY === 0) {
      await pace();
      if (cancelled.has(id)) return null;
    }
  }
  return builder.finish(totalFrames);
}

async function envelope(req: EnvelopeRequest): Promise<void> {
  const t0 = performance.now();
  const key = req.cacheKey ? `env:v${CACHE_VERSION}:${req.cacheKey}:${req.tracks}:${req.gapless ? 1 : 0}:${ENVELOPE_BLOCK_FRAMES}` : null;
  if (key) {
    const hit = await cacheGet<EnvelopeCacheValue>(key);
    if (hit) {
      post({ type: "envelope", id: req.id, tracks: hit.tracks, fromCache: true, ms: performance.now() - t0 });
      return;
    }
  }
  const input = new Input({ formats: ALL_FORMATS, source: await sourceFor(req.url) });
  try {
    const all = await input.getAudioTracks();
    const tracks = req.tracks === "first" ? all.slice(0, 1) : all;
    const gapless = req.gapless && !req.url.startsWith("data:") ? await readGapless(req.url) : null;
    const out: (PeakEnvelope | null)[] = [];
    for (const track of tracks) {
      if (cancelled.has(req.id)) return;
      out.push(await decodeEnvelope(track, gapless, req.id).catch(() => null));
    }
    if (cancelled.has(req.id)) return;
    post({ type: "envelope", id: req.id, tracks: out, fromCache: false, ms: performance.now() - t0 });
    if (key) await cachePut(key, { tracks: out } satisfies EnvelopeCacheValue);
  } finally {
    input.dispose();
  }
}

// ── Message loop ───────────────────────────────────────────────────────────

self.onmessage = (e: MessageEvent<MediaWorkerRequest>) => {
  const msg = e.data;
  switch (msg.type) {
    case "cancel":
      cancelled.add(msg.id);
      return;
    case "pace":
      playing = msg.playing;
      return;
    case "filmstrip":
    case "envelope": {
      const run = msg.type === "filmstrip" ? () => filmstrip(msg) : () => envelope(msg);
      queue = queue.then(async () => {
        if (cancelled.has(msg.id)) return;
        try {
          await run();
        } catch (error) {
          post({ type: "error", id: msg.id, message: error instanceof Error ? error.message : String(error) });
        } finally {
          cancelled.delete(msg.id);
        }
      });
      return;
    }
  }
};
