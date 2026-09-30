/**
 * 48 kHz → 16 kHz decimation for speech recognition — the browser's half of
 * `TranscriptionService.extractAudio`, whose `AVAssetReaderTrackOutput`
 * hands WhisperKit 16 kHz mono PCM (Core Audio's converter does the
 * low-pass + resample there).
 *
 * The decoded track arrives as 48 kHz (engine/audio/pcm.ts serves every
 * source rate at 48 kHz), so the resample is an exact 3:1 decimation behind
 * a 193-tap Kaiser-windowed-sinc low-pass (flat to 6.5 kHz, −6 dB at
 * 7.2 kHz, ≤ −65 dB from 7.8 kHz, ≈ −90 dB beyond — Whisper's mel bank
 * stops at the 8 kHz output Nyquist). Like pcm.ts's resampler it is
 * STATELESS and evaluated at absolute positions — output sample n reads
 * input samples 3n − HALF … 3n + HALF — so any split of a long track into
 * windows produces bit-identical samples.
 */

export const DECIMATION = 3;
export const SPEECH_SAMPLE_RATE = 16_000;
/** Half-width of the low-pass kernel, in 48 kHz input samples. */
export const DECIMATE_HALF = 96;

let kernelCache: Float32Array | null = null;

function besselI0(x: number): number {
  let sum = 1;
  let term = 1;
  for (let k = 1; k < 50; k++) {
    term *= (x / (2 * k)) * (x / (2 * k));
    sum += term;
    if (term < 1e-12 * sum) break;
  }
  return sum;
}

/** The low-pass FIR (2·HALF + 1 taps, unit DC gain). */
export function decimationKernel(): Float32Array {
  if (kernelCache) return kernelCache;
  const beta = 8.0;
  const cutoff = 7_200 / 48_000; // cycles per input sample
  const n = 2 * DECIMATE_HALF + 1;
  const taps = new Float64Array(n);
  const i0b = besselI0(beta);
  let sum = 0;
  for (let i = 0; i < n; i++) {
    const x = i - DECIMATE_HALF;
    const sinc = x === 0 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * x) / (Math.PI * x);
    const r = x / (DECIMATE_HALF + 1);
    const w = besselI0(beta * Math.sqrt(Math.max(0, 1 - r * r))) / i0b;
    taps[i] = sinc * w;
    sum += taps[i];
  }
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = taps[i] / sum;
  kernelCache = out;
  return out;
}

/**
 * The 48 kHz input span that output samples [outStart, outStart + outCount)
 * read: [3·outStart − HALF, 3·(outStart + outCount − 1) + HALF + 1).
 */
export function decimationInputSpan(outStart: number, outCount: number): { start: number; end: number } {
  return {
    start: DECIMATION * outStart - DECIMATE_HALF,
    end: DECIMATION * (outStart + Math.max(0, outCount) - 1) + DECIMATE_HALF + 1,
  };
}

/**
 * 16 kHz samples [outStart, outStart + outCount) from 48 kHz `input`, whose
 * element 0 is absolute input sample `inputStart`. Input outside the array
 * (before the track, past its end) reads as silence.
 */
export function decimate48kTo16k(
  input: Float32Array,
  inputStart: number,
  outStart: number,
  outCount: number,
  out: Float32Array = new Float32Array(Math.max(0, outCount)),
): Float32Array {
  const h = decimationKernel();
  const taps = h.length;
  for (let n = 0; n < outCount; n++) {
    const first = DECIMATION * (outStart + n) - DECIMATE_HALF - inputStart;
    let acc = 0;
    if (first >= 0 && first + taps <= input.length) {
      for (let k = 0; k < taps; k++) acc += h[k] * input[first + k];
    } else {
      for (let k = 0; k < taps; k++) {
        const j = first + k;
        if (j >= 0 && j < input.length) acc += h[k] * input[j];
      }
    }
    out[n] = acc;
  }
  return out;
}

/** Mono downmix: the average of L and R (mono sources arrive duplicated, so
 *  this returns them unchanged). */
export function downmixStereo(left: Float32Array, right: Float32Array, out: Float32Array = new Float32Array(left.length)): Float32Array {
  for (let i = 0; i < left.length; i++) out[i] = (left[i] + right[i]) * 0.5;
  return out;
}
