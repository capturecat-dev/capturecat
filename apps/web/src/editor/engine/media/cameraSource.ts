/**
 * The webcam recording as a SECOND decode stream beside the screen recording
 * (the Mac exporter's `cameraReader`), plus frame selection:
 *
 *   camera time = timeline source time − project.cameraTimeOffset
 *   frame       = last sample with PTS ≤ CMTime(camera time, 600)  (truncating)
 *
 * EXPORT (exact, `prefetch`): the Mac reader only ever walks FORWARD — a
 * backwards source jump (clip reorder) keeps the last decoded frame — so the
 * exporter path keeps a monotonic cursor (core `CameraReaderCursor` rule) and
 * awaits the exact frame. PREVIEW: random access by time, decode-ahead while
 * playing, the last shown frame stays up until the wanted one decodes (like
 * the screen stream), and a decode landing re-renders.
 */
import { cmTimeValue600 } from "../../core/math/exportCameraBubble";
import { DemuxedVideo } from "./demux";
import { VideoStream } from "./videoStream";

export interface CameraFrame {
  index: number;
  frame: VideoFrame;
}

export class CameraSource {
  readonly ready: Promise<void>;
  private demux: DemuxedVideo | null = null;
  private stream: VideoStream | null = null;
  private failed: Error | null = null;
  private disposed = false;
  /** Frame currently on screen (pinned in the cache while shown). */
  private shown: CameraFrame | null = null;
  /** Export: highest sample consumed so far (forward-only reader). */
  private cursor = -1;
  /** Preview counters: frames shown exact vs stale (the wanted one still decoding). */
  readonly counters = { exact: 0, stale: 0, staleWhilePlaying: 0 };

  constructor(
    readonly url: string,
    private readonly opts: { onFrame?: () => void; onError?: (e: Error) => void; label?: string; cacheBytes?: number },
  ) {
    this.ready = this.open();
  }

  private async open(): Promise<void> {
    try {
      const demux = await DemuxedVideo.open(this.url);
      if (this.disposed) {
        demux.dispose();
        return;
      }
      this.demux = demux;
      this.stream = new VideoStream(demux, {
        label: this.opts.label ?? "camera",
        lookahead: 6,
        cacheBytes: this.opts.cacheBytes ?? 64 * 1024 * 1024,
        onFrame: () => this.opts.onFrame?.(),
        onError: (e) => this.opts.onError?.(e),
      });
    } catch (e) {
      this.failed = e instanceof Error ? e : new Error(String(e));
      this.opts.onError?.(this.failed);
    }
  }

  /** The camera track opened (Mac: `cameraReader != nil`). */
  get isOpen(): boolean {
    return this.stream !== null;
  }

  get error(): Error | null {
    return this.failed;
  }

  /** Track display size (Mac: camTrack.naturalSize). */
  get naturalSize(): { width: number; height: number } {
    return this.demux ? { width: this.demux.info.width, height: this.demux.info.height } : { width: 0, height: 0 };
  }

  get stats() {
    return this.stream?.getStats() ?? null;
  }

  /** Sample index for a camera time (−1 before the first sample). */
  indexAt(cameraTime: number): number {
    if (!this.demux || cameraTime < 0) return -1;
    return this.demux.frameIndexAt(Number(cmTimeValue600(cameraTime)) / 600);
  }

  /** Loop-aware prefetch over the camera span the timeline loop covers. */
  setLoop(range: { start: number; end: number } | null): void {
    this.stream?.setLoop(range);
  }

  /**
   * PREVIEW: the frame to show for `cameraTime`. Returns the exact frame when
   * decoded, else the last shown frame (stale while decoding), else null.
   */
  preview(cameraTime: number, playing: boolean): CameraFrame | null {
    const stream = this.stream;
    if (!stream || cameraTime < 0) return null;
    const idx = this.indexAt(cameraTime);
    if (idx < 0) return null;
    stream.setTarget(idx, playing);
    const exact = stream.frame(idx);
    if (exact) {
      this.counters.exact++;
      return this.show({ index: idx, frame: exact });
    }
    this.counters.stale++;
    if (playing) this.counters.staleWhilePlaying++;
    return this.shown;
  }

  /**
   * EXPORT: advance the forward-only reader to `cameraTime` and wait for that
   * frame. A negative time does not advance (the frame draws the poster).
   */
  async exact(cameraTime: number): Promise<CameraFrame | null> {
    await this.ready;
    const stream = this.stream;
    if (!stream) return null;
    if (cameraTime >= 0) this.cursor = Math.max(this.cursor, this.indexAt(cameraTime));
    if (this.cursor < 0 || cameraTime < 0) return null;
    const idx = this.cursor;
    const frame = await stream.waitFor(idx, true);
    return this.show({ index: idx, frame });
  }

  private show(f: CameraFrame): CameraFrame {
    const stream = this.stream!;
    if (this.shown?.index !== f.index) {
      stream.cache.pin(f.index);
      if (this.shown) stream.cache.unpin(this.shown.index);
    }
    this.shown = f;
    return f;
  }

  dispose(): void {
    this.disposed = true;
    this.shown = null;
    this.stream?.dispose();
    this.demux?.dispose();
    this.stream = null;
    this.demux = null;
  }
}
