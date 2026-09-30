/**
 * Web exporter — the SAME FrameGraph + passes as the preview, rendered into
 * an export-sized OffscreenCanvas, stepped on the OUTPUT timeline exactly
 * like `VideoExporter.exportFrameTimes`. Three outputs, one render path:
 *
 *  - MP4 / MOV: WebCodecs `VideoEncoder` → mediabunny. Mirrors the Mac:
 *    frame i is output time i / fps; its source frame is the last sample with
 *    PTS ≤ CMTime(sourceTime, 600) (the reader walk in the export loop); HEVC
 *    when the browser can encode it (the Mac always writes HEVC), H.264
 *    otherwise; bitrate from `estimatedVideoBitRate`; colour tags follow the
 *    SOURCE (P3-D65 or BT.709 primaries, sRGB transfer, BT.709 matrix —
 *    `VideoColorTags.colorProperties`); the project's audio mix
 *    (export/audioExport.ts), AAC 48 kHz stereo 192 kbps, pumped ~1 s ahead.
 *    Sample timestamps are the Mac writer's: `CMTime(seconds: i / fps,
 *    preferredTimescale: 600)` (truncated) on a 1/600 s track timescale, the
 *    last sample running to the timeline's end (the Mac's `endSession`).
 *    Fast export (`collapseStaticSpans`) is core/export/staticSpans — the
 *    Mac's StaticSpanCollapse: a frame whose key matches the last written one
 *    is neither decoded-for-render, rendered nor encoded; the previous sample
 *    lasts longer (VFR), and every written frame keeps its CFR timestamp.
 *  - GIF: core/export/gifPolicy's frame rate and size (the Mac's
 *    GIFExportPolicy), every frame dense, read back, converted to sRGB and
 *    encoded by export/gif/gifEncoder.ts — all inside this worker.
 *  - PNG (still captures): core/export/stillImage — StillImageExporter's
 *    settled micro clip, its last frame, in the working space's colours.
 */
import { BufferTarget, EncodedPacket, EncodedVideoPacketSource, MovOutputFormat, Mp4OutputFormat, Output } from "mediabunny";
import { gifDelayCentiseconds, gifFrameRate, gifFrameSize } from "../../core/export/gifPolicy";
import {
  cameraLayoutKey,
  exportFrameSeconds,
  StaticSpanCollapse,
  type StaticFrameKey,
} from "../../core/export/staticSpans";
import { stillExportDocument, stillFrameIndex } from "../../core/export/stillImage";
import { backdropAlpha } from "../../core/math/annotationGeometry";
import { resolve as resolveCameraLayout } from "../../core/math/cameraLayoutMath";
import { deviceSegmentActive, segmentDeviceAssets } from "../../core/math/deviceSegmentDip";
import { shouldHideCursor } from "../../core/math/exportCursor";
import { interpolateIfFresh } from "../../core/math/cursorSmoother";
import { parseProject } from "../../core/model";
import type { AudioMixRenderer } from "../audio/mixer";
import { AudioExport, type AudioExportInfo } from "./audioExport";
import type { WorkingSpace } from "../color";
import { renderProjectFromJSON, type RenderProject } from "../contract";
import { configureCanvas, type GpuContext } from "../gpu/device";
import { encodeCopy, type PendingReadback } from "../gpu/readback";
import { cardGeometry, cmTime600, estimatedVideoBitRate, exportFrameCount, resolvedOutputSize, type Size } from "../layout";
import type { DemuxedVideo } from "../media/demux";
import { VideoStream } from "../media/videoStream";
import { FrameGraph } from "../passes/frameGraph";
import { cursorSceneData } from "../passes/cursor/cursorScene";
import type { FrameState, Scene, SceneExtras } from "../passes/types";
import { buildCameraPath, cameraKeyAt, cameraStateAt, type CameraPath } from "../camera";
import type { ExportOptions, ExportResult } from "../protocol";
import { createTimeMap, type TimeMap } from "../time";
import { GifEncoder } from "./gif/gifEncoder";
import { toSrgbOpaque } from "./gif/srgb";

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
  const format = args.options.format ?? "MP4";
  if (format === "PNG") return exportStill(args);
  if (format === "GIF") return exportGif(args);
  return exportMovie(args);
}

// ── The shared render pipeline ──────────────────────────────────────────────

interface PreparedFrame {
  index: number;
  outputTime: number;
  sourceTime: number;
  /** Source sample index (−1: no video at this time). */
  sourceIndex: number;
  state: FrameState;
}

/**
 * Export-sized canvas + frame graph + decode stream for one export. `prepare`
 * resolves a frame's decisions and async side inputs (the webcam's exact
 * frame) WITHOUT decoding the screen frame; `decode` then waits for it (a
 * collapsed frame never does).
 */
class ExportPipeline {
  readonly canvas: OffscreenCanvas;
  readonly context: GPUCanvasContext;
  readonly graph: FrameGraph;
  readonly scene: Scene;
  readonly cameraPath: CameraPath | null;
  readonly stream: VideoStream;
  private pinned = -1;

  constructor(
    private readonly args: ExportArgs,
    out: Size,
    fps: number,
    readonly timeMap: TimeMap,
    extras: SceneExtras,
    settings: RenderProject["settings"],
    /** A camera path built for this export (the PNG micro clip); undefined = the preview's, or rebuilt at `fps`. */
    cameraPath?: CameraPath | null,
  ) {
    const { gpu, media, workingSpace, options } = args;
    const sourceSize = { width: media.info.width, height: media.info.height };
    this.canvas = new OffscreenCanvas(out.width, out.height);
    const context = this.canvas.getContext("webgpu");
    if (!context) throw new Error("WebGPU canvas unavailable for export");
    this.context = context;
    configureCanvas(context, gpu, workingSpace);
    this.graph = new FrameGraph(gpu);
    this.scene = {
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
    this.cameraPath =
      cameraPath !== undefined
        ? cameraPath
        : extras.fps === fps || !extras.project
          ? extras.cameraPath
          : buildCameraPath(extras.project, extras.assets, timeMap, fps, sourceSize, out);
    this.scene.extras.cameraPath = this.cameraPath;
    this.graph.setScene(this.scene);
    this.stream = new VideoStream(media, { lookahead: 8, cacheBytes: 160 * 1024 * 1024, label: "export" });
  }

  async prepare(index: number, t: number): Promise<PreparedFrame> {
    const src = this.timeMap.sourceTime(t);
    const media = this.args.media;
    const sourceIndex = this.timeMap.hasVisibleVideo(src) ? media.frameIndexAt(cmTime600(src)) : -1;
    const state: FrameState = {
      outputTime: t,
      sourceTime: src,
      video: null,
      ...cameraStateAt(this.cameraPath, this.scene.geometry, this.args.extras.project?.settings ?? null, t),
    };
    // Second decode streams (the webcam) resolve their exact frame first.
    await this.graph.prefetch(state);
    return { index, outputTime: t, sourceTime: src, sourceIndex, state };
  }

  /** Waits for the screen frame (pinned until `release`). */
  async decode(frame: PreparedFrame): Promise<void> {
    if (frame.sourceIndex < 0) return;
    const f = await this.stream.waitFor(frame.sourceIndex, true);
    this.stream.cache.pin(frame.sourceIndex);
    this.pinned = frame.sourceIndex;
    frame.state.video = { frame: f, index: frame.sourceIndex };
  }

  /** Renders into the canvas; `capture` also records a readback of the frame. */
  render(frame: PreparedFrame, capture: boolean): PendingReadback | null {
    const texture = this.context.getCurrentTexture();
    let pending: PendingReadback | null = null;
    this.graph.render(
      frame.state,
      { texture, view: texture.createView(), format: this.args.gpu.preferredFormat },
      capture ? (enc) => void (pending = encodeCopy(this.args.gpu.device, enc, texture)) : undefined,
    );
    return pending;
  }

  release(): void {
    if (this.pinned >= 0) this.stream.cache.unpin(this.pinned);
    this.pinned = -1;
  }

  dispose(): void {
    this.release();
    this.stream.dispose();
    this.graph.destroy();
  }
}

// ── Fast export (static-span collapse) ──────────────────────────────────────

/**
 * The per-export key builder: VideoExporter's `StaticSpanCollapse.FrameKey`
 * inputs, evaluated at the MAC's frame times (`exportFrameSeconds`) with the
 * same core math the passes draw with.
 */
function staticSpanCollapse(pipe: ExportPipeline, media: DemuxedVideo) {
  const scene = pipe.scene;
  const project = scene.extras.project;
  if (!project) return null;
  const settings = project.settings;
  const cursor = cursorSceneData(scene);
  const events = cursor?.events ?? [];
  const H = scene.target.height;
  const vr = scene.geometry.videoRect;
  const videoRectYUp = { x: vr.x, y: H - vr.y - vr.height, width: vr.width, height: vr.height };
  const device = segmentDeviceAssets(project.recordingSourceKind, settings.showDeviceFrame, project.sourceSegments, videoRectYUp);
  const collapse = StaticSpanCollapse.forProject(
    true,
    project,
    (cursor?.keystrokeDisplay ?? []).map((e) => e.time),
    device ? device.ranges.flatMap((r) => [r.start, r.end]) : null,
    events,
  );
  const zero = { x: 0, y: 0, width: 0, height: 0 };
  const noCameraLayout = cameraLayoutKey(resolveCameraLayout(0, [], zero, zero, 0, 0, false));
  // Mac: `currentVideoSampleTime` starts at the first sample and only
  // advances while a source frame is visible.
  let videoSample = media.frames[0]?.pts ?? 0;
  return {
    collapse,
    key(frame: PreparedFrame, macOutput: number, macSource: number): StaticFrameKey {
      if (frame.sourceIndex >= 0) videoSample = media.frames[frame.sourceIndex].pts;
      const cam = cameraKeyAt(pipe.cameraPath, macOutput);
      const parts = pipe.graph.staticKeyParts(frame.state);
      return {
        videoSampleSeconds: videoSample,
        cameraSampleSeconds: parts.cameraSampleSeconds ?? 0,
        zoom: cam.zoom,
        focalX: cam.focalX,
        focalY: cam.focalY,
        offsetX: cam.offsetX,
        offsetY: cam.offsetY,
        tiltPitch: cam.tiltPitch,
        tiltYaw: cam.tiltYaw,
        tiltRoll: cam.tiltRoll,
        cursorPosition: events.length > 0 ? interpolateIfFresh(events, macSource) : null,
        cursorHidden: settings.showCursor && events.length > 0 ? shouldHideCursor(macSource, events, settings) : false,
        dimAlpha: backdropAlpha(project.annotations, macSource),
        deviceSegment: device !== null && deviceSegmentActive(device, macSource),
        cameraLayout: parts.cameraLayout ?? noCameraLayout,
      };
    },
  };
}

// ── MP4 / MOV ───────────────────────────────────────────────────────────────

const us = (seconds: number) => Math.round(seconds * 1e6);

async function exportMovie(args: ExportArgs): Promise<ExportResult> {
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

  const pipe = new ExportPipeline(args, out, fps, timeMap, extras, settings);
  const fast = options.collapseStaticSpans ? staticSpanCollapse(pipe, media) : null;

  const format = options.format === "MOV" ? new MovOutputFormat({ fastStart: "in-memory" }) : new Mp4OutputFormat({ fastStart: "in-memory" });
  const output = new Output({ format, target: new BufferTarget() });
  const source = new EncodedVideoPacketSource(container);
  // Track timescale 600 — the Mac's AVAssetWriter (CMTime 600): the frame
  // timestamps below are its truncated CMTime values, stored exactly.
  output.addVideoTrack(source, { frameRate: 600 });
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
  const timestamps: number[] = [];
  const captures: { frame: number; rgba: ArrayBuffer }[] = [];
  const pendingCaptures: { frame: number; copy: PendingReadback }[] = [];
  const captureSet = new Set(options.captureFrames ?? []);
  const keyEvery = fps * 2;
  let sinceKey = keyEvery;
  const waitDequeue = () => new Promise<void>((r) => encoder.addEventListener("dequeue", () => r(), { once: true }));

  let audioInfo: AudioExportInfo | null = null;
  try {
    for (let i = 0; i < total; i++) {
      if (encodeError) throw encodeError;
      if (args.cancelled?.()) throw new ExportCancelledError();
      // Keep the audio ~1 s ahead of the video (both tracks interleave in the mux).
      if (audio) await audio.pump(i / fps + 1);
      const frame = await pipe.prepare(i, start + i / fps);
      sourceIndices.push(frame.sourceIndex);
      // The Mac writer's frame time (CMTime 600, truncated) — the PTS, and
      // the clock of the fast-export decisions.
      const macOutput = exportFrameSeconds(i, fps, start);
      if (fast) {
        const macSource = timeMap.sourceTime(macOutput);
        const key = fast.key(frame, macOutput, macSource);
        if (fast.collapse.shouldSkip(i, total, macOutput, macSource, key)) {
          if (i % 10 === 0) onProgress(i + 1, total);
          continue;
        }
      }
      await pipe.decode(frame);
      const copy = pipe.render(frame, captureSet.has(i));
      if (copy) pendingCaptures.push({ frame: i, copy });
      // Every written frame keeps its CFR timestamp; the last one runs to
      // the timeline's end (Mac: `endSession(atSourceTime: totalSeconds)`).
      const ts = us(macOutput - start);
      const next = i + 1 < total ? us(exportFrameSeconds(i + 1, fps, start) - start) : us(end - start);
      const vf = new VideoFrame(pipe.canvas, { timestamp: ts, duration: Math.max(1, next - ts) });
      pipe.release();
      while (encoder.encodeQueueSize > 4) await waitDequeue();
      // A keyframe at least every 2 s of written frames (and after a long hold).
      const keyFrame = timestamps.length === 0 || sinceKey >= keyEvery || ts - (timestamps.at(-1) ?? 0) >= 2e6;
      encoder.encode(vf, { keyFrame });
      sinceKey = keyFrame ? 1 : sinceKey + 1;
      timestamps.push(ts);
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
    pipe.dispose();
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
    timestamps,
    collapsedFrames: fast?.collapse.collapsedFrameCount ?? 0,
    captures,
    audio: audioInfo,
  };
}

// ── GIF ─────────────────────────────────────────────────────────────────────

async function exportGif(args: ExportArgs): Promise<ExportResult> {
  const { media, project, timeMap, extras, workingSpace, options, onProgress } = args;
  const t0 = performance.now();
  const settings = project.settings;
  const sourceSize = { width: media.info.width, height: media.info.height };
  const videoSize =
    options.width && options.height
      ? { width: options.width, height: options.height }
      : resolvedOutputSize(settings.exportSettings, settings.aspectRatio, sourceSize);
  const out = gifFrameSize(videoSize);
  const fps = gifFrameRate(options.fps ?? settings.exportSettings.fps);
  const start = Math.max(0, options.start ?? 0);
  const end = Math.min(timeMap.outputDuration, options.end ?? timeMap.outputDuration);
  const total = exportFrameCount(Math.max(0.0001, end - start), fps);

  const pipe = new ExportPipeline(args, out, fps, timeMap, extras, settings);
  const gif = new GifEncoder(out.width, out.height, gifDelayCentiseconds(fps));
  const sourceIndices: number[] = [];
  const captures: { frame: number; rgba: ArrayBuffer }[] = [];
  const captureSet = new Set(options.captureFrames ?? []);
  try {
    for (let i = 0; i < total; i++) {
      if (args.cancelled?.()) throw new ExportCancelledError();
      const frame = await pipe.prepare(i, start + i / fps);
      sourceIndices.push(frame.sourceIndex);
      await pipe.decode(frame);
      const copy = pipe.render(frame, true)!;
      pipe.release();
      const px = await copy.read();
      if (captureSet.has(i)) captures.push({ frame: i, rgba: px.rgba.slice().buffer as ArrayBuffer });
      gif.addFrame(toSrgbOpaque(px.rgba, workingSpace));
      if (i % 5 === 0 || i === total - 1) onProgress(i + 1, total);
    }
  } finally {
    pipe.dispose();
  }
  const bytes = gif.finish();
  return {
    buffer: bytes.buffer as ArrayBuffer,
    mimeType: "image/gif",
    codec: "gif",
    width: out.width,
    height: out.height,
    fps,
    frames: total,
    encodeMs: performance.now() - t0,
    sourceIndices,
    captures,
    audio: null,
  };
}

// ── PNG (still captures) ────────────────────────────────────────────────────

async function exportStill(args: ExportArgs): Promise<ExportResult> {
  const { media, project, extras, workingSpace, options, onProgress } = args;
  const t0 = performance.now();
  // StillImageExporter's clone: the settled micro clip at the head of the trim.
  const doc = stillExportDocument(extras.doc);
  const still = renderProjectFromJSON(doc);
  let core: ReturnType<typeof parseProject> | null = null;
  try {
    core = parseProject(doc);
  } catch {
    core = null;
  }
  const timeMap = createTimeMap(still, media.info.duration, core);
  const settings = project.settings;
  const sourceSize = { width: media.info.width, height: media.info.height };
  const out =
    options.width && options.height
      ? { width: options.width, height: options.height }
      : resolvedOutputSize(settings.exportSettings, settings.aspectRatio, sourceSize);
  const fps = Math.max(1, Math.round(options.fps ?? settings.exportSettings.fps));
  const index = stillFrameIndex(timeMap.outputDuration, fps);
  // The micro clip's own camera path (the Mac exports the clone).
  let cameraPath: CameraPath | null = null;
  try {
    cameraPath = core ? buildCameraPath(core, extras.assets, timeMap, fps, sourceSize, out) : null;
  } catch {
    cameraPath = null;
  }
  const pipe = new ExportPipeline(args, out, fps, timeMap, { ...extras, doc, project: core, timeMap, cameraPath }, still.settings, cameraPath);
  try {
    const frame = await pipe.prepare(index, exportFrameSeconds(index, fps));
    await pipe.decode(frame);
    const copy = pipe.render(frame, true)!;
    pipe.release();
    const px = await copy.read();
    const png = await encodePng(px.width, px.height, px.rgba, workingSpace === "display-p3" ? "display-p3" : "srgb");
    onProgress(1, 1);
    return {
      buffer: await png.arrayBuffer(),
      mimeType: "image/png",
      codec: "png",
      width: out.width,
      height: out.height,
      fps,
      frames: 1,
      encodeMs: performance.now() - t0,
      sourceIndices: [frame.sourceIndex],
      captures: options.captureFrames?.includes(0) ? [{ frame: 0, rgba: px.rgba.slice().buffer as ArrayBuffer }] : [],
      audio: null,
    };
  } finally {
    pipe.dispose();
  }
}

/** Premultiplied readback → straight-alpha PNG, tagged with the render space. */
async function encodePng(w: number, h: number, rgba: Uint8Array, space: PredefinedColorSpace): Promise<Blob> {
  const c = new OffscreenCanvas(w, h);
  const ctx = c.getContext("2d", { colorSpace: space });
  if (!ctx) throw new Error("Canvas2D unavailable for PNG encode");
  const straight = new Uint8ClampedArray(rgba.length);
  for (let i = 0; i < rgba.length; i += 4) {
    const a = rgba[i + 3];
    if (a === 0) continue;
    const k = 255 / a;
    straight[i] = rgba[i] * k;
    straight[i + 1] = rgba[i + 1] * k;
    straight[i + 2] = rgba[i + 2] * k;
    straight[i + 3] = a;
  }
  ctx.putImageData(new ImageData(straight, w, h, { colorSpace: space }), 0, 0);
  return c.convertToBlob({ type: "image/png" });
}
