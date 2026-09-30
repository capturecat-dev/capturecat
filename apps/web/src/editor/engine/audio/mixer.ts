/**
 * Renders an `AudioMixPlan` (core/audio/mixPlan.ts) to 48 kHz stereo — the
 * web twin of `AVAssetReaderAudioMixOutput` reading the Mac's prepared
 * composition. Any window [start, start + count) of OUTPUT frames renders
 * identically however it is chunked, so playback (small chunks ahead of the
 * speakers) and export (1 s chunks into the AAC encoder) are the same audio.
 *
 * Summation follows the composition's track order (recorded tracks, voice
 * overs, clicks, keys), each × its Float mix volume, in Float32. Mono
 * sources feed both channels at unit gain. No clamp here — the exporter
 * saturates to the Int16 range the Mac's reader hands its AAC writer.
 */
import type { AudioMixPlan, Edit } from "../../core/audio/mixPlan";
import { KeyTrack, tickTrackSamples } from "../../core/audio/sounds";
import type { PcmTrackReader } from "./pcm";
import { WsolaEdit } from "./wsola";

export interface MixSources {
  /** Readers aligned with `plan.recording.tracks` (null = undecodable). */
  recording: (PcmTrackReader | null)[];
  /** fileName → voice-over reader. */
  voices: Map<string, PcmTrackReader>;
}

function overlap(e: Edit, start: number, end: number): [number, number] | null {
  const a = Math.max(start, e.start);
  const b = Math.min(end, e.start + e.dur);
  return b > a ? [a, b] : null;
}

export class AudioMixRenderer {
  private stretchers = new Map<string, WsolaEdit>();
  private keyTrack: KeyTrack | null = null;

  constructor(
    readonly plan: AudioMixPlan,
    private readonly sources: MixSources,
  ) {}

  get endFrame(): number {
    return this.plan.endFrame;
  }

  async render(start: number, count: number): Promise<[Float32Array, Float32Array]> {
    const L = new Float32Array(count);
    const R = new Float32Array(count);
    const end = Math.min(start + count, this.plan.endFrame);
    if (end <= start) return [L, R];
    const plan = this.plan;
    const addStereo = (l: Float32Array, r: Float32Array, at: number, gain: number) => {
      const o = at - start;
      for (let i = 0; i < l.length; i++) {
        L[o + i] += l[i] * gain;
        R[o + i] += r[i] * gain;
      }
    };

    // Recorded tracks (system = index 0, microphone = the rest); reads run
    // concurrently, summation stays in track order (deterministic Float32).
    const recordingParts = await Promise.all(
      plan.recording.tracks.map(async (track, ti) => {
        const reader = this.sources.recording[ti];
        if (!reader || track.volume === 0) return [];
        const parts: { at: number; lr: [Float32Array, Float32Array] }[] = [];
        for (let ei = 0; ei < plan.recording.edits.length; ei++) {
          const e = plan.recording.edits[ei];
          const ov = overlap(e, start, end);
          if (!ov) continue;
          const [a, b] = ov;
          if (e.dur === e.srcDur || !plan.recording.timePitch) {
            const src = Math.round(e.src) + (a - e.start);
            parts.push({ at: a, lr: await reader.read(src, b - a) });
          } else {
            const key = `${ti}:${ei}:${e.start}:${e.dur}:${e.src}`;
            let st = this.stretchers.get(key);
            if (!st) this.stretchers.set(key, (st = new WsolaEdit(e)));
            parts.push({ at: a, lr: await st.render(a - e.start, b - e.start, (s, n) => reader.read(s, n)) });
          }
        }
        return parts;
      }),
    );
    plan.recording.tracks.forEach((track, ti) => {
      for (const p of recordingParts[ti]) addStereo(p.lr[0], p.lr[1], p.at, track.volume);
    });

    // Voice-overs: one composition track each, never retimed.
    const voiceParts = await Promise.all(
      plan.voiceOvers.map(async (vo) => {
        const reader = this.sources.voices.get(vo.fileName);
        const ov = overlap(vo.edit, start, end);
        if (!reader || !ov || vo.volume === 0) return null;
        const [a, b] = ov;
        return { at: a, lr: await reader.read(Math.round(vo.edit.src) + (a - vo.edit.start), b - a), gain: vo.volume };
      }),
    );
    for (const p of voiceParts) if (p) addStereo(p.lr[0], p.lr[1], p.at, p.gain);

    // Click ticks (16-bit WAV, mono).
    if (plan.clicks && plan.clicks.volume !== 0) {
      const tick = tickTrackSamples(plan.clicks.style);
      const g = plan.clicks.volume;
      for (const e of plan.clicks.edits) {
        const ov = overlap(e, start, end);
        if (!ov) continue;
        const src = Math.round(e.src) - e.start;
        for (let n = ov[0]; n < ov[1]; n++) {
          const j = src + n;
          if (j < 0 || j >= tick.length) continue;
          const v = tick[j] * g;
          L[n - start] += v;
          R[n - start] += v;
        }
      }
    }

    // Key track (one mono WAV inserted at 0).
    if (plan.keys && plan.keys.volume !== 0) {
      this.keyTrack ??= new KeyTrack(plan.keys.cues, plan.keys.duration, plan.keys.style);
      const k = this.keyTrack.render(start, end - start);
      const g = plan.keys.volume;
      for (let i = 0; i < k.length; i++) {
        const v = k[i] * g;
        L[i] += v;
        R[i] += v;
      }
    }
    return [L, R];
  }
}
