/**
 * How a long recording is fed to Whisper, 30 s at a time.
 *
 * Whisper reads fixed 30 s windows. WhisperKit (the Mac's
 * `TranscriptionService`) walks the audio window by window and re-seeks at
 * the last timestamp it decoded; the browser model runs one window per call,
 * so the windows are cut here instead — at the QUIETEST moment of each
 * window's last ten seconds, so a cut lands between words, not inside one.
 *
 * Windows with no speech-level energy at all are skipped: Whisper invents
 * text for silence ("Thank you."), which WhisperKit suppresses with its
 * no-speech threshold. All positions are 16 kHz sample indices.
 */
import { SPEECH_SAMPLE_RATE } from "../audio/decimate";

/** Whisper's input window. */
export const WINDOW_SECONDS = 30;
/** A cut is searched for in the last (WINDOW − MIN) seconds of each window. */
export const MIN_WINDOW_SECONDS = 20;
/** Energy is measured over 100 ms frames hopped by 20 ms. */
export const ENERGY_FRAME = Math.round(0.1 * SPEECH_SAMPLE_RATE);
export const ENERGY_HOP = Math.round(0.02 * SPEECH_SAMPLE_RATE);
/** A window whose loudest 100 ms stays below this has nothing to transcribe
 *  (−55 dBFS: under any voice, over a digitally silent or empty track). */
export const SILENCE_RMS = 10 ** (-55 / 20);

/** RMS of samples [start, end) of `x`. */
export function rms(x: Float32Array, start = 0, end = x.length): number {
  const a = Math.max(0, start);
  const b = Math.min(x.length, end);
  if (b <= a) return 0;
  let sum = 0;
  for (let i = a; i < b; i++) sum += x[i] * x[i];
  return Math.sqrt(sum / (b - a));
}

/** Loudest 100 ms RMS of `x` (0 for an empty buffer). */
export function peakFrameRms(x: Float32Array): number {
  if (x.length <= ENERGY_FRAME) return rms(x);
  let peak = 0;
  for (let s = 0; s + ENERGY_FRAME <= x.length; s += ENERGY_HOP) peak = Math.max(peak, rms(x, s, s + ENERGY_FRAME));
  return peak;
}

/** True when `x` holds nothing a speech model should hear. */
export function isSilent(x: Float32Array): boolean {
  return peakFrameRms(x) < SILENCE_RMS;
}

/**
 * Where to end a window: the centre of the quietest 100 ms frame whose
 * centre lies in [from, to) of `x` (indices into `x`). The LATEST of equally
 * quiet frames wins, so a silent stretch keeps windows long.
 */
export function quietestCut(x: Float32Array, from: number, to: number): number {
  const half = ENERGY_FRAME >> 1;
  let best = -1;
  let bestEnergy = Infinity;
  for (let c = Math.max(from, half); c < Math.min(to, x.length - half); c += ENERGY_HOP) {
    const e = rms(x, c - half, c + half);
    if (e <= bestEnergy) {
      bestEnergy = e;
      best = c;
    }
  }
  return best >= 0 ? best : Math.min(to, x.length);
}

export interface WindowPlan {
  /** 16 kHz sample index of the window's first sample. */
  start: number;
  /** Exclusive end. */
  end: number;
}

/**
 * The next window starting at `start` of a `total`-sample track, given the
 * audio `x` = samples [start, start + x.length) (at most WINDOW_SECONDS).
 * The last window runs to the end; every other one ends at its quietest cut
 * after MIN_WINDOW_SECONDS.
 */
export function nextWindow(start: number, total: number, x: Float32Array, rate = SPEECH_SAMPLE_RATE): WindowPlan {
  const full = WINDOW_SECONDS * rate;
  if (total - start <= full) return { start, end: total };
  const cut = quietestCut(x, MIN_WINDOW_SECONDS * rate, Math.min(x.length, full));
  return { start, end: start + Math.max(1, cut) };
}
