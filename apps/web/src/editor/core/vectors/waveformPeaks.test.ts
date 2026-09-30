/**
 * Timeline waveform gate — core/audio/waveformPeaks.ts against the REAL Swift.
 *
 * `golden/waveformPeaks.json` was recorded by apps/web/scripts/waveform-golden/record.swift,
 * compiled TOGETHER WITH the app's own Services/WaveformGenerator.swift (no copy): it writes
 * synthetic WAVs (16-bit and IEEE-float, 1–3 channels, 22.05/44.1/48 kHz) and records
 * `WaveformGenerator.generate(from:sampleCount:timeRange:)` — AVAssetReader's s16 conversion,
 * its timeRange frame selection, the interleaved bucket split and the f32 peak normalisation.
 *
 * Each case regenerates the identical PCM here (xorshift32 from the case spec, the same
 * arithmetic the driver uses) and requires EVERY Float to match exactly. The envelope path the
 * web actually caches (PeakEnvelope + envelopePeaks) is then held to the same outputs: exactly
 * at blockFrames = 1 for mono, and within the documented block-edge bound at the runtime size.
 * The suite FAILS — never skips — when the golden file is missing.
 */
import { describe, expect, it } from "vitest";
import {
  ENVELOPE_BLOCK_FRAMES,
  PeakEnvelopeBuilder,
  envelopePeaks,
  floatToInt16,
  int16Magnitude,
  mergeTrackPeaks,
  peakBuckets,
  readerFrameWindow,
  recordingWaveform,
  voiceClipWaveform,
  waveformPeaks,
} from "../audio/waveformPeaks";

type ProcessLike = { getBuiltinModule?: (id: string) => unknown };
type NodeFS = { readFileSync(path: string, encoding: "utf8"): string; existsSync(path: string): boolean };
type NodeURL = { fileURLToPath(url: string | URL): string };

interface Spec {
  name: string;
  rate: number;
  channels: number;
  format: "s16" | "f32";
  seed: number;
  segments: [number, number[]][];
  sampleCount: number;
  timeRange: [number, number] | null;
}

interface Golden {
  unit: string;
  notes: string;
  count: number;
  cases: { input: Spec; output: number[] }[];
}

function loadGolden(): Golden {
  const proc = (globalThis as { process?: ProcessLike }).process;
  if (!proc?.getBuiltinModule) throw new Error("waveformPeaks golden needs Node >= 22.3 (process.getBuiltinModule).");
  const fs = proc.getBuiltinModule("node:fs") as NodeFS;
  const url = proc.getBuiltinModule("node:url") as NodeURL;
  const path = url.fileURLToPath(new URL("./golden/waveformPeaks.json", import.meta.url));
  if (!fs.existsSync(path)) {
    throw new Error(
      "Golden file src/editor/core/vectors/golden/waveformPeaks.json is missing. Re-record it from the REAL " +
        "Swift with apps/web/scripts/waveform-golden/record.swift (see its header) — never hand-edit expectations.",
    );
  }
  return JSON.parse(fs.readFileSync(path, "utf8")) as Golden;
}

/** The driver's `XorShift32` + `signal(_:)`: interleaved s16 values, or f32 values for float WAVs. */
function signal(spec: Spec): number[] {
  let s = spec.seed >>> 0;
  const next = () => {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5;
    s >>>= 0;
    return s;
  };
  const out: number[] = [];
  for (const [frames, amps] of spec.segments) {
    for (let f = 0; f < frames; f++) {
      for (let c = 0; c < spec.channels; c++) {
        const u = next() / 4294967296;
        const v = (u * 2 - 1) * amps[c];
        out.push(spec.format === "s16" ? Math.trunc(v) : Math.fround(v));
      }
    }
  }
  return out;
}

/** What AVAssetReader hands the generator: s16 (float WAVs go through its converter). */
function asInt16(spec: Spec, values: number[]): Int16Array {
  const out = new Int16Array(values.length);
  for (let i = 0; i < values.length; i++) out[i] = spec.format === "s16" ? values[i] : floatToInt16(values[i]);
  return out;
}

const range = (spec: Spec) => (spec.timeRange ? { start: spec.timeRange[0], duration: spec.timeRange[1] } : null);

const golden = loadGolden();

describe("waveformPeaks — WaveformGenerator.generate (golden from the real Swift)", () => {
  it("golden file is the expected unit", () => {
    expect(golden.unit).toBe("waveformPeaks");
    expect(golden.cases.length).toBe(golden.count);
    expect(golden.count).toBeGreaterThanOrEqual(15);
  });

  for (const { input, output } of golden.cases) {
    it(`${input.name}: exact f32 buckets`, () => {
      const pcm = asInt16(input, signal(input));
      const got = waveformPeaks(pcm, input.channels, input.rate, input.sampleCount, range(input));
      expect(got.length).toBe(output.length);
      for (let i = 0; i < output.length; i++) {
        if (got[i] !== output[i]) throw new Error(`${input.name}[${i}]: got ${got[i]}, Swift ${output[i]}`);
      }
    });
  }

  it("envelope at blockFrames = 1 reproduces the mono cases exactly", () => {
    let checked = 0;
    for (const { input, output } of golden.cases) {
      if (input.channels !== 1) continue;
      const pcm = asInt16(input, signal(input));
      const b = new PeakEnvelopeBuilder(input.rate, 1, 1);
      b.pushInt16Interleaved(0, pcm);
      const got = envelopePeaks(b.finish(), input.sampleCount, range(input));
      expect(Array.from(got)).toEqual(output);
      checked++;
    }
    expect(checked).toBeGreaterThanOrEqual(8);
  });

  it("f32-fed envelope (the decoder path) equals the s16-fed one", () => {
    for (const { input } of golden.cases) {
      if (input.format !== "f32") continue;
      const values = signal(input);
      const frames = values.length / input.channels;
      const planes = Array.from({ length: input.channels }, (_, c) => {
        const p = new Float32Array(frames);
        for (let f = 0; f < frames; f++) p[f] = values[f * input.channels + c];
        return p;
      });
      const a = new PeakEnvelopeBuilder(input.rate, input.channels);
      // Chunked like decoded AudioSamples (1024-frame AAC packets).
      for (let f = 0; f < frames; f += 1024) {
        const n = Math.min(1024, frames - f);
        a.pushFloat(f, n, planes.map((p) => p.subarray(f, f + n)));
      }
      const b = new PeakEnvelopeBuilder(input.rate, input.channels);
      b.pushInt16Interleaved(0, asInt16(input, values));
      expect(a.finish()).toEqual(b.finish());
    }
  });

  it(`runtime envelope (${ENVELOPE_BLOCK_FRAMES}-frame blocks) stays within its block-edge bound`, () => {
    for (const { input, output } of golden.cases) {
      if (output.length === 0) continue;
      const pcm = asInt16(input, signal(input));
      const b = new PeakEnvelopeBuilder(input.rate, input.channels);
      b.pushInt16Interleaved(0, pcm);
      const env = b.finish();
      const got = envelopePeaks(env, input.sampleCount, range(input));
      expect(got.length).toBe(output.length);
      // Bound: the exact bucket max over a window widened by one block each side.
      const frames = pcm.length / input.channels;
      const [f0, f1] = readerFrameWindow(range(input), input.rate, frames);
      const total = (f1 - f0) * input.channels;
      const per = Math.max(1, Math.floor(total / input.sampleCount));
      const mags = Array.from(pcm, int16Magnitude);
      const widened: number[] = [];
      for (let i = 0; i < input.sampleCount; i++) {
        const s = i * per;
        if (s >= total) {
          widened.push(0);
          continue;
        }
        const e = Math.min(s + per, total);
        const a0 = Math.max(0, (Math.floor((f0 + Math.floor(s / input.channels)) / ENVELOPE_BLOCK_FRAMES) * ENVELOPE_BLOCK_FRAMES) * input.channels);
        const a1 = Math.min(pcm.length, (Math.floor((f0 + Math.ceil(e / input.channels) - 1) / ENVELOPE_BLOCK_FRAMES) + 1) * ENVELOPE_BLOCK_FRAMES * input.channels);
        let m = 0;
        for (let j = a0; j < a1; j++) if (mags[j] > m) m = mags[j];
        widened.push(m);
      }
      const wPeak = Math.max(...widened);
      const exactRaw = output; // normalised
      for (let i = 0; i < got.length; i++) {
        // Never below the exact bucket (blocks only widen the window)…
        expect(got[i]).toBeGreaterThanOrEqual(exactRaw[i] * (1 - 1e-3) - 1e-6);
        // …and never above the widened window's normalised max.
        const bound = wPeak > 0 ? Math.min(1, widened[i] / wPeak) * (1 + 1e-3) + 1e-6 : 1e-6;
        if (wPeak / 32767 > 0.01) expect(got[i]).toBeLessThanOrEqual(bound);
      }
    }
  });
});

describe("waveformPeaks — measured AVFoundation rules + call sites", () => {
  it("floatToInt16: ×32768, ties away from zero, clamped (AVAssetReader probe)", () => {
    const probes: [number, number][] = [
      [1.0, 32767],
      [-1.0, -32768],
      [0.5, 16384],
      [-0.5, -16384],
      [1.5, 32767],
      [-1.5, -32768],
      [0.999, 32735],
      [-0.999, -32735],
      [1 / 65536, 1],
      [-1 / 65536, -1],
      [3 / 65536, 2],
      [0.25 / 32768, 0],
      [0.75 / 32768, 1],
      [2.5 / 32768, 3],
      [-2.5 / 32768, -3],
      [32767.5 / 32768, 32767],
      [-32767.5 / 32768, -32768],
    ];
    for (const [x, want] of probes) expect(floatToInt16(Math.fround(x))).toBe(want);
  });

  it("readerFrameWindow: CMTime(600) truncation, floor start, ceil end (AVAssetReader probe)", () => {
    // 44.1 kHz: 1/600 s = 73.5 frames.
    expect(readerFrameWindow({ start: 0, duration: 1 / 600 }, 44100, 88200)).toEqual([0, 74]);
    expect(readerFrameWindow({ start: 1 / 600, duration: 2 / 600 }, 44100, 88200)).toEqual([73, 221]);
    expect(readerFrameWindow({ start: 7 / 600, duration: 13 / 600 }, 44100, 88200)).toEqual([514, 1470]);
    expect(readerFrameWindow({ start: 0.123456, duration: 0.654321 }, 44100, 88200)).toEqual([5439, 34251]);
    expect(readerFrameWindow({ start: 0.0017, duration: 0.0021 }, 48000, 96000)).toEqual([80, 160]);
    expect(readerFrameWindow({ start: 1.9, duration: 0.5 }, 48000, 96000)).toEqual([91200, 96000]);
    expect(readerFrameWindow(null, 48000, 96000)).toEqual([0, 96000]);
  });

  it("int16Magnitude saturates Int16.min (the Swift loop traps there)", () => {
    expect(int16Magnitude(-32768)).toBe(32767);
    expect(int16Magnitude(-5)).toBe(5);
    // peakBuckets over magnitudes: floor(total / count) buckets, remainder dropped, tail zeros.
    // 7 samples / 3 buckets → 2 per bucket; the trailing 7 is dropped; peak 1 → scale 1.
    expect(Array.from(peakBuckets([1, 2, 3, 4, 5, 32767, 7], 3))).toEqual([2 / 32767, 4 / 32767, 1].map(Math.fround));
    expect(Array.from(peakBuckets([100, 200], 4))).toEqual([Math.fround(100 / 32767), Math.fround(200 / 32767), 0, 0]);
  });

  it("mergeTrackPeaks: element-wise max, empty tracks skipped, [] when none", () => {
    expect(Array.from(mergeTrackPeaks([[0.1, 0.9, 0.3], [0.5, 0.2]], 3))).toEqual(
      [0.5, 0.9, 0.3].map(Math.fround),
    );
    expect(mergeTrackPeaks([[], []], 180).length).toBe(0);
    expect(mergeTrackPeaks([[], [1]], 4).length).toBe(4);
  });

  it("recordingWaveform uses the trim window (180) and voiceClipWaveform the clip window (72, ≥ 0.1 s)", () => {
    const spec = golden.cases.find((c) => c.input.name === "stereo-s16-48k-10s-trim")!;
    const pcm = asInt16(spec.input, signal(spec.input));
    const b = new PeakEnvelopeBuilder(48000, 2, 1);
    b.pushInt16Interleaved(0, pcm);
    const env = b.finish();
    const [start, duration] = spec.input.timeRange!;
    const project = { trimStart: start, trimEnd: start + duration, duration: 10 };
    const wave = recordingWaveform(project, [env]);
    expect(wave.length).toBe(180);
    // Stereo blocks of one frame can straddle a bucket's odd interleaved edge — near-exact.
    for (let i = 0; i < 180; i++) expect(Math.abs(wave[i] - spec.output[i])).toBeLessThan(0.02);
    // No trim window (trimmedDuration 0) → the reader reads the whole file.
    expect(Array.from(recordingWaveform({ trimStart: 0, trimEnd: 0, duration: 0 }, [env]))).toEqual(
      Array.from(envelopePeaks(env, 180, null)),
    );
    const voice = voiceClipWaveform({ sourceStartTime: 1, duration: 0.01 }, env);
    expect(voice.length).toBe(72);
  });
});
