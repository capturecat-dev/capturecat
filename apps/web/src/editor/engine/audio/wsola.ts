/**
 * Pitch-preserving time stretch for one scaled composition edit — the web
 * stand-in for AVFoundation's `.timeDomain` time-pitch algorithm (the Mac
 * sets it on every recorded-audio track when the project has speed regions;
 * voice-overs, ticks and keys are never scaled).
 *
 * WSOLA (waveform-similarity overlap-add), output-synchronous:
 *   frame k is centred at output frame k·H (relative to the edit start),
 *   Hann window of 2H, and reads the source around a_k + δ_k where
 *   a_k = round(k·H·speed) and δ_k ∈ [−Δ, Δ] maximises the normalised
 *   correlation with the natural continuation of frame k−1.
 * δ is reset to 0 every ANCHOR frames, so the chain — and therefore every
 * output sample — is a pure function of the source and the frame index:
 * any window renders identically regardless of chunking or seek history
 * (playback == export, sample for sample).
 */
import type { Edit } from "../../core/audio/mixPlan";

export const WSOLA_HOP = 768; // 16 ms at 48 kHz
const N = WSOLA_HOP * 2;
const DELTA = 480; // ±10 ms search
const ANCHOR = 32; // δ chain reset every ~0.5 s of output
const DECIM = 4;

let hann: Float32Array | null = null;
function window(): Float32Array {
  if (hann) return hann;
  hann = new Float32Array(N);
  // Periodic Hann: w[m] + w[m + H] = 1 (perfect overlap-add at hop H).
  for (let m = 0; m < N; m++) hann[m] = 0.5 - 0.5 * Math.cos((2 * Math.PI * m) / N);
  return hann;
}

export type SourceRead = (start: number, count: number) => Promise<[Float32Array, Float32Array]>;

export class WsolaEdit {
  private readonly speed: number;
  private readonly frames: number;
  private readonly delta = new Map<number, number>();

  constructor(private readonly edit: Edit) {
    this.speed = edit.srcDur / edit.dur;
    this.frames = Math.ceil(edit.dur / WSOLA_HOP) + 1;
  }

  private nominal(k: number): number {
    return Math.round(k * WSOLA_HOP * this.speed);
  }

  /** Output frames [a, b) of the edit (relative to edit.start), stereo. */
  async render(a: number, b: number, read: SourceRead): Promise<[Float32Array, Float32Array]> {
    const count = b - a;
    const L = new Float32Array(count);
    const R = new Float32Array(count);
    if (count <= 0) return [L, R];
    const H = WSOLA_HOP;
    const kmin = Math.max(0, Math.floor(a / H));
    const kmax = Math.min(this.frames, Math.ceil(b / H));
    const chainStart = Math.floor(kmin / ANCHOR) * ANCHOR;
    // Source span (relative to edit.src) covering the chain + synthesis.
    const lo = this.nominal(chainStart) - H - DELTA - 1;
    const hi = this.nominal(kmax) + 2 * H + DELTA + 1;
    const src0 = Math.round(this.edit.src) + lo;
    const [sl, sr] = await read(src0, hi - lo);
    const at = (rel: number) => rel - lo; // index into sl/sr for a source offset rel

    // δ chain from the anchor.
    let mono: Float32Array | null = null;
    for (let k = chainStart; k <= kmax; k++) {
      if (this.delta.has(k)) continue;
      if (k % ANCHOR === 0) {
        this.delta.set(k, 0);
        continue;
      }
      if (!mono) {
        mono = new Float32Array(sl.length);
        for (let i = 0; i < sl.length; i++) mono[i] = (sl[i] + sr[i]) * 0.5;
      }
      const prev = this.delta.get(k - 1)!;
      // Template: what naturally follows frame k−1 (its window start + H).
      const tStart = at(this.nominal(k - 1) + prev + H - H);
      const cBase = at(this.nominal(k) - H);
      this.delta.set(k, bestOffset(mono, tStart, cBase));
    }

    const w = window();
    for (let k = kmin; k <= kmax; k++) {
      const c = k * H;
      const d = this.delta.get(k)!;
      const from = Math.max(a, c - H);
      const to = Math.min(b, c + H);
      const s = at(this.nominal(k) + d) - c; // source index = s + n
      for (let n = from; n < to; n++) {
        const wt = w[n - c + H];
        const j = s + n;
        L[n - a] += wt * sl[j];
        R[n - a] += wt * sr[j];
      }
    }
    return [L, R];
  }
}

/** δ ∈ [−Δ, Δ] maximising normalised correlation (coarse decimated pass, then ±DECIM refine). */
function bestOffset(m: Float32Array, tStart: number, cBase: number): number {
  let best = 0;
  let bestScore = -Infinity;
  const score = (d: number, stride: number) => {
    let xy = 0;
    let yy = 1e-9;
    const cs = cBase + d;
    for (let q = 0; q < N; q += stride) {
      const y = m[cs + q];
      xy += m[tStart + q] * y;
      yy += y * y;
    }
    return xy / Math.sqrt(yy);
  };
  for (let d = -DELTA; d <= DELTA; d += DECIM) {
    const s = score(d, DECIM);
    if (s > bestScore) {
      bestScore = s;
      best = d;
    }
  }
  let refined = best;
  let refinedScore = -Infinity;
  for (let d = Math.max(-DELTA, best - DECIM + 1); d <= Math.min(DELTA, best + DECIM - 1); d++) {
    const s = score(d, 1);
    if (s > refinedScore) {
      refinedScore = s;
      refined = d;
    }
  }
  return refined;
}
