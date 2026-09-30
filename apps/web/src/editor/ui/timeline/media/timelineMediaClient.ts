/**
 * Main-thread proxy for the timeline media worker (timelineMedia.worker.ts):
 * request/response by id, cancellation, and the playback pacing flag. One
 * client per open editor; the worker is created lazily on the first request.
 */
import type { PeakEnvelope } from "../../../core/audio/waveformPeaks";
import type { MediaWorkerRequest, MediaWorkerResponse } from "./protocol";

export interface FilmstripJob {
  cancel(): void;
  /** Resolves when every thumbnail has been delivered (or the job failed). */
  done: Promise<{ fromCache: boolean; ms: number; decoded: number } | null>;
}

type Pending =
  | { kind: "filmstrip"; onThumb: (indices: number[], bitmap: ImageBitmap) => void; resolve: (v: { fromCache: boolean; ms: number; decoded: number } | null) => void }
  | { kind: "envelope"; resolve: (v: { tracks: (PeakEnvelope | null)[]; fromCache: boolean; ms: number } | null) => void };

export class TimelineMediaClient {
  private worker: Worker | null = null;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private playing = false;
  private disposed = false;

  private ensure(): Worker | null {
    if (this.disposed) return null;
    if (this.worker) return this.worker;
    try {
      const w = new Worker(new URL("./timelineMedia.worker.ts", import.meta.url), { type: "module", name: "capturecat-timeline-media" });
      w.onmessage = (e: MessageEvent<MediaWorkerResponse>) => this.onMessage(e.data);
      w.onerror = () => {
        for (const p of this.pending.values()) p.resolve(null);
        this.pending.clear();
      };
      this.worker = w;
      if (this.playing) w.postMessage({ type: "pace", playing: true } satisfies MediaWorkerRequest);
      return w;
    } catch {
      return null;
    }
  }

  private onMessage(msg: MediaWorkerResponse): void {
    const p = this.pending.get(msg.id);
    if (!p) {
      if (msg.type === "thumb") msg.bitmap.close();
      return;
    }
    switch (msg.type) {
      case "thumb":
        if (p.kind === "filmstrip") p.onThumb(msg.indices, msg.bitmap);
        else msg.bitmap.close();
        return;
      case "filmstripDone":
        this.pending.delete(msg.id);
        if (p.kind === "filmstrip") p.resolve({ fromCache: msg.fromCache, ms: msg.ms, decoded: msg.decoded });
        return;
      case "envelope":
        this.pending.delete(msg.id);
        if (p.kind === "envelope") p.resolve({ tracks: msg.tracks, fromCache: msg.fromCache, ms: msg.ms });
        return;
      case "error":
        this.pending.delete(msg.id);
        if (import.meta.env.DEV) console.warn(`[timeline media] job ${msg.id}: ${msg.message}`);
        p.resolve(null);
        return;
    }
  }

  filmstrip(
    req: { url: string; cacheKey: string | null; duration: number; count: number; heightPx: number },
    onThumb: (indices: number[], bitmap: ImageBitmap) => void,
  ): FilmstripJob {
    const id = this.nextId++;
    const w = this.ensure();
    if (!w) return { cancel() {}, done: Promise.resolve(null) };
    const done = new Promise<{ fromCache: boolean; ms: number; decoded: number } | null>((resolve) => {
      this.pending.set(id, { kind: "filmstrip", onThumb, resolve });
    });
    w.postMessage({ type: "filmstrip", id, ...req } satisfies MediaWorkerRequest);
    return { cancel: () => this.cancel(id), done };
  }

  envelope(req: { url: string; cacheKey: string | null; tracks: "all" | "first"; gapless: boolean }): {
    cancel(): void;
    done: Promise<{ tracks: (PeakEnvelope | null)[]; fromCache: boolean; ms: number } | null>;
  } {
    const id = this.nextId++;
    const w = this.ensure();
    if (!w) return { cancel() {}, done: Promise.resolve(null) };
    const done = new Promise<{ tracks: (PeakEnvelope | null)[]; fromCache: boolean; ms: number } | null>((resolve) => {
      this.pending.set(id, { kind: "envelope", resolve });
    });
    w.postMessage({ type: "envelope", id, ...req } satisfies MediaWorkerRequest);
    return { cancel: () => this.cancel(id), done };
  }

  private cancel(id: number): void {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    p.resolve(null);
    this.worker?.postMessage({ type: "cancel", id } satisfies MediaWorkerRequest);
  }

  /** Playback running → the worker spaces its decodes out. */
  setPlaying(playing: boolean): void {
    if (this.playing === playing) return;
    this.playing = playing;
    this.worker?.postMessage({ type: "pace", playing } satisfies MediaWorkerRequest);
  }

  dispose(): void {
    this.disposed = true;
    for (const p of this.pending.values()) p.resolve(null);
    this.pending.clear();
    this.worker?.terminate();
    this.worker = null;
  }
}
