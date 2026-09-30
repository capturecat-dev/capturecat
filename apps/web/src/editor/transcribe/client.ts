/**
 * Main-thread handle on the transcription worker (transcribe/worker.ts).
 *
 * One job at a time. The worker — and the model it has loaded — stays warm
 * for a minute after a job (Regenerate reuses it), then is released so an
 * idle editor does not hold ~300 MB of model on the GPU the renderer shares
 * (the next run reloads it from the browser cache in about a second).
 * Cancelling TERMINATES the worker:
 * a Whisper window cannot be interrupted mid-decode, and a user who pressed
 * Cancel should get their GPU back now, not in ten seconds. The next job
 * starts a fresh worker, which reloads the model from the browser cache.
 */
import {
  TranscriptionCancelled,
  type TranscribeOptions,
  type TranscribeProgress,
  type TranscribeReply,
  type TranscribeRequest,
  type Transcriber,
  type TranscriptionResult,
} from "./protocol";

/** How long a finished worker keeps its model loaded. */
const IDLE_RELEASE_MS = 60_000;

export class TranscriptionClient implements Transcriber {
  private worker: Worker | null = null;
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private nextJob = 1;
  private pending: {
    jobId: number;
    resolve(r: TranscriptionResult): void;
    reject(e: unknown): void;
    onProgress?(p: TranscribeProgress): void;
  } | null = null;

  private ensureWorker(): Worker {
    if (this.worker) return this.worker;
    const worker = new Worker(new URL("./worker.ts", import.meta.url), { type: "module", name: "capturecat-transcribe" });
    worker.onmessage = (event: MessageEvent<TranscribeReply>) => this.receive(event.data);
    worker.onerror = (event) => {
      event.preventDefault();
      this.fail(new Error(`Transcription failed: ${event.message || "the speech worker stopped."}`));
      this.terminate();
    };
    this.worker = worker;
    return worker;
  }

  private receive(msg: TranscribeReply) {
    const job = this.pending;
    if (!job || msg.jobId !== job.jobId) return;
    if (msg.type === "progress") job.onProgress?.(msg);
    else {
      this.pending = null;
      this.scheduleRelease();
      if (msg.type === "done") job.resolve({ words: msg.words, stats: msg.stats });
      else job.reject(new Error(msg.message));
    }
  }

  private scheduleRelease() {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null;
      if (!this.pending) this.terminate();
    }, IDLE_RELEASE_MS);
  }

  private fail(error: unknown) {
    const job = this.pending;
    this.pending = null;
    job?.reject(error);
  }

  private terminate() {
    this.worker?.terminate();
    this.worker = null;
  }

  transcribe(url: string, options: TranscribeOptions = {}): Promise<TranscriptionResult> {
    if (options.signal?.aborted) return Promise.reject(new TranscriptionCancelled());
    // A new job supersedes one still running (the caller guards against it).
    if (this.pending) this.cancel();
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
    const jobId = this.nextJob++;
    return new Promise<TranscriptionResult>((resolve, reject) => {
      this.pending = { jobId, resolve, reject, onProgress: options.onProgress };
      options.signal?.addEventListener("abort", () => this.pending?.jobId === jobId && this.cancel(), { once: true });
      // Absolute: a worker has no `window` to resolve a page-relative media
      // URL against (mediabunny's non-range fallback builds `new URL(url)`).
      const absolute = typeof location !== "undefined" ? new URL(url, location.href).href : url;
      const req: TranscribeRequest = { type: "transcribe", jobId, url: absolute, device: options.device };
      this.ensureWorker().postMessage(req);
    });
  }

  /** Stops the running job now (its promise rejects with TranscriptionCancelled). */
  cancel(): void {
    if (!this.pending) return;
    this.terminate();
    this.fail(new TranscriptionCancelled());
  }

  dispose(): void {
    this.cancel();
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
    this.terminate();
  }
}
