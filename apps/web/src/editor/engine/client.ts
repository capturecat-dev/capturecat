/**
 * EngineClient — the main-thread proxy for the render worker.
 *
 * Owns nothing heavy: it transfers the canvas, posts commands, resolves the
 * request/response promises, fans out transport/stats events, and — when
 * the recording has audio — plays it and feeds the worker's master clock.
 * No method blocks; nothing here runs per frame.
 */
import { AudioPlayback } from "./audio";
import { wallNow } from "./clock";
import type { RenderMedia } from "./contract";
import type {
  BenchResult,
  EngineCapabilities,
  EngineStats,
  ExportOptions,
  ExportResult,
  FrameInfo,
  FromWorker,
  LoadedInfo,
  SnapshotResult,
  ToWorker,
  TransportState,
  ViewportSpec,
} from "./protocol";

export class EngineError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "EngineError";
  }
}

type Pending = { resolve: (v: never) => void; reject: (e: Error) => void; onProgress?: (d: number, t: number) => void };

export interface ClientOptions {
  /** Play the recording's audio and use it as the master clock (default true). */
  audio?: boolean;
}

export class EngineClient {
  private worker: Worker;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private statsListeners = new Set<(s: EngineStats) => void>();
  private transportListeners = new Set<(s: TransportState) => void>();
  private errorListeners = new Set<(e: EngineError) => void>();
  private frameListeners = new Set<(f: FrameInfo) => void>();
  /** Geometry of the last presented frame (stage editing chrome). */
  lastFrame: FrameInfo | null = null;
  private audio: AudioPlayback | null = null;
  private clockTimer: ReturnType<typeof setInterval> | null = null;
  capabilities: EngineCapabilities | null = null;
  info: LoadedInfo | null = null;
  transport: TransportState | null = null;
  lastStats: EngineStats | null = null;

  private constructor(
    worker: Worker,
    private readonly opts: ClientOptions,
  ) {
    this.worker = worker;
    worker.addEventListener("message", (ev: MessageEvent<FromWorker>) => this.onMessage(ev.data));
    worker.addEventListener("error", (ev) => this.emitError(new EngineError("worker", ev.message || "render worker crashed")));
  }

  /** Transfers `canvas` to a new render worker and brings up WebGPU there. */
  static async create(canvas: HTMLCanvasElement, viewport: ViewportSpec, opts: ClientOptions = {}): Promise<EngineClient> {
    if (!("gpu" in navigator)) {
      throw new EngineError("no-webgpu", "WebGPU is not available in this browser. Use Chrome/Edge 113+, Safari 26+, or Firefox 141+.");
    }
    const worker = new Worker(new URL("./worker.ts", import.meta.url), { type: "module", name: "capturecat-render" });
    const client = new EngineClient(worker, opts);
    const offscreen = canvas.transferControlToOffscreen();
    const ready = new Promise<EngineCapabilities>((resolve, reject) => {
      const onMsg = (ev: MessageEvent<FromWorker>) => {
        if (ev.data.type === "ready") {
          worker.removeEventListener("message", onMsg);
          resolve(ev.data.capabilities);
        } else if (ev.data.type === "error" && ev.data.requestId === undefined) {
          worker.removeEventListener("message", onMsg);
          reject(new EngineError(ev.data.code, ev.data.message));
        }
      };
      worker.addEventListener("message", onMsg);
    });
    client.post({ type: "init", canvas: offscreen, viewport }, [offscreen]);
    client.capabilities = await ready;
    return client;
  }

  private post(msg: ToWorker, transfer: Transferable[] = []) {
    this.worker.postMessage(msg, transfer);
  }

  private request<T>(build: (id: number) => ToWorker, onProgress?: (d: number, t: number) => void): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: never) => void, reject, onProgress });
      this.post(build(id));
    });
  }

  private settle(id: number, value: unknown) {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    p.resolve(value as never);
  }

  private disposed = false;

  private onMessage(msg: FromWorker) {
    if (this.disposed) return;
    switch (msg.type) {
      case "loaded":
        this.info = msg.info;
        this.settle(msg.requestId, msg.info);
        break;
      case "seeked":
        this.settle(msg.requestId, { frameIndex: msg.frameIndex, superseded: msg.superseded, time: msg.time });
        break;
      case "snapshot":
        this.settle(msg.requestId, msg.result);
        break;
      case "exported":
        this.settle(msg.requestId, msg.result);
        break;
      case "benchResult":
        this.settle(msg.requestId, msg.result);
        break;
      case "exportProgress":
        this.pending.get(msg.requestId)?.onProgress?.(msg.done, msg.total);
        break;
      case "transport":
        this.handleTransport(msg.state);
        break;
      case "stats":
        this.lastStats = msg.stats;
        for (const l of this.statsListeners) l(msg.stats);
        break;
      case "error": {
        const err = new EngineError(msg.code, msg.message);
        if (msg.requestId !== undefined && this.pending.has(msg.requestId)) {
          this.pending.get(msg.requestId)!.reject(err);
          this.pending.delete(msg.requestId);
        } else {
          this.emitError(err);
        }
        break;
      }
      case "frame":
        this.lastFrame = msg.info;
        for (const l of this.frameListeners) l(msg.info);
        break;
      case "ready":
        break;
    }
  }

  private emitError(e: EngineError) {
    if (this.errorListeners.size === 0) console.error("[engine]", e);
    for (const l of this.errorListeners) l(e);
  }

  private handleTransport(state: TransportState) {
    const prev = this.transport;
    this.transport = state;
    // Audio follows every transport discontinuity (play, pause, seek, rate, loop wrap).
    if (this.audio?.hasAudio) {
      const jumped = !prev || Math.abs(state.time - this.extrapolate(prev, state.wallMs)) > 0.03;
      if (!state.playing) this.audio.stop();
      else if (!prev?.playing || jumped || prev.rate !== state.rate) this.audio.start(state);
    }
    for (const l of this.transportListeners) l(state);
  }

  private extrapolate(s: TransportState, wall: number): number {
    if (!s.playing) return s.time;
    return Math.min(s.duration, s.time + ((wall - s.wallMs) / 1000) * s.rate);
  }

  // ── Public API ────────────────────────────────────────────────────────────

  async load(project: unknown, media: RenderMedia): Promise<LoadedInfo> {
    this.audio?.dispose();
    this.audio = null;
    if (this.clockTimer) clearInterval(this.clockTimer);
    const info = await this.request<LoadedInfo>((requestId) => ({ type: "load", requestId, project, media }));
    if (this.opts.audio !== false) {
      // The export's own mix (recorded tracks, voice-overs, click/key sounds)
      // — present even for a recording without an audio track.
      try {
        const audio = await AudioPlayback.open({ recording: media.video, files: media.files ?? {} }, project);
        if (this.disposed) {
          audio.dispose();
          return info;
        }
        this.audio = audio;
        this.clockTimer = setInterval(() => {
          const s = this.audio?.sample();
          if (s) this.post({ type: "clock", mediaTime: s.mediaTime, wallMs: s.wallMs });
        }, 50);
      } catch (e) {
        console.warn("[engine] audio unavailable:", e);
      }
    }
    return info;
  }

  setProject(project: unknown): void {
    this.post({ type: "setProject", project });
    void this.audio?.setProject(project);
  }

  play(): void {
    this.post({ type: "play" });
  }
  pause(): void {
    this.post({ type: "pause" });
  }
  /** Resolves when the exact frame for `time` is on screen (or a later seek superseded it). */
  seek(time: number): Promise<{ frameIndex: number; superseded: boolean; time: number }> {
    return this.request((requestId) => ({ type: "seek", requestId, time }));
  }
  setRate(rate: number): void {
    this.post({ type: "rate", rate });
  }
  setLoop(enabled: boolean): void {
    this.post({ type: "loop", enabled });
  }
  resize(viewport: ViewportSpec): void {
    this.post({ type: "resize", viewport });
  }
  snapshot(opts: { png?: boolean } = {}): Promise<SnapshotResult> {
    return this.request((requestId) => ({ type: "snapshot", requestId, png: opts.png }));
  }
  export(options: ExportOptions = {}, onProgress?: (done: number, total: number) => void): Promise<ExportResult> {
    return this.request((requestId) => ({ type: "export", requestId, options }), onProgress);
  }
  /** Stops a running export; its promise rejects with code "cancelled". */
  cancelExport(): void {
    this.post({ type: "exportCancel" });
  }
  debug(d: { camera?: { zoom: number; focalX: number; focalY: number } | null; forceLayer?: boolean }): void {
    this.post({ type: "debug", ...d });
  }
  bench(frames = 120, refit = true): Promise<BenchResult> {
    return this.request((requestId) => ({ type: "bench", requestId, frames, refit }));
  }
  resetStats(): void {
    this.post({ type: "resetStats" });
  }

  /** Playhead extrapolated from the last transport message — for UI, not rendering. */
  currentTime(): number {
    return this.transport ? this.extrapolate(this.transport, wallNow()) : 0;
  }

  get hasAudioClock(): boolean {
    return !!this.audio?.hasAudio;
  }

  /** The playing audio mix plan (null: the export has no audio track). */
  get audioPlan() {
    return this.audio?.plan ?? null;
  }

  /** Playback audio diagnostics (chunks scheduled / late, render ms). */
  get audioStats() {
    return this.audio ? { ...this.audio.stats } : null;
  }

  onStats(cb: (s: EngineStats) => void): () => void {
    this.statsListeners.add(cb);
    return () => this.statsListeners.delete(cb);
  }
  onTransport(cb: (s: TransportState) => void): () => void {
    this.transportListeners.add(cb);
    return () => this.transportListeners.delete(cb);
  }
  onError(cb: (e: EngineError) => void): () => void {
    this.errorListeners.add(cb);
    return () => this.errorListeners.delete(cb);
  }
  /** Every presented frame's geometry (FrameInfo) — for stage interactions. */
  onFrame(cb: (f: FrameInfo) => void): () => void {
    this.frameListeners.add(cb);
    return () => this.frameListeners.delete(cb);
  }

  dispose(): void {
    this.disposed = true;
    this.audio?.dispose();
    if (this.clockTimer) clearInterval(this.clockTimer);
    this.post({ type: "dispose" });
    setTimeout(() => this.worker.terminate(), 100);
    for (const p of this.pending.values()) p.reject(new EngineError("disposed", "engine disposed"));
    this.pending.clear();
  }
}
