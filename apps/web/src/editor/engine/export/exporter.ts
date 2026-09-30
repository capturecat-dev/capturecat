/**
 * Web exporter (skeleton) — the SAME FrameGraph + passes as the preview,
 * rendered into an export-sized OffscreenCanvas, stepped at the project fps
 * on the OUTPUT timeline exactly like `VideoExporter.exportFrameTimes`, and
 * encoded with WebCodecs `VideoEncoder` → mediabunny MP4.
 *
 * Mirrors the Mac:
 *  - frame i is output time i / fps; its source frame is the last sample with
 *    PTS ≤ CMTime(sourceTime, 600) (the reader walk in the export loop);
 *  - HEVC when the browser can encode it (the Mac always writes HEVC), H.264
 *    otherwise; bitrate from `estimatedVideoBitRate`;
 *  - colour tags follow the SOURCE: P3-D65 or BT.709 primaries, sRGB transfer,
 *    BT.709 matrix (`VideoColorTags.colorProperties`).
 *  - audio: the project's mix (export/audioExport.ts — the ProjectAudioMix
 *    port rendered by the same renderer playback uses), AAC 48 kHz stereo
 *    192 kbps, pumped ~1 s ahead of the video frames;
 *  - container: MOV for "MOV", MPEG-4 otherwise (the Mac's writer uses
 *    `.mp4` for its "GIF" format too — a Mac bug, ported as-is).
 * Not yet: static-span collapse (VFR).
 */
import { BufferTarget, EncodedPacket, EncodedVideoPacketSource, MovOutputFormat, Mp4OutputFormat, Output } from "mediabunny";
import type { AudioMixRenderer } from "../audio/mixer";
import { AudioExport, type AudioExportInfo } from "./audioExport";
import type { WorkingSpace } from "../color";
import type { RenderProject } from "../contract";
import { configureCanvas, type GpuContext } from "../gpu/device";
import { encodeCopy, type PendingReadback } from "../gpu/readback";
import { cardGeometry, cmTime600, estimatedVideoBitRate, exportFrameCount, resolvedOutputSize } from "../layout";
import { IDENTITY } from "../mat3";
import type { DemuxedVideo } from "../media/demux";
import { VideoStream } from "../media/videoStream";
import { FrameGraph } from "../passes/frameGraph";
import type { Scene, SceneExtras } from "../passes/types";
import { buildCameraPath, cameraStateAt } from "../camera";
import type { FrameState } from "../passes/types";
import type { ExportOptions, ExportResult } from "../protocol";
import type { TimeMap } from "../time";

interface ExportArgs {
  gpu: GpuContext;
  media: DemuxedVideo;
  project: RenderProject;
  timeMap: TimeMap;
  /** The preview engine's scene extras — the SAME project data every pass reads. */
  extras: SceneExtras;
  workingSpace: WorkingSpace;
  options: ExportOptions;
  onProgress: (done: number, total: number) => void;
  /** The project's audio mix (null: no audio track). */
  audio?: AudioMixRenderer | null;
  /** Polled every frame; true stops the export with `ExportCancelledError`. */
  cancelled?: () => boolean;
}

/** Thrown when `cancelled()` turns true mid-export (worker error code "cancelled"). */
export class ExportCancelledError extends Error {
  readonly code = "cancelled";
  constructor() {
    super("Export cancelled.");
    this.name = "ExportCancelledError";
  }
}

async function pickCodec(
  pref: ExportOptions["codec"],
  width: number,
  height: number,
  fps: number,
  bitrate: number,
): Promise<{ config: VideoEncoderConfig; container: "hevc" | "avc" }> {
  const big = width * height > 1920 * 1080;
  const candidates: { config: VideoEncoderConfig; container: "hevc" | "avc" }[] = [];
  const base = { width, height, bitrate, framerate: fps, bitrateMode: "variable" as const, latencyMode: "quality" as const };
  if (pref !== "avc") {
    candidates.push({
      container: "hevc",
      config: { ...base, codec: big ? "hvc1.1.6.L153.B0" : "hvc1.1.6.L123.B0", hevc: { format: "hevc" } } as VideoEncoderConfig,
    });
  }
  if (pref !== "hevc") {
    candidates.push({
      container: "avc",
      config: { ...base, codec: big ? "avc1.640034" : "avc1.64002A", avc: { format: "avc" } },
    });
  }
  for (const c of candidates) {
    const r = await VideoEncoder.isConfigSupported(c.config).catch(() => null);
    if (r?.supported) return c;
  }
  throw new Error("This browser cannot encode HEVC or H.264 video at this size.");
}

export async function exportVideo(args: ExportArgs): Promise<ExportResult> {
  const { gpu, media, project, timeMap, extras, workingSpace, options, onProgress } = args;
  const t0 = performance.now();
  const settings = project.settings;
  const sourceSize = { width: media.info.width, height: media.info.height };
  const out =
    options.width && options.height
      ? { width: options.width, height: options.height }
      : resolvedOutputSize(settings.exportSettings, settings.aspectRatio, sourceSize);
  const fps = Math.max(1, Math.round(options.fps ?? settings.exportSettings.fps));
  const start = Math.max(0, options.start ?? 0);
  const end = Math.min(timeMap.outputDuration, options.end ?? timeMap.outputDuration);
  const total = exportFrameCount(Math.max(0.0001, end - start), fps);
  const bitrate = options.bitrate ?? estimatedVideoBitRate({ ...settings.exportSettings, fps }, out);
  const { config, container } = await pickCodec(options.codec ?? "auto", out.width, out.height, fps, bitrate);

  // Same passes, own target: an export-sized canvas in the working space.
  const canvas = new OffscreenCanvas(out.width, out.height);
  const context = canvas.getContext("webgpu");
  if (!context) throw new Error("WebGPU canvas unavailable for export");
  configureCanvas(context, gpu, workingSpace);
  const graph = new FrameGraph(gpu);
  const scene: Scene = {
    version: 1,
    target: out,
    targetFormat: gpu.preferredFormat,
    workingSpace,
    settings,
    sourceSize,
    geometry: cardGeometry(sourceSize, out, settings, options.reference ?? null),
    // The Mac renders the export backdrop at scale 1 (createBackground).
    extras: { ...extras, fps, pixelScale: 1 },
  };
  // Same camera path as the preview; rebuilt only if the export fps differs.
  const cameraPath =
    extras.fps === fps || !extras.project
      ? extras.cameraPath
      : buildCameraPath(extras.project, extras.assets, timeMap, fps, sourceSize, out);
  scene.extras.cameraPath = cameraPath;
  graph.setScene(scene);
  const stream = new VideoStream(media, { lookahead: 8, cacheBytes: 160 * 1024 * 1024, label: "export" });

  const format = options.format === "MOV" ? new MovOutputFormat({ fastStart: "in-memory" }) : new Mp4OutputFormat({ fastStart: "in-memory" });
  const output = new Output({ format, target: new BufferTarget() });
  const source = new EncodedVideoPacketSource(container);
  output.addVideoTrack(source, { frameRate: fps });
  const audio =
    options.audio !== false && args.audio
      ? await AudioExport.attach(
          output,
          args.audio,
          { startFrame: Math.round(start * 48_000), endFrame: Math.round(end * 48_000) },
          !!options.captureAudio,
        )
      : null;
  await output.start();

  let muxChain: Promise<void> = Promise.resolve();
  let encodeError: Error | null = null;
  const colorTags: VideoColorSpaceInit = {
    // "smpte432" (P3-D65) is valid WebCodecs but missing from TS lib.dom.
    primaries: (workingSpace === "display-p3" ? "smpte432" : "bt709") as VideoColorPrimaries,
    transfer: "iec61966-2-1",
    matrix: "bt709",
    fullRange: false,
  };
  const encoder = new VideoEncoder({
    output: (chunk, meta) => {
      const packet = EncodedPacket.fromEncodedChunk(chunk);
      const m: EncodedVideoChunkMetadata | undefined = meta?.decoderConfig
        ? {
            ...meta,
            decoderConfig: {
              ...meta.decoderConfig,
              // Keep the encoder's own matrix/range report; tag primaries +
              // transfer like the source (the Mac's VideoColorTags).
              colorSpace: {
                ...colorTags,
                matrix: meta.decoderConfig.colorSpace?.matrix ?? colorTags.matrix,
                fullRange: meta.decoderConfig.colorSpace?.fullRange ?? colorTags.fullRange,
              },
            },
          }
        : meta;
      muxChain = muxChain.then(() => source.add(packet, m));
    },
    error: (e) => (encodeError = new Error(`VideoEncoder: ${e.message}`)),
  });
  encoder.configure(config);

  const sourceIndices: number[] = [];
  const captures: { frame: number; rgba: ArrayBuffer }[] = [];
  const pendingCaptures: { frame: number; copy: PendingReadback }[] = [];
  const captureSet = new Set(options.captureFrames ?? []);
  const keyEvery = fps * 2;
  const waitDequeue = () => new Promise<void>((r) => encoder.addEventListener("dequeue", () => r(), { once: true }));

  let audioInfo: AudioExportInfo | null = null;
  try {
    for (let i = 0; i < total; i++) {
      if (encodeError) throw encodeError;
      if (args.cancelled?.()) throw new ExportCancelledError();
      // Keep the audio ~1 s ahead of the video (both tracks interleave in the mux).
      if (audio) await audio.pump(i / fps + 1);
      const t = start + i / fps;
      const src = timeMap.sourceTime(t);
      const idx = timeMap.hasVisibleVideo(src) ? media.frameIndexAt(cmTime600(src)) : -1;
      sourceIndices.push(idx);
      let video: { frame: VideoFrame; index: number } | null = null;
      if (idx >= 0) {
        const frame = await stream.waitFor(idx, true);
        stream.cache.pin(idx);
        video = { frame, index: idx };
      }
      const state: FrameState = {
        outputTime: t,
        sourceTime: src,
        video,
        ...cameraStateAt(cameraPath, scene.geometry, extras.project?.settings ?? null, t),
      };
      // Second decode streams (the webcam) resolve their exact frame first.
      await graph.prefetch(state);
      const texture = context.getCurrentTexture();
      graph.render(
        state,
        { texture, view: texture.createView(), format: gpu.preferredFormat },
        captureSet.has(i) ? (enc) => void pendingCaptures.push({ frame: i, copy: encodeCopy(gpu.device, enc, texture) }) : undefined,
      );
      const vf = new VideoFrame(canvas, {
        timestamp: Math.round((i * 1e6) / fps),
        duration: Math.round(1e6 / fps),
      });
      if (idx >= 0) stream.cache.unpin(idx);
      while (encoder.encodeQueueSize > 4) await waitDequeue();
      encoder.encode(vf, { keyFrame: i % keyEvery === 0 });
      vf.close();
      if (i % 10 === 0 || i === total - 1) onProgress(i + 1, total);
    }
    await encoder.flush();
    if (encodeError) throw encodeError;
    await muxChain;
    if (audio) audioInfo = await audio.finish();
    if (args.cancelled?.()) throw new ExportCancelledError();
    await output.finalize();
    for (const c of pendingCaptures) {
      const px = await c.copy.read();
      captures.push({ frame: c.frame, rgba: px.rgba.buffer as ArrayBuffer });
    }
  } catch (e) {
    if (output.state === "started") await output.cancel().catch(() => undefined);
    throw e;
  } finally {
    if (encoder.state !== "closed") encoder.close();
    audio?.close();
    stream.dispose();
    graph.destroy();
  }

  const buffer = (output.target as BufferTarget).buffer;
  if (!buffer) throw new Error("Export produced no data");
  return {
    buffer,
    mimeType: options.format === "MOV" ? "video/quicktime" : "video/mp4",
    codec: config.codec,
    width: out.width,
    height: out.height,
    fps,
    frames: total,
    encodeMs: performance.now() - t0,
    sourceIndices,
    captures,
    audio: audioInfo,
  };
}
