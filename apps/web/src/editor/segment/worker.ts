/// <reference lib="webworker" />
/**
 * On-device camera background removal — the browser's twin of the Mac's
 * person-segmentation job (docs/camera-cutout.md §6). Created by
 * segment/client.ts as `new Worker(new URL("./worker.ts", import.meta.url), { type: "module" })`,
 * beside the Whisper worker (transcribe/).
 *
 * Nothing leaves the device but the finished mask: the camera recording is
 * decoded here (mediabunny + WebCodecs) and MODNet runs here (transformers.js
 * `background-removal` on ONNX Runtime Web — WebGPU, else WASM). The only
 * other network traffic is the one-time model download, cached afterwards.
 *
 * Flow: open the camera (byte size + duration: the mask's staleness keys) →
 * the project's existing mask still matches? done → load the model → every
 * decoded camera frame, in presentation order: draw at the model's working
 * size (shortest edge 512) → matte → area-resample to the producer mask
 * resolution (height 192, width round(192 × aspect) ≤ 341) → producer alpha
 * conditioning (dead zone, hold, 8 levels — docs/camera-cutout.md §6, the
 * Mac's CameraMaskConditioning twin) → append to the streaming encoder
 * (frame time = the sample's PTS, as the renderer looks it up) →
 * camera-mask.ccmask bytes back to the main thread.
 */
import { env, pipeline, RawImage } from "@huggingface/transformers";
import { VideoSampleSink } from "mediabunny";

import { maskIsFresh } from "../core/math/cameraCutoutMath";
import { CameraMaskEncoder, CCMASK_HEADER_BYTES, parseCameraMask } from "../core/mask/cameraMaskCodec";
import { conditionAlpha, PRODUCER_KEYFRAME_INTERVAL, producerMaskSize } from "../core/mask/conditionAlpha";
import { resampleAlpha } from "../core/mask/resampleAlpha";
import { DemuxedVideo } from "../engine/media/demux";
import { cameraFileFacts } from "../engine/media/cameraSource";
import { MATTING_DTYPE, MATTING_MODEL, MATTING_SHORTEST_EDGE, type MattingDevice } from "./model";
import type { SegmentReply, SegmentRequest } from "./protocol";

declare const self: DedicatedWorkerGlobalScope;

// Hub only (never probe this site's /models/ path), browser Cache Storage on.
env.allowLocalModels = false;
env.allowRemoteModels = true;
env.useBrowserCache = true;

/** A key frame at least this often (the codec's seek bound) — both producers write 30. */
const KEYFRAME_INTERVAL = PRODUCER_KEYFRAME_INTERVAL;

type Matte = (image: RawImage) => Promise<RawImage | RawImage[]>;

let loaded: { matte: Matte; device: MattingDevice } | null = null;
let loading: Promise<{ matte: Matte; device: MattingDevice }> | null = null;

const post = (msg: SegmentReply, transfer: Transferable[] = []) => self.postMessage(msg, transfer);

async function webgpuUsable(): Promise<boolean> {
  const gpu = (navigator as Navigator & { gpu?: { requestAdapter(): Promise<unknown> } }).gpu;
  if (!gpu) return false;
  try {
    return (await gpu.requestAdapter()) != null;
  } catch {
    return false;
  }
}

const DTYPE_SUFFIX: Record<string, string> = { fp32: "", fp16: "_fp16", q8: "_quantized", q4: "_q4" };

async function weightsCached(device: MattingDevice): Promise<boolean> {
  try {
    const cache = await caches.open(env.cacheKey);
    const urls = (await cache.keys()).map((r) => r.url).filter((u) => u.includes(`/${MATTING_MODEL}/`));
    return urls.some((u) => u.endsWith(`/onnx/model${DTYPE_SUFFIX[MATTING_DTYPE[device]] ?? ""}.onnx`));
  } catch {
    return false;
  }
}

function loadMatte(jobId: number, forced?: MattingDevice): Promise<{ matte: Matte; device: MattingDevice }> {
  if (loaded && (!forced || loaded.device === forced)) return Promise.resolve(loaded);
  loading ??= (async () => {
    const devices: MattingDevice[] = forced ? [forced] : (await webgpuUsable()) ? ["webgpu", "wasm"] : ["wasm"];
    let lastError: unknown = null;
    for (const device of devices) {
      try {
        const cached = await weightsCached(device);
        const matte = (await pipeline("background-removal", MATTING_MODEL, {
          device,
          dtype: MATTING_DTYPE[device] as never,
          progress_callback: (p: { status: string; loaded?: number; total?: number }) => {
            if (!cached && p.status === "progress_total" && p.total && p.loaded !== undefined) {
              post({ type: "progress", jobId, stage: p.loaded < p.total ? "download" : "load", loaded: p.loaded, total: p.total });
            }
          },
        })) as unknown as Matte;
        loaded = { matte, device };
        return loaded;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError instanceof Error ? lastError : new Error(String(lastError));
  })().finally(() => {
    loading = null;
  });
  return loading;
}

/** Is the project's existing mask still the one for this camera file? */
async function existingMaskFresh(url: string | undefined, facts: { byteSize: number | null; duration: number | null }): Promise<boolean> {
  if (!url) return false;
  try {
    // The header is all the check needs; a server that ignores Range sends the whole file.
    const res = await fetch(url, { headers: { Range: `bytes=0-${CCMASK_HEADER_BYTES - 1}` } });
    if (!res.ok) return false;
    const bytes = new Uint8Array(await res.arrayBuffer());
    const header = bytes.length > CCMASK_HEADER_BYTES ? parseCameraMask(bytes).header : parseHeaderOnly(bytes);
    return header !== null && header.frameCount > 0 && maskIsFresh(header, facts);
  } catch {
    return false;
  }
}

function parseHeaderOnly(bytes: Uint8Array): { frameCount: number; sourceDuration: number; sourceByteSize: number } | null {
  if (bytes.length < CCMASK_HEADER_BYTES) return null;
  if (String.fromCharCode(bytes[0]!, bytes[1]!, bytes[2]!, bytes[3]!) !== "CCMK") return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { frameCount: view.getUint32(12, true), sourceDuration: view.getFloat64(16, true), sourceByteSize: view.getFloat64(24, true) };
}

/** The alpha channel of the pipeline's RGBA output (or a 1-channel matte). */
function alphaOf(image: RawImage): Uint8Array {
  const { data, width, height, channels } = image as unknown as { data: Uint8ClampedArray | Uint8Array; width: number; height: number; channels: number };
  const out = new Uint8Array(width * height);
  if (channels === 1) {
    out.set(data);
    return out;
  }
  for (let i = 0, p = channels - 1; i < out.length; i++, p += channels) out[i] = data[p]!;
  return out;
}

async function segment(req: SegmentRequest): Promise<void> {
  const { jobId } = req;
  post({ type: "progress", jobId, stage: "check" });
  const demux = await DemuxedVideo.open(req.cameraUrl);
  try {
    const facts = await cameraFileFacts(demux);
    if (facts.byteSize === null || facts.duration === null) throw new Error("The camera recording's size could not be read.");
    if (await existingMaskFresh(req.maskUrl, facts)) {
      post({ type: "fresh", jobId });
      return;
    }
    if (req.checkOnly) {
      post({ type: "stale", jobId });
      return;
    }

    const t0 = performance.now();
    post({ type: "progress", jobId, stage: "load" });
    let { matte, device } = await loadMatte(jobId, req.device);
    const t1 = performance.now();

    const sw = demux.info.width;
    const sh = demux.info.height;
    const aspect = sh > 0 ? sw / sh : 16 / 9;
    const size = producerMaskSize(aspect);
    // The model's working size: shortest edge 512 (its processor resizes to that anyway).
    const inW = aspect >= 1 ? Math.max(1, Math.round(MATTING_SHORTEST_EDGE * aspect)) : MATTING_SHORTEST_EDGE;
    const inH = aspect >= 1 ? MATTING_SHORTEST_EDGE : Math.max(1, Math.round(MATTING_SHORTEST_EDGE / aspect));
    const canvas = new OffscreenCanvas(inW, inH);
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx) throw new Error("No 2D canvas in this browser's workers.");

    const encoder = new CameraMaskEncoder({
      width: size.width,
      height: size.height,
      keyframeInterval: KEYFRAME_INTERVAL,
      sourceDuration: facts.duration,
      sourceByteSize: facts.byteSize,
    });
    const sink = new VideoSampleSink(demux.track);
    const total = Math.max(1, demux.frames.length);
    const small = new Uint8Array(size.width * size.height);
    /** The previous frame's CONDITIONED alpha (the hold compares against it). */
    let previousAlpha: Uint8Array | null = null;
    let done = 0;
    let lastTime = -Infinity;
    let lastPost = 0;
    for await (const sample of sink.samples()) {
      try {
        // The renderer looks the mask up by the demuxed PTS of the frame it draws.
        const at = demux.frameIndexAt(sample.timestamp);
        const time = at >= 0 ? demux.frames[at]!.pts : sample.timestamp;
        if (!(time > lastTime)) continue;
        ctx.clearRect(0, 0, inW, inH);
        sample.draw(ctx, 0, 0, inW, inH);
        const pixels = ctx.getImageData(0, 0, inW, inH).data;
        const input = new RawImage(pixels, inW, inH, 4);
        let out: RawImage | RawImage[];
        try {
          out = await matte(input);
        } catch (error) {
          // A GPU that loaded the model but cannot run it: once, fall back to WASM.
          if (device !== "webgpu" || req.device) throw error;
          loaded = null;
          ({ matte, device } = await loadMatte(jobId, "wasm"));
          out = await matte(input);
        }
        const image = Array.isArray(out) ? out[0]! : out;
        const alpha = alphaOf(image);
        const w = (image as unknown as { width: number }).width;
        const h = (image as unknown as { height: number }).height;
        const conditioned = conditionAlpha(resampleAlpha(alpha, w, h, size.width, size.height, small), previousAlpha);
        await encoder.add(time, conditioned);
        // `small` is reused next frame — keep a copy for the hold.
        previousAlpha = conditioned.slice();
        lastTime = time;
      } finally {
        sample.close();
      }
      done++;
      const now = performance.now();
      if (now - lastPost > 200) {
        lastPost = now;
        post({ type: "progress", jobId, stage: "segment", fraction: Math.min(1, done / total) });
      }
    }
    if (encoder.frameCount === 0) throw new Error("The camera recording has no frames.");
    post({ type: "progress", jobId, stage: "encode", fraction: 1 });
    const bytes = encoder.finish();
    const buffer = bytes.buffer as ArrayBuffer;
    post(
      {
        type: "done",
        jobId,
        bytes: buffer,
        stats: {
          device,
          frames: encoder.frameCount,
          width: size.width,
          height: size.height,
          bytes: bytes.length,
          loadMs: Math.round(t1 - t0),
          segmentMs: Math.round(performance.now() - t1),
        },
      },
      [buffer],
    );
  } finally {
    demux.dispose();
  }
}

self.onmessage = (event: MessageEvent<SegmentRequest>) => {
  const req = event.data;
  if (req?.type !== "segment") return;
  segment(req).catch((error: unknown) => {
    post({ type: "error", jobId: req.jobId, message: `Background removal failed: ${error instanceof Error ? error.message : String(error)}` });
  });
};
