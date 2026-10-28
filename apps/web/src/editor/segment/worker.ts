/// <reference lib="webworker" />
/**
 * On-device camera background removal — the browser's twin of the Mac's
 * person-segmentation job (docs/camera-cutout.md §6). Created by
 * segment/client.ts as `new Worker(new URL("./worker.ts", import.meta.url), { type: "module" })`,
 * beside the Whisper worker (transcribe/).
 *
 * Nothing leaves the device but the finished mask: the camera recording is
 * decoded here (mediabunny + WebCodecs) and MediaPipe's multiclass selfie
 * segmenter runs here (@mediapipe/tasks-vision — GPU delegate, else CPU;
 * segment/model.ts says why this model). The only other network traffic is
 * the one-time model and runtime download, cached afterwards.
 *
 * Flow: open the camera (byte size + duration: the mask's staleness keys) →
 * the project's existing mask still matches? done → load the model → every
 * decoded camera frame, in presentation order: draw at the working size
 * (shortest edge MATTING_SHORTEST_EDGE) → person confidence (1 − background)
 * → area-resample to the producer mask
 * resolution (height 192, width round(192 × aspect) ≤ 341) → producer alpha
 * conditioning (dead zone, hold, 8 levels — docs/camera-cutout.md §6, the
 * Mac's CameraMaskConditioning twin) → append to the streaming encoder
 * (frame time = the sample's PTS, as the renderer looks it up) →
 * camera-mask.ccmask bytes back to the main thread.
 */
import { ImageSegmenter } from "@mediapipe/tasks-vision";
import { VideoSampleSink } from "mediabunny";

import { maskIsFresh } from "../core/math/cameraCutoutMath";
import { CameraMaskEncoder, CCMASK_HEADER_BYTES, parseCameraMask } from "../core/mask/cameraMaskCodec";
import { conditionAlpha, PRODUCER_KEYFRAME_INTERVAL, producerMaskSize } from "../core/mask/conditionAlpha";
import { resampleAlpha } from "../core/mask/resampleAlpha";
import { DemuxedVideo } from "../engine/media/demux";
import { cameraFileFacts } from "../engine/media/cameraSource";
import { MATTING_SHORTEST_EDGE, MODEL_CACHE, SEGMENTER_MODEL_URL, SEGMENTER_RUNTIME, personAlpha, type MattingDevice } from "./model";
import type { SegmentReply, SegmentRequest } from "./protocol";

declare const self: DedicatedWorkerGlobalScope;

/** A key frame at least this often (the codec's seek bound) — both producers write 30. */
const KEYFRAME_INTERVAL = PRODUCER_KEYFRAME_INTERVAL;

/** One frame in, the person alpha (0–255, `width × height`) out. */
type Matte = (frame: OffscreenCanvas, timestampMs: number) => { alpha: Uint8Array; width: number; height: number };

let loaded: { matte: Matte; device: MattingDevice; close: () => void } | null = null;
let loading: Promise<{ matte: Matte; device: MattingDevice; close: () => void }> | null = null;

const post = (msg: SegmentReply, transfer: Transferable[] = []) => self.postMessage(msg, transfer);

/** The model bytes: Cache Storage first, else downloaded once (with progress) and kept. */
async function modelBytes(jobId: number): Promise<Uint8Array> {
  const cache = await caches.open(MODEL_CACHE).catch(() => null);
  const hit = await cache?.match(SEGMENTER_MODEL_URL);
  if (hit) return new Uint8Array(await hit.arrayBuffer());
  const res = await fetch(SEGMENTER_MODEL_URL);
  if (!res.ok || !res.body) throw new Error(`The background-removal model could not be downloaded (HTTP ${res.status}).`);
  const total = Number(res.headers.get("Content-Length")) || 0;
  const chunks: Uint8Array[] = [];
  let received = 0;
  let lastPost = 0;
  const reader = res.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    received += value.byteLength;
    const now = performance.now();
    if (total && now - lastPost > 150) {
      lastPost = now;
      post({ type: "progress", jobId, stage: "download", loaded: received, total });
    }
  }
  const bytes = new Uint8Array(received);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.byteLength;
  }
  await cache?.put(SEGMENTER_MODEL_URL, new Response(bytes, { headers: { "Content-Type": "application/octet-stream" } })).catch(() => undefined);
  return bytes;
}

function loadMatte(jobId: number, forced?: MattingDevice): Promise<{ matte: Matte; device: MattingDevice; close: () => void }> {
  if (loaded && (!forced || loaded.device === forced)) return Promise.resolve(loaded);
  loading ??= (async () => {
    const model = await modelBytes(jobId);
    post({ type: "progress", jobId, stage: "load" });
    const devices: MattingDevice[] = forced ? [forced] : ["gpu", "cpu"];
    let lastError: unknown = null;
    for (const device of devices) {
      try {
        const segmenter = await ImageSegmenter.createFromOptions(SEGMENTER_RUNTIME, {
          baseOptions: { modelAssetBuffer: model, delegate: device === "gpu" ? "GPU" : "CPU" },
          runningMode: "VIDEO",
          outputConfidenceMasks: true,
          outputCategoryMask: false,
        });
        const matte: Matte = (frame, timestampMs) => {
          const result = segmenter.segmentForVideo(frame, timestampMs);
          try {
            // Category 0 is the background: the person is everything else.
            const background = result.confidenceMasks?.[0];
            if (!background) throw new Error("The segmenter returned no mask.");
            const alpha = personAlpha(background.getAsFloat32Array());
            return { alpha, width: background.width, height: background.height };
          } finally {
            result.close();
          }
        };
        loaded = { matte, device, close: () => segmenter.close() };
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
    // The working size handed to the model (it resizes to 256×256 itself).
    const inW = aspect >= 1 ? Math.max(1, Math.round(MATTING_SHORTEST_EDGE * aspect)) : MATTING_SHORTEST_EDGE;
    const inH = aspect >= 1 ? MATTING_SHORTEST_EDGE : Math.max(1, Math.round(MATTING_SHORTEST_EDGE / aspect));
    const canvas = new OffscreenCanvas(inW, inH);
    const ctx = canvas.getContext("2d");
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
        // VIDEO mode wants strictly increasing timestamps (ms): the PTS is.
        let out: ReturnType<Matte>;
        try {
          out = matte(canvas, time * 1000);
        } catch (error) {
          // A GPU that loaded the model but cannot run it: once, fall back to the CPU.
          if (device !== "gpu" || req.device) throw error;
          loaded?.close();
          loaded = null;
          ({ matte, device } = await loadMatte(jobId, "cpu"));
          out = matte(canvas, time * 1000);
        }
        const conditioned = conditionAlpha(resampleAlpha(out.alpha, out.width, out.height, size.width, size.height, small), previousAlpha);
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
