/**
 * Synthesized click + keyboard sounds — ports of
 * `Services/ClickSoundPlayer.swift` (`tickSamples(style:)`) and
 * `Services/KeySoundPlayer.swift` (`variation(timestamp:category:)`,
 * `strokeSamples(style:pitch:)`, `renderTrackWAV(events:duration:style:)`).
 *
 * The Mac feeds BOTH its live preview and its exporter from these exact
 * sample sets (the exporter writes them to 16-bit WAVs and inserts them into
 * the audio composition), so the web does the same: one synthesis, used by
 * playback and export.
 *
 * Swift semantics reproduced: Double math in Swift's evaluation order,
 * `Float(...)` narrowing (Math.fround), UInt32 xorshift noise, UInt64
 * wrapping multiplies (BigInt), Float accumulation + clamp in the key track,
 * and the 16-bit PCM WAV round trip the exporter's composition reads back.
 *
 * Locked to Swift by the `audioSounds` golden vectors
 * (`CaptureCat --web-audio-fixtures`, see core/vectors/audio.test.ts).
 */
import type { ClickSoundStyle, KeySoundStyle, KeystrokeCategory } from "../model/enums";
import { srounded } from "../math/swift";

/** `ClickSoundPlayer.sampleRate` / `KeySoundPlayer.sampleRate`. */
export const SOUND_SAMPLE_RATE = 48_000;
/** `ClickSoundPlayer.tickDuration`. */
export const TICK_DURATION = 0.07;
/** `KeySoundPlayer.strokeDuration`. */
export const STROKE_DURATION = 0.06;
/** `KeySoundPlayer.minInterval` — strokes closer than this merge. */
export const KEY_MIN_INTERVAL = 0.008;

const PI = Math.PI;

function xorshift32(seed: number): number {
  seed = (seed ^ (seed << 13)) >>> 0;
  seed = (seed ^ (seed >>> 17)) >>> 0;
  seed = (seed ^ (seed << 5)) >>> 0;
  return seed;
}

const tickCache = new Map<string, Float32Array>();

/** `ClickSoundPlayer.tickSamples(style:)` — unit-level mono tick at 48 kHz. */
export function tickSamples(style: ClickSoundStyle): Float32Array {
  const cached = tickCache.get(style);
  if (cached) return cached;
  const count = Math.trunc(SOUND_SAMPLE_RATE * TICK_DURATION);
  const samples = new Float32Array(count);
  let seed = 0x9e3779b9 >>> 0;
  for (let i = 0; i < count; i++) {
    const t = i / SOUND_SAMPLE_RATE;
    let body: number;
    let noiseAmp: number;
    switch (style) {
      case "Soft Tick":
        body = Math.exp(-t * 180) * (0.6 * Math.sin(2 * PI * 2600 * t) + 0.25 * Math.sin(2 * PI * 1300 * t));
        noiseAmp = 0.12 * Math.exp(-t * 420);
        break;
      case "Clicky":
        body = Math.exp(-t * 280) * (0.7 * Math.sin(2 * PI * 3600 * t) + 0.2 * Math.sin(2 * PI * 1800 * t));
        noiseAmp = 0.22 * Math.exp(-t * 650);
        break;
      case "Deep":
        body = Math.exp(-t * 110) * (0.7 * Math.sin(2 * PI * 750 * t) + 0.25 * Math.sin(2 * PI * 380 * t));
        noiseAmp = 0.08 * Math.exp(-t * 300);
        break;
      case "Pop": {
        // Downward pitch sweep 1200→300 Hz — a rounded "pop".
        const phase = 2 * PI * (1200 * t - 6400 * t * t);
        body = Math.exp(-t * 90) * 0.8 * Math.sin(phase);
        noiseAmp = 0.05 * Math.exp(-t * 250);
        break;
      }
      default:
        body = 0;
        noiseAmp = 0;
    }
    seed = xorshift32(seed);
    const noise = ((seed % 2000) / 1000 - 1) * noiseAmp;
    samples[i] = Math.max(-1, Math.min(1, body + noise));
  }
  tickCache.set(style, samples);
  return samples;
}

const U64 = (1n << 64n) - 1n;

/**
 * `KeySoundPlayer.variation(timestamp:category:)` — deterministic
 * (pitch, level) per keystroke, hashed from the millisecond timestamp.
 */
export function keyVariation(timestamp: number, category: KeystrokeCategory): { pitch: number; level: number } {
  // UInt64(bitPattern: Int64((timestamp * 1000).rounded()))
  let seed = BigInt.asUintN(64, BigInt(srounded(timestamp * 1000)));
  seed ^= 0x9e3779b97f4a7c15n;
  seed = (seed * 0xbf58476d1ce4e5b9n) & U64;
  seed ^= seed >> 27n;
  const u1 = Number(seed % 10_000n) / 10_000;
  seed = (seed * 0x94d049bb133111ebn) & U64;
  seed ^= seed >> 31n;
  const u2 = Number(seed % 10_000n) / 10_000;

  let pitch = 0.94 + u1 * 0.12;
  let level = 0.85 + u2 * 0.3;
  switch (category) {
    case "space":
    case "return":
      pitch *= 0.85;
      level *= 1.15;
      break;
    case "modifier":
      level *= 0.6;
      break;
    case "scroll":
      level = 0;
      break;
    default:
      break;
  }
  return { pitch, level };
}

/** `KeySoundPlayer.strokeSamples(style:pitch:)` — one keystroke, unit level. */
export function strokeSamples(style: KeySoundStyle, pitch: number): Float32Array {
  const count = Math.trunc(SOUND_SAMPLE_RATE * STROKE_DURATION);
  const samples = new Float32Array(count);
  let seed = 0x5f3759df >>> 0;
  for (let i = 0; i < count; i++) {
    const t = i / SOUND_SAMPLE_RATE;
    let body: number;
    let noiseAmp: number;
    switch (style) {
      case "Thock":
        body = Math.exp(-t * 140) * (0.7 * Math.sin(2 * PI * 620 * pitch * t) + 0.25 * Math.sin(2 * PI * 310 * pitch * t));
        noiseAmp = 0.1 * Math.exp(-t * 380);
        break;
      case "Clacky":
        body = Math.exp(-t * 240) * (0.55 * Math.sin(2 * PI * 2400 * pitch * t) + 0.3 * Math.sin(2 * PI * 1150 * pitch * t));
        noiseAmp = 0.25 * Math.exp(-t * 620);
        break;
      case "Soft":
        body = Math.exp(-t * 200) * (0.4 * Math.sin(2 * PI * 900 * pitch * t) + 0.2 * Math.sin(2 * PI * 450 * pitch * t));
        noiseAmp = 0.16 * Math.exp(-t * 300);
        break;
      case "Cream":
        body = Math.exp(-t * 120) * (0.65 * Math.sin(2 * PI * 480 * pitch * t) + 0.3 * Math.sin(2 * PI * 240 * pitch * t));
        noiseAmp = 0.07 * Math.exp(-t * 340);
        break;
      case "Blue Click":
        body = Math.exp(-t * 320) * (0.5 * Math.sin(2 * PI * 3200 * pitch * t) + 0.3 * Math.sin(2 * PI * 1600 * pitch * t));
        noiseAmp = 0.38 * Math.exp(-t * 900);
        break;
      case "Typewriter":
        body =
          Math.exp(-t * 170) *
          (0.35 * Math.sin(2 * PI * 1800 * pitch * t) +
            0.3 * Math.sin(2 * PI * 2700 * pitch * t) +
            0.25 * Math.sin(2 * PI * 900 * pitch * t));
        noiseAmp = 0.4 * Math.exp(-t * 480);
        break;
      case "Membrane":
        body = Math.exp(-t * 260) * (0.35 * Math.sin(2 * PI * 520 * pitch * t) + 0.2 * Math.sin(2 * PI * 260 * pitch * t));
        noiseAmp = 0.12 * Math.exp(-t * 420);
        break;
      default:
        body = 0;
        noiseAmp = 0;
    }
    seed = xorshift32(seed);
    const noise = ((seed % 2000) / 1000 - 1) * noiseAmp;
    samples[i] = Math.max(-1, Math.min(1, body + noise));
  }
  return samples;
}

/**
 * The 16-bit PCM WAV round trip (`AVAudioFile` write → composition read):
 * float → Int16 (×32768, round to nearest, saturate) → float (÷32768).
 */
export function pcm16RoundTrip(x: number): number {
  const v = Math.round(x * 32768);
  return (v > 32767 ? 32767 : v < -32768 ? -32768 : v) / 32768;
}

/** The tick as the exporter's composition reads it back (16-bit WAV). */
export function tickTrackSamples(style: ClickSoundStyle): Float32Array {
  const key = `wav:${style}`;
  const cached = tickCache.get(key);
  if (cached) return cached;
  const src = tickSamples(style);
  const out = new Float32Array(src.length);
  for (let i = 0; i < src.length; i++) out[i] = pcm16RoundTrip(src[i]);
  tickCache.set(key, out);
  return out;
}

/** One key-track event: OUTPUT time + the SOURCE timestamp that seeds its variation. */
export interface KeyCue {
  outputTime: number;
  seedTimestamp: number;
  category: KeystrokeCategory;
}

/** A keystroke the density filter kept, with its synthesized samples. */
interface PlacedStroke {
  start: number;
  level: number;
  samples: Float32Array;
}

/**
 * `KeySoundPlayer.renderTrackWAV(events:duration:style:)` as a windowed
 * renderer: the whole mono track is `frameCount` samples at 48 kHz; `render`
 * produces any window of it bit-identically to rendering the full track
 * (each sample accumulates its strokes in the same order with the same Float
 * clamp), then applies the 16-bit WAV round trip.
 */
export class KeyTrack {
  readonly frameCount: number;
  private readonly strokes: PlacedStroke[] = [];
  private readonly strokeCache = new Map<number, Float32Array>();

  constructor(events: readonly KeyCue[], duration: number, style: KeySoundStyle) {
    this.frameCount = Math.max(1, Math.trunc((duration + STROKE_DURATION) * SOUND_SAMPLE_RATE));
    // Swift `sorted(by:)` on outputTime; stable here (ties are merged by the
    // density floor below, so only the survivor's seed could differ).
    const sorted = events
      .map((e, i) => ({ e, i }))
      .sort((a, b) => a.e.outputTime - b.e.outputTime || a.i - b.i)
      .map((x) => x.e);
    let lastTime = -Infinity;
    for (const event of sorted) {
      if (!(event.outputTime - lastTime >= KEY_MIN_INTERVAL)) continue;
      lastTime = event.outputTime;
      const v = keyVariation(event.seedTimestamp, event.category);
      const start = Math.trunc(event.outputTime * SOUND_SAMPLE_RATE);
      if (!(start >= 0)) continue;
      let samples = this.strokeCache.get(v.pitch);
      if (!samples) {
        samples = strokeSamples(style, v.pitch);
        this.strokeCache.set(v.pitch, samples);
      }
      this.strokes.push({ start, level: Math.fround(v.level), samples });
    }
  }

  get strokeCount(): number {
    return this.strokes.length;
  }

  /** Mono samples [start, start + count) of the WAV as read back (16-bit). */
  render(start: number, count: number): Float32Array {
    const out = new Float32Array(count);
    const end = Math.min(start + count, this.frameCount);
    if (end <= start) return out;
    const strokeLen = Math.trunc(SOUND_SAMPLE_RATE * STROKE_DURATION);
    // Strokes are sorted by start; binary-search the first that can reach `start`.
    let lo = 0;
    let hi = this.strokes.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.strokes[mid].start + strokeLen <= start) lo = mid + 1;
      else hi = mid;
    }
    for (let k = lo; k < this.strokes.length; k++) {
      const s = this.strokes[k];
      if (s.start >= end) break;
      const from = Math.max(start, s.start);
      const to = Math.min(end, s.start + s.samples.length);
      for (let idx = from; idx < to; idx++) {
        const o = idx - start;
        const add = Math.fround(s.samples[idx - s.start] * s.level);
        const sum = Math.fround(out[o] + add);
        out[o] = sum > 1 ? 1 : sum < -1 ? -1 : sum;
      }
    }
    for (let i = 0; i < end - start; i++) out[i] = pcm16RoundTrip(out[i]);
    return out;
  }
}
