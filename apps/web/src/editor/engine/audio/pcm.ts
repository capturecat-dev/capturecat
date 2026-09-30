/**
 * Decoded PCM of ONE audio track on its presentation timeline, served as
 * 48 kHz stereo — the shape `AVAssetReaderAudioMixOutput` hands the Mac's
 * mix (every track converted to the reader's 48 kHz / 2 ch).
 *
 * Decoding streams through mediabunny's `AudioSampleSink` (WebCodecs
 * `AudioDecoder`; works on the main thread AND in the render worker) with a
 * persistent forward iterator and a sliding native-rate window: sequential
 * reads (playback, export) decode each packet once; a backward or far jump
 * restarts the iterator with a short pre-roll (AAC's first decoded packet
 * after a seek is discarded, never heard).
 *
 * Channel mapping (AVAudioConverter defaults): mono → both channels at unit
 * gain, stereo → L/R, more channels → the first two.
 *
 * Resampling (non-48 kHz sources, e.g. a 44.1 kHz microphone or voice-over):
 * a stateless Kaiser-windowed sinc evaluated at ABSOLUTE positions (48 kHz
 * frame n ↦ input index n·rate/48000 on the track timeline), so any window of
 * output is bit-identical no matter how reads are chunked — playback and
 * export render the same samples.
 */
import { AudioSampleSink, type AudioSample, type InputAudioTrack } from "mediabunny";

export const OUT_RATE = 48_000;
const PREROLL = 0.12; // s decoded and discarded before a seek target
const KEEP_BEHIND = 1.0; // s kept behind the read head (WSOLA lookback)
const READ_AHEAD = 0.5; // s decoded past each request

// Windowed-sinc resampler table.
const TAPS = 16; // half-width in input samples
const RESAMPLE_DELAY = 1; // input samples (AVAudioConverter alignment, measured)
const PHASES = 1024;
let sincTable: Float32Array | null = null;

function besselI0(x: number): number {
  let sum = 1;
  let term = 1;
  for (let k = 1; k < 40; k++) {
    term *= (x / (2 * k)) * (x / (2 * k));
    sum += term;
    if (term < 1e-12 * sum) break;
  }
  return sum;
}

/** Kernel for upsampling (cutoff = input Nyquist): table[phase][tap]. */
function kernel(): Float32Array {
  if (sincTable) return sincTable;
  const beta = 8.6;
  const t = new Float32Array((PHASES + 1) * 2 * TAPS);
  const i0b = besselI0(beta);
  for (let p = 0; p <= PHASES; p++) {
    const frac = p / PHASES;
    let norm = 0;
    const row = new Float64Array(2 * TAPS);
    for (let k = 0; k < 2 * TAPS; k++) {
      const x = k - (TAPS - 1) - frac; // tap offset relative to the fractional position
      const sinc = x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x);
      const r = x / TAPS;
      const w = Math.abs(r) >= 1 ? 0 : besselI0(beta * Math.sqrt(1 - r * r)) / i0b;
      row[k] = sinc * w;
      norm += row[k];
    }
    for (let k = 0; k < 2 * TAPS; k++) t[p * 2 * TAPS + k] = row[k] / norm;
  }
  sincTable = t;
  return t;
}

/**
 * A track's media timeline as AVFoundation presents it: its duration and the
 * native priming frames its container timestamps run ahead by. `gapless` is
 * the file's iTunSMPB (priming / valid sample count), honoured when no edit
 * list already moved the first sample before 0. Shared by the playback/export
 * reader and the timeline waveform decoder (ui/timeline/media).
 */
export async function trackTimeline(
  track: InputAudioTrack,
  gapless?: { priming: number; validFrames: number } | null,
): Promise<{ duration: number; priming: number }> {
  let duration = await track.computeDuration();
  let priming = 0;
  if (gapless && gapless.priming > 0) {
    const first = await track.getFirstTimestamp().catch(() => 0);
    if (first >= -1e-6) {
      priming = gapless.priming;
      duration = gapless.validFrames > 0 ? gapless.validFrames / track.sampleRate : duration - priming / track.sampleRate;
    }
  }
  return { duration, priming };
}

export class PcmTrackReader {
  readonly rate: number;
  readonly channels: number;
  /** End of the track on its timeline, in 48 kHz frames. */
  readonly endFrame: number;
  private sink: AudioSampleSink;
  private iter: AsyncGenerator<AudioSample, void, unknown> | null = null;
  /** Native-rate window: absolute input indices [base, base + length). */
  private base = 0;
  private length = 0;
  private bufL = new Float32Array(0);
  private bufR = new Float32Array(0);
  private iterDone = false;
  private queue: Promise<unknown> = Promise.resolve();
  private scratch = new Float32Array(0);
  private disposed = false;

  /** Native input frames the container's timestamps run ahead of the media timeline (gapless priming). */
  private readonly primingFrames: number;

  private constructor(track: InputAudioTrack, duration: number, priming: number) {
    this.rate = track.sampleRate;
    this.channels = track.numberOfChannels;
    this.sink = new AudioSampleSink(track);
    this.endFrame = Math.round(duration * OUT_RATE);
    this.primingFrames = priming;
  }

  /**
   * `gapless`: the file's iTunSMPB (priming / valid sample count), honoured
   * like AVFoundation does when the container has no edit list for it —
   * `AVAudioFile`/`AVAudioRecorder` m4a voice-overs carry their 2112-frame
   * AAC priming that way. Ignored when an edit list already moved the first
   * sample before 0.
   */
  static async open(
    track: InputAudioTrack,
    gapless?: { priming: number; validFrames: number } | null,
  ): Promise<PcmTrackReader | null> {
    if (!(await track.canDecode())) return null;
    const { duration, priming } = await trackTimeline(track, gapless);
    return new PcmTrackReader(track, duration, priming);
  }

  /** Track duration on its timeline (seconds, from the packet table). */
  get duration(): number {
    return this.endFrame / OUT_RATE;
  }

  /**
   * 48 kHz stereo frames [start, start + count) of the track timeline
   * (zeros outside the decoded media). Calls are serialized.
   */
  read(start: number, count: number): Promise<[Float32Array, Float32Array]> {
    const run = this.queue.then(() => this.readNow(start, count));
    this.queue = run.catch(() => undefined);
    return run;
  }

  private async readNow(start: number, count: number): Promise<[Float32Array, Float32Array]> {
    const L = new Float32Array(count);
    const R = new Float32Array(count);
    if (count <= 0 || this.disposed) return [L, R];
    const from = Math.max(start, 0); // the timeline starts at 0 (priming lies before it)
    const to = Math.min(start + count, this.endFrame + OUT_RATE); // small margin: priming/remainder
    if (to <= Math.max(from, 0)) return [L, R];
    if (this.rate === OUT_RATE) {
      await this.ensure(from, to);
      this.copyNative(from, to, L, R, start);
      return [L, R];
    }
    // Resample: input index for output frame n is n·rate/48000 − 1 (the
    // Mac's converter lands one INPUT sample later — measured against the
    // exporter's own read-back of a 44.1 kHz microphone track).
    const ratio = this.rate / OUT_RATE;
    const n0 = from;
    const j0 = Math.floor(n0 * ratio - RESAMPLE_DELAY) - TAPS;
    const j1 = Math.ceil((to - 1) * ratio) + TAPS + 1;
    await this.ensure(Math.max(0, j0), j1);
    const table = kernel();
    for (let n = n0; n < to; n++) {
      const pos = n * ratio - RESAMPLE_DELAY;
      const ip = Math.floor(pos);
      const frac = pos - ip;
      const p = Math.round(frac * PHASES);
      const row = p * 2 * TAPS;
      const first = ip - (TAPS - 1);
      let accL = 0;
      let accR = 0;
      for (let k = 0; k < 2 * TAPS; k++) {
        const j = first + k - this.base;
        if (j < 0 || j >= this.length) continue;
        const w = table[row + k];
        accL += w * this.bufL[j];
        accR += w * this.bufR[j];
      }
      L[n - start] = accL;
      R[n - start] = accR;
    }
    return [L, R];
  }

  private copyNative(j0: number, j1: number, L: Float32Array, R: Float32Array, outStart: number): void {
    const a = Math.max(j0, this.base);
    const b = Math.min(j1, this.base + this.length);
    if (b <= a) return;
    L.set(this.bufL.subarray(a - this.base, b - this.base), a - outStart);
    R.set(this.bufR.subarray(a - this.base, b - this.base), a - outStart);
  }

  /** Makes native input indices [j0, j1) resident (as far as the media reaches). */
  private async ensure(j0: number, j1: number): Promise<void> {
    const haveEnd = this.base + this.length;
    const forward = this.iter && j0 >= this.base && j0 <= haveEnd + this.rate * 0.25;
    if (!forward) {
      await this.restart(j0);
    }
    // Drop what is far behind the read head.
    const keepFrom = j0 - Math.round(KEEP_BEHIND * this.rate);
    if (keepFrom > this.base) this.dropBefore(keepFrom);
    const want = j1 + Math.round(READ_AHEAD * this.rate);
    while (!this.iterDone && this.base + this.length < want) {
      const next = await this.iter!.next();
      if (next.done) {
        this.iterDone = true;
        break;
      }
      this.append(next.value);
    }
  }

  private async restart(j0: number): Promise<void> {
    await this.iter?.return(undefined).catch(() => undefined);
    // Container time (priming included) of the pre-rolled start.
    const t = Math.max(0, (j0 + this.primingFrames) / this.rate - PREROLL);
    this.iter = this.sink.samples(t);
    this.iterDone = false;
    // The first packet after a seek decodes without its MDCT overlap
    // partner; it lies inside the pre-roll, before anything that is read.
    this.base = Math.round(t * this.rate) - this.primingFrames;
    this.length = 0;
  }

  private append(sample: AudioSample): void {
    try {
      const frames = sample.numberOfFrames;
      const startIdx = Math.round(sample.timestamp * this.rate) - this.primingFrames;
      if (this.length === 0 && startIdx > this.base) this.base = startIdx;
      if (this.length === 0 && startIdx < this.base) this.base = startIdx;
      const end = this.base + this.length;
      // Gap → zeros; overlap → keep what we have.
      const offset = startIdx - end;
      const skip = offset < 0 ? -offset : 0;
      if (skip >= frames) return;
      const pad = offset > 0 ? offset : 0;
      const n = frames - skip;
      this.reserve(this.length + pad + n);
      if (pad > 0) {
        this.bufL.fill(0, this.length, this.length + pad);
        this.bufR.fill(0, this.length, this.length + pad);
        this.length += pad;
      }
      if (this.scratch.length < frames) this.scratch = new Float32Array(frames);
      const s = this.scratch.subarray(0, frames);
      sample.copyTo(s, { planeIndex: 0, format: "f32-planar" });
      this.bufL.set(s.subarray(skip), this.length);
      if (sample.numberOfChannels > 1) sample.copyTo(s, { planeIndex: 1, format: "f32-planar" });
      this.bufR.set(s.subarray(skip), this.length);
      this.length += n;
    } finally {
      sample.close();
    }
  }

  private reserve(n: number): void {
    if (this.bufL.length >= n) return;
    const cap = Math.max(n, this.bufL.length * 2, this.rate * 4);
    const l = new Float32Array(cap);
    const r = new Float32Array(cap);
    l.set(this.bufL.subarray(0, this.length));
    r.set(this.bufR.subarray(0, this.length));
    this.bufL = l;
    this.bufR = r;
  }

  private dropBefore(j: number): void {
    const d = Math.min(this.length, j - this.base);
    if (d <= 0) return;
    this.bufL.copyWithin(0, d, this.length);
    this.bufR.copyWithin(0, d, this.length);
    this.length -= d;
    this.base += d;
  }

  dispose(): void {
    this.disposed = true;
    void this.iter?.return(undefined).catch(() => undefined);
    this.iter = null;
  }
}
