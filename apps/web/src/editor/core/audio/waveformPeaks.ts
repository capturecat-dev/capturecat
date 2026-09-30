/**
 * Timeline waveform peaks — the port of the Mac's `WaveformGenerator`
 * (Services/WaveformGenerator.swift) and the two call sites that feed the
 * timeline (Views/Editor/TimelineViewController.swift):
 *
 *   loadAudioSamples    the recording's VIDEO-row waveform: 180 buckets over
 *                       the trim window (source time), every audio track
 *                       generated separately and merged with an element-wise
 *                       max (system audio = track 0, mic = track 1).
 *   loadVoiceWaveforms  each voice-over clip's waveform: 72 buckets over the
 *                       clip's visible window of its file,
 *                       [sourceStartTime, sourceStartTime + max(0.1, duration)].
 *
 * The generator reads the track through AVAssetReader as 16-bit INTERLEAVED
 * LPCM at the native rate and channel count, splits the interleaved sample
 * stream into `floor(total / sampleCount)`-sample buckets (the tail remainder
 * is dropped; buckets past the end are 0), takes max |s16| per bucket over
 * Int16.max, then normalises to the loudest bucket when it is above 0.01 —
 * all in Swift `Float` (f32) arithmetic, reproduced here with Math.fround.
 *
 * Locked to the REAL Swift by `vectors/golden/waveformPeaks.json`
 * (apps/web/scripts/waveform-golden/record.swift compiles the app's own
 * WaveformGenerator.swift and records it over synthetic WAVs).
 *
 * Two facts measured from AVFoundation by that driver's probes:
 *  - f32 → s16 (AVAssetReader's converter): ×32768, round half AWAY from
 *    zero, clamp to [−32768, 32767] (so −1.0 → −32768, +1.0 → 32767).
 *  - `reader.timeRange` (CMTime at timescale 600, TRUNCATED from seconds)
 *    selects frames [floor(start·rate), ceil(end·rate)), clamped to the file.
 *
 * One deliberate divergence: the Swift bucket loop computes `-v` on an Int16
 * and TRAPS on −32768 (a full-scale negative sample crashes the Mac app —
 * verified with the recorder driver, exit 133). The port saturates it to
 * 32767 instead.
 *
 * The web decodes each media file ONCE into a `PeakEnvelope` (max |s16| over
 * all channels per `blockFrames` frames) that is cached per file, so a trim
 * or a voice clip resize re-buckets instantly without decoding again.
 * `envelopePeaks` over an envelope with blockFrames = 1 is exactly
 * `waveformPeaks` for mono audio; coarser blocks can widen a bucket's window
 * by < 1 block at each edge.
 */
import { effectiveTrimEnd, effectiveTrimStart, type TrimProject } from "../time/clips";

/** TimelineViewController.loadAudioSamples — `let sampleCount = 180`. */
export const RECORDING_WAVEFORM_BUCKETS = 180;
/** TimelineViewController.loadVoiceWaveforms — `sampleCount: 72`. */
export const VOICE_WAVEFORM_BUCKETS = 72;
/** loadVoiceWaveforms — `duration: max(0.1, clip.duration)`. */
export const VOICE_WAVEFORM_MIN_DURATION = 0.1;

const INT16_MAX = 32767;
/** Swift `Float` literal 0.01 (`peak > 0.01` compares in f32). */
const NORMALIZE_THRESHOLD = Math.fround(0.01);
const f32 = Math.fround;

/** AVAssetReader's f32 → s16 conversion (measured): ×32768, ties away from zero, clamped. */
export function floatToInt16(x: number): number {
  if (!(x === x)) return 0; // NaN
  const v = x * 32768;
  const r = v < 0 ? -Math.round(-v) : Math.round(v); // Math.round(|v|) = ties away for |v|
  return r > 32767 ? 32767 : r < -32768 ? -32768 : r;
}

/** |s16| as the bucket loop compares it (−32768 saturates; Swift traps there). */
export function int16Magnitude(v: number): number {
  const a = v < 0 ? -v : v;
  return a > INT16_MAX ? INT16_MAX : a;
}

/** `CMTime(seconds:preferredTimescale: 600).value` — truncates toward zero. */
export function cmTime600(seconds: number): number {
  return Math.trunc(seconds * 600);
}

/**
 * The frames an AVAssetReader with `timeRange = CMTimeRange(start:duration:)`
 * (both CMTime(seconds:preferredTimescale: 600)) returns from a track of
 * `totalFrames` frames: [floor(start·rate), ceil((start+duration)·rate)),
 * clamped to [0, totalFrames]. No range = the whole track.
 */
export function readerFrameWindow(
  range: { start: number; duration: number } | null | undefined,
  sampleRate: number,
  totalFrames: number,
): [number, number] {
  if (!range) return [0, totalFrames];
  const startValue = cmTime600(range.start);
  const endValue = startValue + cmTime600(range.duration);
  // value · rate is an exact integer for any real rate; floor/ceil of the
  // exact rational (value · rate) / 600.
  const f0 = Math.floor((startValue * sampleRate) / 600);
  const f1 = Math.ceil((endValue * sampleRate) / 600);
  const a = Math.min(Math.max(f0, 0), totalFrames);
  const b = Math.min(Math.max(f1, a), totalFrames);
  return [a, b];
}

/**
 * The generator's bucket loop + peak normalisation over the magnitudes of an
 * interleaved s16 stream (`int16Magnitude` of each sample, in stream order).
 * Returns [] for an empty stream (Swift: `guard !allSamples.isEmpty`).
 */
export function peakBuckets(magnitudes: ArrayLike<number>, sampleCount: number): Float32Array {
  const total = magnitudes.length;
  if (total === 0 || !(sampleCount > 0)) return new Float32Array(0);
  const perBucket = Math.max(1, Math.floor(total / sampleCount));
  const out = new Float32Array(sampleCount);
  for (let i = 0; i < sampleCount; i++) {
    const start = i * perBucket;
    if (start >= total) break; // `buckets.append(0)`
    const end = Math.min(start + perBucket, total);
    let maxVal = 0;
    for (let j = start; j < end; j++) {
      const a = magnitudes[j];
      if (a > maxVal) maxVal = a;
    }
    out[i] = maxVal / INT16_MAX; // Float(maxVal) / Float(Int16.max), stored as f32
  }
  return normalize(out);
}

/** `buckets.max()`, then `min(1, b · (1 / peak))` when peak > 0.01 — f32 throughout. */
function normalize(buckets: Float32Array): Float32Array {
  let peak = 0;
  let any = false;
  for (let i = 0; i < buckets.length; i++) {
    if (!any || buckets[i] > peak) peak = buckets[i];
    any = true;
  }
  if (!(peak > NORMALIZE_THRESHOLD)) return buckets;
  const scale = f32(1 / peak);
  for (let i = 0; i < buckets.length; i++) {
    const v = f32(buckets[i] * scale);
    buckets[i] = v > 1 ? 1 : v; // Swift min(1.0, v)
  }
  return buckets;
}

/**
 * `WaveformGenerator.generate` over already-decoded PCM: interleaved s16
 * samples of ONE track, the reader's time range, the bucket count.
 */
export function waveformPeaks(
  interleaved: ArrayLike<number>,
  channels: number,
  sampleRate: number,
  sampleCount: number,
  range?: { start: number; duration: number } | null,
): Float32Array {
  const frames = Math.floor(interleaved.length / Math.max(1, channels));
  const [f0, f1] = readerFrameWindow(range, sampleRate, frames);
  const mags = new Uint16Array((f1 - f0) * channels);
  for (let i = 0; i < mags.length; i++) mags[i] = int16Magnitude(interleaved[f0 * channels + i]);
  return peakBuckets(mags, sampleCount);
}

/**
 * loadAudioSamples' merge: `merged[i] = max(merged[i], samples[i])` over the
 * tracks that produced samples (empty ones are skipped), sized
 * `sampleCount`. Returns [] when no track produced anything — the Mac's
 * `audioSamples` stays empty then (and the row shows no waveform).
 */
export function mergeTrackPeaks(tracks: readonly ArrayLike<number>[], sampleCount: number): Float32Array {
  const live = tracks.filter((t) => t.length > 0);
  if (live.length === 0) return new Float32Array(0);
  const merged = new Float32Array(sampleCount);
  for (const samples of live) {
    const n = Math.min(merged.length, samples.length);
    for (let i = 0; i < n; i++) if (samples[i] > merged[i]) merged[i] = samples[i];
  }
  return merged;
}

// ── Cached envelope (the web's decode-once representation) ─────────────────

/** Frames per envelope block: 32 frames ≈ 0.67 ms at 48 kHz (≈ 1.8 MB per 10 min track). */
export const ENVELOPE_BLOCK_FRAMES = 32;

export interface PeakEnvelope {
  sampleRate: number;
  channels: number;
  blockFrames: number;
  /** Track length in frames on its timeline (frame 0 = media time 0). */
  frameCount: number;
  /** max |s16| over every channel of each block of `blockFrames` frames. */
  peaks: Uint16Array;
}

/**
 * Streams decoded PCM (placed by absolute frame index on the track timeline)
 * into a PeakEnvelope. Overlaps keep the max; gaps stay silent.
 */
export class PeakEnvelopeBuilder {
  private peaks: Uint16Array;
  private frames = 0;

  constructor(
    readonly sampleRate: number,
    readonly channels: number,
    readonly blockFrames = ENVELOPE_BLOCK_FRAMES,
    expectedFrames = 0,
  ) {
    this.peaks = new Uint16Array(Math.max(16, Math.ceil(Math.max(0, expectedFrames) / blockFrames) + 1));
  }

  private ensure(blocks: number): void {
    if (blocks <= this.peaks.length) return;
    const next = new Uint16Array(Math.max(blocks, this.peaks.length * 2));
    next.set(this.peaks);
    this.peaks = next;
  }

  /**
   * Adds `frameCount` planar f32 frames (one plane per channel) starting at
   * absolute frame `startFrame`, converted to s16 like AVAssetReader.
   */
  pushFloat(startFrame: number, frameCount: number, planes: readonly Float32Array[]): void {
    const channels = Math.min(this.channels, planes.length);
    let from = 0;
    if (startFrame < 0) from = -startFrame; // before media time 0 (priming) — never read
    if (from >= frameCount) return;
    const lastFrame = startFrame + frameCount;
    this.ensure(Math.ceil(lastFrame / this.blockFrames) + 1);
    const B = this.blockFrames;
    const peaks = this.peaks;
    for (let i = from; i < frameCount; i++) {
      let m = 0;
      for (let c = 0; c < channels; c++) {
        const a = int16Magnitude(floatToInt16(planes[c][i]));
        if (a > m) m = a;
      }
      const block = ((startFrame + i) / B) | 0;
      if (m > peaks[block]) peaks[block] = m;
    }
    if (lastFrame > this.frames) this.frames = lastFrame;
  }

  /** Same, for interleaved s16 input (tests / already-integer sources). */
  pushInt16Interleaved(startFrame: number, interleaved: ArrayLike<number>): void {
    const ch = this.channels;
    const frameCount = Math.floor(interleaved.length / ch);
    const lastFrame = startFrame + frameCount;
    this.ensure(Math.ceil(lastFrame / this.blockFrames) + 1);
    for (let i = Math.max(0, -startFrame); i < frameCount; i++) {
      let m = 0;
      for (let c = 0; c < ch; c++) {
        const a = int16Magnitude(interleaved[i * ch + c]);
        if (a > m) m = a;
      }
      const block = Math.floor((startFrame + i) / this.blockFrames);
      if (m > this.peaks[block]) this.peaks[block] = m;
    }
    if (lastFrame > this.frames) this.frames = lastFrame;
  }

  /** Clamp the length to the track's own duration (frames beyond are dropped). */
  finish(frameCount = this.frames): PeakEnvelope {
    const frames = Math.max(0, Math.min(frameCount, this.frames));
    const blocks = Math.ceil(frames / this.blockFrames);
    return {
      sampleRate: this.sampleRate,
      channels: this.channels,
      blockFrames: this.blockFrames,
      frameCount: frames,
      peaks: this.peaks.slice(0, blocks),
    };
  }
}

/**
 * `WaveformGenerator.generate` evaluated on a cached envelope: the same
 * reader window, bucket split (over the INTERLEAVED sample count, so the
 * bucket width follows the channel count exactly like the Mac) and f32
 * normalisation; each bucket's max is taken over the envelope blocks its
 * frames touch.
 */
export function envelopePeaks(
  env: PeakEnvelope,
  sampleCount: number,
  range?: { start: number; duration: number } | null,
): Float32Array {
  const ch = Math.max(1, env.channels);
  const [f0, f1] = readerFrameWindow(range, env.sampleRate, env.frameCount);
  const total = (f1 - f0) * ch;
  if (total === 0 || !(sampleCount > 0)) return new Float32Array(0);
  const perBucket = Math.max(1, Math.floor(total / sampleCount));
  const out = new Float32Array(sampleCount);
  const B = env.blockFrames;
  const peaks = env.peaks;
  for (let i = 0; i < sampleCount; i++) {
    const start = i * perBucket;
    if (start >= total) break;
    const end = Math.min(start + perBucket, total);
    // Interleaved [start, end) → frames [f0 + ⌊start/ch⌋, f0 + ⌈end/ch⌉) → blocks.
    const b0 = Math.floor((f0 + Math.floor(start / ch)) / B);
    const b1 = Math.floor((f0 + Math.ceil(end / ch) - 1) / B);
    let maxVal = 0;
    for (let b = b0; b <= b1 && b < peaks.length; b++) if (peaks[b] > maxVal) maxVal = peaks[b];
    out[i] = maxVal / INT16_MAX;
  }
  return normalize(out);
}

/**
 * loadAudioSamples on cached envelopes: the trim window when it is non-empty
 * (else the whole file), 180 buckets per track, merged.
 */
export function recordingWaveform(project: TrimProject, tracks: readonly PeakEnvelope[]): Float32Array {
  const trimStart = effectiveTrimStart(project);
  const trimDuration = Math.max(0, effectiveTrimEnd(project) - trimStart);
  const range = trimDuration > 0 ? { start: trimStart, duration: trimDuration } : null;
  return mergeTrackPeaks(
    tracks.map((env) => envelopePeaks(env, RECORDING_WAVEFORM_BUCKETS, range)),
    RECORDING_WAVEFORM_BUCKETS,
  );
}

/** loadVoiceWaveforms for one clip on its file's (first track's) envelope. */
export function voiceClipWaveform(
  clip: { sourceStartTime: number; duration: number },
  env: PeakEnvelope,
): Float32Array {
  return envelopePeaks(env, VOICE_WAVEFORM_BUCKETS, {
    start: clip.sourceStartTime,
    duration: Math.max(VOICE_WAVEFORM_MIN_DURATION, clip.duration),
  });
}

/** TimelineVoiceAssets.signature(for:) — the identity the Mac reloads a clip's waveform on. */
export function voiceWaveformSignature(clip: {
  fileName: string;
  sourceStartTime: number;
  duration: number;
  sourceDuration: number;
  gain: number;
}): string {
  return `${clip.fileName}:${clip.sourceStartTime}:${clip.duration}:${clip.sourceDuration}:${clip.gain}`;
}
