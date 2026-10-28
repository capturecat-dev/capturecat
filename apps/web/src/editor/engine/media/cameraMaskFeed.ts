/**
 * The camera person mask (camera-mask.ccmask, docs/camera-cutout.md §2) as a
 * per-renderer feed: decoded frames by index, the GPU texture the camera
 * shaders sample.
 *
 *  - Lookup: by the PTS of the camera frame actually DRAWN (never the target
 *    time), `frameIndexAt` (last frame ≤ t, clamped to 0) — with the demuxer's
 *    PTS tolerance so a float-noise PTS cannot land on the previous frame.
 *  - Decode is async (DecompressionStream), so the feed decodes AHEAD of the
 *    playhead (the decoder's cursor walks forward: one inflate per frame) and
 *    keeps a small cache; `prefetch` (export) awaits the exact frame; the
 *    preview's seek gate waits until the drawn frame's mask is decoded.
 *  - One decoder, one queue: `CameraMaskDecoder` is a stateful cursor, so
 *    every decode is serialized.
 *  - GPU: one r8unorm texture of the mask size, rewritten only when the frame
 *    changes (no per-frame allocation — the cache's arrays are reused).
 */
import { CameraMaskDecoder, frameIndexAt, type CameraMaskTrack } from "../../core/mask/cameraMaskCodec";
import { PTS_EPSILON } from "./demux";

/** Frames kept decoded (playback reads ahead; a scrub reuses recent ones). */
const CACHE_FRAMES = 16;
/** Frames decoded ahead of the one the preview draws. */
const LOOKAHEAD = 4;

export class CameraMaskFeed {
  readonly width: number;
  readonly height: number;
  private readonly decoder: CameraMaskDecoder;
  private readonly cache = new Map<number, Uint8Array>();
  /** Spare buffers from evicted frames (no allocation once warm). */
  private readonly spare: Uint8Array[] = [];
  private readonly pending = new Map<number, Promise<Uint8Array>>();
  private queue: Promise<unknown> = Promise.resolve();
  private failed = false;
  private texture: { texture: GPUTexture; view: GPUTextureView; index: number } | null = null;

  constructor(
    readonly track: CameraMaskTrack,
    private readonly onDecoded: () => void = () => {},
  ) {
    this.width = track.header.width;
    this.height = track.header.height;
    this.decoder = new CameraMaskDecoder(track);
  }

  get frameCount(): number {
    return this.track.header.frameCount;
  }

  get broken(): boolean {
    return this.failed;
  }

  /** Mask frame for a drawn camera sample at `pts` seconds (−1: empty track). */
  indexForPts(pts: number): number {
    return frameIndexAt(this.track.index, pts + PTS_EPSILON);
  }

  /** The decoded alpha of frame `i`, if it is in the cache (kicks a decode otherwise). */
  peek(i: number): Uint8Array | null {
    const hit = this.cache.get(i);
    if (hit) return hit;
    void this.load(i).catch(() => undefined);
    return null;
  }

  /** Preview: decode `i` and the next few, in order (one inflate each). */
  readAhead(i: number): void {
    for (let k = i; k < Math.min(this.frameCount, i + 1 + LOOKAHEAD); k++) {
      if (!this.cache.has(k)) void this.load(k).catch(() => undefined);
    }
  }

  /** Decode frame `i` (serialized with every other decode). */
  load(i: number): Promise<Uint8Array> {
    const hit = this.cache.get(i);
    if (hit) return Promise.resolve(hit);
    const inflight = this.pending.get(i);
    if (inflight) return inflight;
    const job = this.queue.then(async () => {
      const cached = this.cache.get(i);
      if (cached) return cached;
      const alpha = await this.decoder.frame(i);
      const copy = this.spare.pop() ?? new Uint8Array(alpha.length);
      copy.set(alpha);
      this.store(i, copy);
      return copy;
    });
    this.pending.set(i, job);
    this.queue = job.catch(() => undefined);
    job.then(
      () => {
        this.pending.delete(i);
        this.onDecoded();
      },
      (error) => {
        this.pending.delete(i);
        if (!this.failed) console.warn(`[camera] person mask frame ${i} failed to decode: ${String(error)}`);
        this.failed = true;
        this.onDecoded();
      },
    );
    return job;
  }

  private store(i: number, alpha: Uint8Array): void {
    this.cache.set(i, alpha);
    while (this.cache.size > CACHE_FRAMES) {
      // Evict the frame farthest from the one just decoded (never the texture's).
      let far = -1;
      let farDist = -1;
      for (const k of this.cache.keys()) {
        if (k === i || k === this.texture?.index) continue;
        const d = Math.abs(k - i);
        if (d > farDist) {
          far = k;
          farDist = d;
        }
      }
      if (far < 0) break;
      const freed = this.cache.get(far)!;
      this.cache.delete(far);
      this.spare.push(freed);
    }
  }

  /** The texture currently holds frame (−1: nothing uploaded yet). */
  get uploadedIndex(): number {
    return this.texture?.index ?? -1;
  }

  /**
   * The GPU view for frame `i`: uploads it when decoded and not already
   * there. Falls back to whatever the texture last held (a decode still on its
   * way — the seek gate holds a seek until it lands); an all-zero mask before
   * the first upload.
   */
  view(device: GPUDevice, i: number): GPUTextureView {
    if (!this.texture) {
      const texture = device.createTexture({
        label: "camera-person-mask",
        size: { width: this.width, height: this.height },
        format: "r8unorm",
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
      });
      this.texture = { texture, view: texture.createView(), index: -1 };
    }
    const t = this.texture;
    if (t.index !== i) {
      const alpha = this.cache.get(i);
      if (alpha) {
        device.queue.writeTexture({ texture: t.texture }, alpha as Uint8Array<ArrayBuffer>, { bytesPerRow: this.width }, { width: this.width, height: this.height });
        t.index = i;
      }
    }
    return t.view;
  }

  dispose(device?: GPUDevice): void {
    const t = this.texture;
    this.texture = null;
    if (t) {
      if (device) void device.queue.onSubmittedWorkDone().then(() => t.texture.destroy());
      else t.texture.destroy();
    }
    this.cache.clear();
    this.spare.length = 0;
  }
}
