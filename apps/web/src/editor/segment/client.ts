/**
 * Main-thread handle on the camera segmentation worker (segment/worker.ts).
 *
 * One job at a time. Like the transcription client, the worker (and the
 * matting model it loaded) stays warm for a minute after a job, then is
 * released so an idle editor does not hold the model on the GPU the renderer
 * shares. Cancelling TERMINATES the worker — a model run cannot be
 * interrupted mid-frame, and a user who pressed Cancel gets the GPU back now.
 */
import {
  SegmentationCancelled,
  type SegmentOptions,
  type SegmentProgress,
  type SegmentReply,
  type SegmentRequest,
  type SegmentResult,
  type Segmenter,
} from "./protocol";

const IDLE_RELEASE_MS = 60_000;

export class SegmentationClient implements Segmenter {
  private worker: Worker | null = null;
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private nextJob = 1;
  private pending: {
    jobId: number;
    resolve(r: SegmentResult): void;
    reject(e: unknown): void;
    onProgress?(p: SegmentProgress): void;
  } | null = null;

  private ensureWorker(): Worker {
    if (this.worker) return this.worker;
    const worker = new Worker(new URL("./worker.ts", import.meta.url), { type: "module", name: "capturecat-segment" });
    worker.onmessage = (event: MessageEvent<SegmentReply>) => this.receive(event.data);
    worker.onerror = (event) => {
      event.preventDefault();
      this.fail(new Error(`Background removal failed: ${event.message || "the segmentation worker stopped."}`));
      this.terminate();
    };
    this.worker = worker;
    return worker;
  }

  private receive(msg: SegmentReply) {
    const job = this.pending;
    if (!job || msg.jobId !== job.jobId) return;
    if (msg.type === "progress") {
      job.onProgress?.(msg);
      return;
    }
    this.pending = null;
    this.scheduleRelease();
    if (msg.type === "done") job.resolve({ kind: "done", bytes: new Uint8Array(msg.bytes), stats: msg.stats });
    else if (msg.type === "fresh") job.resolve({ kind: "fresh" });
    else if (msg.type === "stale") job.resolve({ kind: "stale" });
    else job.reject(new Error(msg.message));
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

  segment(cameraUrl: string, options: SegmentOptions = {}): Promise<SegmentResult> {
    if (options.signal?.aborted) return Promise.reject(new SegmentationCancelled());
    if (this.pending) this.cancel();
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
    const jobId = this.nextJob++;
    return new Promise<SegmentResult>((resolve, reject) => {
      this.pending = { jobId, resolve, reject, onProgress: options.onProgress };
      options.signal?.addEventListener("abort", () => this.pending?.jobId === jobId && this.cancel(), { once: true });
      // Absolute: a worker has no page to resolve a relative media URL against.
      const abs = (u: string) => (typeof location !== "undefined" ? new URL(u, location.href).href : u);
      const req: SegmentRequest = {
        type: "segment",
        jobId,
        cameraUrl: abs(cameraUrl),
        maskUrl: options.maskUrl ? abs(options.maskUrl) : undefined,
        checkOnly: options.checkOnly,
        device: options.device,
      };
      this.ensureWorker().postMessage(req);
    });
  }

  /** Stops the running job now (its promise rejects with SegmentationCancelled). */
  cancel(): void {
    if (!this.pending) return;
    this.terminate();
    this.fail(new SegmentationCancelled());
  }

  dispose(): void {
    this.cancel();
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
    this.terminate();
  }
}
