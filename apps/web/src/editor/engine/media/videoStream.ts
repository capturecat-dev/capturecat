/**
 * VideoStream — WebCodecs decode scheduling for one video track.
 *
 * One decoder "run" = decoding forward in decode order from a keyframe. The
 * stream keeps a run going as long as it can reach the wanted frame; it
 * RESTARTS (reset → keyframe → decode forward, dropping frames before the
 * target) when the target is behind the run, already dropped, or so far
 * ahead that a later keyframe is a shorter path (GOP-aware seek).
 *
 * Backpressure: packets are fed only while (decoded-ahead + in-flight) is
 * below the lookahead, and the decoder queue stays short, so memory is
 * bounded and a scrub never waits behind stale work. Every VideoFrame is
 * owned by the FrameCache or closed on arrival.
 */
import type { EncodedPacket } from "mediabunny";
import type { DemuxedVideo } from "./demux";
import { FrameCache } from "./frameCache";

export interface StreamStats {
  decodeQueueSize: number;
  inflight: number;
  cached: number;
  cacheBytes: number;
  aheadOfTarget: number;
  restarts: number;
  decoded: number;
  /** Frames that arrived already behind the playhead while playing (decode too slow). */
  lateOutputs: number;
  lastSeekMs: number | null;
  decoderState: string;
}

export interface StreamOptions {
  /** Cache budget in bytes (NV12-sized estimate per frame). */
  cacheBytes?: number;
  lookahead?: number;
  onFrame?: (index: number) => void;
  onError?: (err: Error) => void;
  label?: string;
}

const MAX_DECODE_QUEUE = 6;
/** Packets allowed in flight beyond the window so reordering decoders (B-frames) keep emitting. */
const REORDER_SLACK = 4;

export class VideoStream {
  readonly cache: FrameCache;
  private decoder: VideoDecoder;
  private target = 0;
  private playing = false;
  /** Loop range (presentation indices) while looped playback is on. */
  private loop: { start: number; end: number } | null = null;
  private lookahead: number;
  private gen = 0;
  /** Decode index the current run started at (−1 = no run). */
  private runStart = -1;
  /** Next decode index to feed. */
  private feedPos = -1;
  private reader: AsyncGenerator<EncodedPacket, void, unknown> | null = null;
  private readerDone = false;
  private drained = false;
  private flushing = false;
  private feedingGen = -1;
  private restartingGen = -1;
  private inflight = 0;
  /** chunk µs timestamp → run generation (outputs of a reset run are dropped). */
  private pendingTs = new Map<number, number>();
  /** Highest presentation index output by the current run. */
  private outputMax = -1;
  private waiters: { index: number; resolve: (f: VideoFrame) => void; reject: (e: Error) => void }[] = [];
  private seekStartedAt: number | null = null;
  private stats = { restarts: 0, decoded: 0, lateOutputs: 0, lastSeekMs: null as number | null };
  private disposed = false;

  constructor(
    private readonly media: DemuxedVideo,
    private readonly opts: StreamOptions = {},
  ) {
    const { width, height } = media.info;
    const frameBytes = Math.ceil(width * height * 1.5);
    const budget = opts.cacheBytes ?? 256 * 1024 * 1024;
    const maxFrames = Math.max(6, Math.min(64, Math.floor(budget / frameBytes)));
    this.cache = new FrameCache(maxFrames, frameBytes);
    this.lookahead = Math.max(2, Math.min(opts.lookahead ?? 8, maxFrames - 3));
    this.decoder = this.createDecoder();
  }

  private createDecoder(): VideoDecoder {
    const d = new VideoDecoder({
      output: (f) => this.onOutput(f),
      error: (e) => this.onDecoderError(e),
    });
    d.addEventListener("dequeue", () => this.pump());
    return d;
  }

  private configure(): void {
    this.decoder.configure({
      ...this.media.decoderConfig,
      hardwareAcceleration: "no-preference",
      optimizeForLatency: true,
    });
  }

  get frameCount(): number {
    return this.media.frames.length;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /** The frame the renderer wants now, and whether we are playing (drives lookahead + dropping). */
  setTarget(index: number, playing: boolean): void {
    const i = Math.max(0, Math.min(this.frameCount - 1, index));
    if (i !== this.target && !this.cache.has(i)) this.seekStartedAt = performance.now();
    this.target = i;
    this.playing = playing;
    this.pump();
  }

  /** Enables loop-aware prefetch over [start, end] (null = no wrap). */
  setLoop(range: { start: number; end: number } | null): void {
    this.loop = range && range.end > range.start ? range : null;
    this.cache.score = (i) => this.distance(i);
    this.pump();
  }

  /** Playback distance from the target (cyclic when looping) — eviction order. */
  private distance(i: number): number {
    const t = this.target;
    if (i >= t) return i - t;
    if (this.loop && this.playing && i >= this.loop.start) return this.loop.end - t + 1 + (i - this.loop.start);
    return (t - i) * 2;
  }

  /** Exact frame if decoded. */
  frame(index: number): VideoFrame | null {
    return this.cache.get(index);
  }

  nearestAtOrBefore(index: number) {
    return this.cache.nearestAtOrBefore(index);
  }

  /** Resolves with the exact frame (owned by the cache — do not close). Export/snapshot path. */
  waitFor(index: number, playing = false): Promise<VideoFrame> {
    const hit = this.cache.get(index);
    this.setTarget(index, playing);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolve, reject) => this.waiters.push({ index, resolve, reject }));
  }

  getStats(): StreamStats {
    return {
      decodeQueueSize: this.decoder.decodeQueueSize,
      inflight: this.inflight,
      cached: this.cache.size,
      cacheBytes: this.cache.residentBytes,
      aheadOfTarget: this.cache.countInRange(this.target, this.target + 1000),
      restarts: this.stats.restarts,
      decoded: this.stats.decoded,
      lateOutputs: this.stats.lateOutputs,
      lastSeekMs: this.stats.lastSeekMs,
      decoderState: this.decoder.state,
    };
  }

  dispose(): void {
    this.disposed = true;
    this.gen++;
    void this.reader?.return(undefined);
    this.reader = null;
    try {
      if (this.decoder.state !== "closed") this.decoder.close();
    } catch {
      /* already closed */
    }
    this.cache.destroy();
    for (const w of this.waiters) w.reject(new Error("stream disposed"));
    this.waiters = [];
  }

  // ── Scheduling ────────────────────────────────────────────────────────────

  /**
   * Frames wanted decoded right now, in priority order: the target and the
   * lookahead after it; when looping and the window runs past the loop end,
   * the lookahead WRAPS to the loop start — so the head of the timeline is
   * decoded (by a second run, once the tail is buffered) before the playhead
   * wraps, and the loop is gapless.
   */
  private wanted(): number[] {
    const n = this.playing ? this.lookahead : Math.min(3, this.lookahead);
    const last = this.loop ? this.loop.end : this.frameCount - 1;
    const out: number[] = [];
    for (let i = this.target; i <= Math.min(last, this.target + n); i++) out.push(i);
    if (this.loop && this.playing) {
      const wrap = this.target + n - last;
      for (let k = 0; k < Math.min(wrap, n); k++) {
        const i = this.loop.start + k;
        if (i < this.target) out.push(i);
      }
    }
    return out;
  }

  /** Keep-alive predicate for frames behind the playhead (loop head, pins handled by the cache). */
  private isWanted(i: number): boolean {
    if (i >= this.target) return true;
    if (!this.loop || !this.playing) return !this.playing;
    return i >= this.loop.start && i < this.loop.start + this.lookahead;
  }

  /** Can the current run still produce frame `i`? */
  private runReaches(i: number): boolean {
    if (this.runStart < 0) return false;
    const f = this.media.frames[i];
    if (f.decodeIndex < this.runStart) return false;
    // Already output by this run and no longer cached → gone.
    if (i <= this.outputMax && !this.cache.has(i)) return false;
    if (this.drained && !this.cache.has(i)) return false;
    // A later keyframe is a shorter path than decoding every GOP in between.
    const key = this.media.keyDecodeIndexFor(i);
    if (key > this.feedPos && key > this.runStart) return false;
    return true;
  }

  pump(): void {
    if (this.disposed) return;
    const target = this.target;
    if (this.cache.has(target)) this.resolveWaiters();

    // Drop frames the playhead has passed while playing (they will never show).
    if (this.playing) this.cache.retain((i) => this.isWanted(i));

    // First wanted frame that is not decoded yet.
    const missing = this.wanted().find((i) => !this.cache.has(i));
    if (missing === undefined) return;
    if (!this.runReaches(missing)) {
      void this.restart(this.media.keyDecodeIndexFor(missing));
      return;
    }
    void this.feed(this.gen);
  }

  private shouldFeed(): boolean {
    if (this.readerDone || this.flushing || this.drained) return false;
    if (this.decoder.state !== "configured") return false;
    if (this.decoder.decodeQueueSize >= MAX_DECODE_QUEUE) return false;
    // Wanted frames this run has yet to output; plus B-frame reorder slack.
    let need = 0;
    for (const i of this.wanted()) {
      if (i > this.outputMax && !this.cache.has(i) && this.media.frames[i].decodeIndex >= this.runStart) need++;
    }
    if (need === 0) return false;
    return this.inflight < need + REORDER_SLACK;
  }

  private async restart(keyDecodeIndex: number): Promise<void> {
    const gen = ++this.gen;
    this.restartingGen = gen;
    this.stats.restarts++;
    void this.reader?.return(undefined);
    this.reader = null;
    this.readerDone = false;
    this.drained = false;
    this.flushing = false;
    this.inflight = 0;
    this.pendingTs.clear();
    this.outputMax = -1;
    this.runStart = keyDecodeIndex;
    this.feedPos = keyDecodeIndex;
    try {
      if (this.decoder.state === "closed") this.decoder = this.createDecoder();
      else this.decoder.reset();
      this.configure();
      const key = await this.media.keyPacketAt(keyDecodeIndex);
      if (gen !== this.gen) return;
      // verifyKeyPackets may have stepped back to an earlier real keyframe.
      const idx = this.media.frameIndexForTimestamp(Math.round(key.timestamp * 1e6));
      if (idx >= 0) {
        this.runStart = this.media.frames[idx].decodeIndex;
        this.feedPos = this.runStart;
      }
      this.reader = this.media.sink.packets(key);
    } catch (e) {
      if (gen === this.gen) this.fail(e);
      return;
    } finally {
      if (this.restartingGen === gen) this.restartingGen = -1;
    }
    if (gen === this.gen) void this.feed(gen);
  }

  private async feed(gen: number): Promise<void> {
    if (this.feedingGen === gen || this.restartingGen === gen || !this.reader) return;
    this.feedingGen = gen;
    const reader = this.reader;
    try {
      while (gen === this.gen && this.shouldFeed()) {
        const r = await reader.next();
        if (gen !== this.gen) return;
        if (r.done) {
          this.readerDone = true;
          break;
        }
        const chunk = r.value.toEncodedVideoChunk();
        this.pendingTs.set(chunk.timestamp, gen);
        this.decoder.decode(chunk);
        this.feedPos++;
        this.inflight++;
      }
      if (gen === this.gen && this.readerDone && !this.flushing && !this.drained && this.inflight > 0) {
        this.flushing = true;
        await this.decoder.flush().catch(() => undefined);
        if (gen !== this.gen) return;
        this.flushing = false;
        this.drained = true;
        this.inflight = 0;
      }
    } catch (e) {
      if (gen === this.gen) this.fail(e);
    } finally {
      if (this.feedingGen === gen) this.feedingGen = -1;
    }
  }

  private onOutput(frame: VideoFrame): void {
    const gen = this.pendingTs.get(frame.timestamp);
    this.pendingTs.delete(frame.timestamp);
    if (gen === undefined || gen !== this.gen || this.disposed) {
      frame.close();
      return;
    }
    this.inflight = Math.max(0, this.inflight - 1);
    this.stats.decoded++;
    const idx = this.media.frameIndexForTimestamp(frame.timestamp);
    if (idx < 0) {
      frame.close();
      return;
    }
    if (idx > this.outputMax) this.outputMax = idx;
    const target = this.target;
    if (this.playing && !this.isWanted(idx)) {
      this.stats.lateOutputs++;
      frame.close();
    } else {
      this.cache.put(idx, frame, target);
      if (!this.cache.has(idx)) {
        // Evicted immediately (behind the target, cache full) — nothing to report.
      } else if (idx === target && this.seekStartedAt !== null) {
        this.stats.lastSeekMs = performance.now() - this.seekStartedAt;
        this.seekStartedAt = null;
      }
    }
    this.resolveWaiters();
    if (this.cache.has(idx)) this.opts.onFrame?.(idx);
    this.pump();
  }

  private resolveWaiters(): void {
    if (!this.waiters.length) return;
    this.waiters = this.waiters.filter((w) => {
      const f = this.cache.get(w.index);
      if (f) {
        w.resolve(f);
        return false;
      }
      return true;
    });
  }

  private onDecoderError(e: DOMException): void {
    this.fail(new Error(`VideoDecoder error (${this.media.info.codecString}): ${e.message}`));
  }

  private fail(e: unknown): void {
    const err = e instanceof Error ? e : new Error(String(e));
    this.opts.onError?.(err);
    for (const w of this.waiters) w.reject(err);
    this.waiters = [];
    this.runStart = -1;
  }
}
