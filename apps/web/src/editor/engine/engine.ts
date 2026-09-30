/**
 * Engine — the worker-side renderer: owns the GPU device, the OffscreenCanvas,
 * the media pipeline and the playback loop. No DOM, no React.
 *
 * Per vsync (rAF inside the worker):
 *   clock → output time → SOURCE time (TimeMap) → frame index
 *   → VideoStream.setTarget (decode-ahead / GOP-aware seek)
 *   → FrameState → FrameGraph.render → present
 * When paused and nothing is dirty the loop stops entirely (zero idle cost).
 */
import { parseProject, type Project } from "../core/model";
import { buildCameraPath, CAMERA_REST, cameraStateAt, type CameraPath, type CameraState } from "./camera";
import { PlaybackClock, wallNow } from "./clock";
import type { WorkingSpace } from "./color";
import { renderProjectFromJSON, type RenderMedia, type RenderProject } from "./contract";
import { configureCanvas, EngineCapabilityError, initGpu, type GpuContext } from "./gpu/device";
import { cardGeometry, cmTime600, resolvedOutputSize, type Size } from "./layout";
import { IDENTITY, scaleAbout, type Mat3 } from "./mat3";
import { disposeSceneAssets, EMPTY_ASSETS, loadSceneAssets, refsOf, type SceneAssets } from "./media/assets";
import { DemuxedVideo } from "./media/demux";
import { VideoStream } from "./media/videoStream";
import { FrameGraph } from "./passes/frameGraph";
import type { FrameState, Scene, SceneExtras } from "./passes/types";
import type {
  EngineStats,
  ExportOptions,
  FromWorker,
  LoadedInfo,
  SnapshotResult,
  TransportState,
  ViewportSpec,
} from "./protocol";
import { createTimeMap, type TimeMap } from "./time";
import { exportVideo } from "./export/exporter";
import { ProjectAudio } from "./audio/projectAudio";
import { encodeCopy, type PendingReadback } from "./gpu/readback";

type Post = (msg: FromWorker, transfer?: Transferable[]) => void;

interface PendingSeek {
  requestId: number;
  time: number;
  index: number;
}

const rAF: (cb: (t: number) => void) => number =
  typeof requestAnimationFrame === "function"
    ? (cb) => requestAnimationFrame(cb)
    : (cb) => setTimeout(() => cb(performance.now()), 16) as unknown as number;

class Rolling {
  private v: number[] = [];
  constructor(private readonly n: number) {}
  push(x: number) {
    this.v.push(x);
    if (this.v.length > this.n) this.v.shift();
  }
  get last(): number {
    return this.v[this.v.length - 1] ?? 0;
  }
  get count(): number {
    return this.v.length;
  }
  quantile(q: number): number {
    if (!this.v.length) return 0;
    const s = [...this.v].sort((a, b) => a - b);
    return s[Math.min(s.length - 1, Math.floor(q * s.length))];
  }
  clear() {
    this.v = [];
  }
}

export class Engine {
  private gpu!: GpuContext;
  private canvas!: OffscreenCanvas;
  private context!: GPUCanvasContext;
  private canvasSpace: PredefinedColorSpace = "srgb";
  private graph!: FrameGraph;
  private viewport!: ViewportSpec;

  private project: RenderProject | null = null;
  /** Raw project.json + its lossless core parse + loaded sidecar assets. */
  private doc: Record<string, unknown> = {};
  private core: Project | null = null;
  private renderMedia: RenderMedia = { video: "" };
  private assets: SceneAssets = EMPTY_ASSETS;
  private cameraPath: CameraPath | null = null;
  private media: DemuxedVideo | null = null;
  private stream: VideoStream | null = null;
  private timeMap: TimeMap | null = null;
  private workingSpace: WorkingSpace = "srgb";
  private scene: Scene | null = null;
  private sceneVersion = 0;

  private clock = new PlaybackClock();
  private loop = true;
  private dirty = true;
  private rafPending = false;
  private displayed: { index: number; frame: VideoFrame } | null = null;
  private lastShownIndex = -1;
  private continuity = false;
  private pendingSeeks: PendingSeek[] = [];
  private pendingSnapshots: { requestId: number; png: boolean }[] = [];
  private debugCamera: { zoom: number; focalX: number; focalY: number } | null = null;
  private exporting = false;
  private exportCancelled = false;
  private disposed = false;

  // stats
  private encodeMs = new Rolling(120);
  private gpuMs = new Rolling(120);
  private intervals = new Rolling(240);
  private presentTimes: number[] = [];
  private lastPresentWall = 0;
  private rendered = 0;
  private lateFrames = 0;
  private skippedFrames = 0;
  private targetIndex = -1;
  private statsTimer: ReturnType<typeof setInterval> | null = null;

  constructor(private readonly post: Post) {}

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  async init(canvas: OffscreenCanvas, viewport: ViewportSpec): Promise<void> {
    this.canvas = canvas;
    this.gpu = await initGpu((reason) => {
      if (!this.disposed) this.post({ type: "error", code: "device-lost", message: `GPU device lost (${reason}). Reload the editor.` });
    });
    const ctx = canvas.getContext("webgpu");
    if (!ctx) throw new EngineCapabilityError("no-webgpu", "Could not create a WebGPU canvas context.");
    this.context = ctx;
    this.graph = new FrameGraph(this.gpu);
    this.graph.requestFrame = () => this.requestFrame(true);
    this.applyViewport(viewport);
    this.canvasSpace = configureCanvas(this.context, this.gpu, this.workingSpace);
    this.statsTimer = setInterval(() => this.post({ type: "stats", stats: this.getStats() }), 250);
    this.post({
      type: "ready",
      capabilities: {
        adapter: this.gpu.adapterInfo,
        timestampQuery: this.gpu.timestampQuery,
        canvasFormat: this.gpu.preferredFormat,
      },
    });
  }

  async load(requestId: number, rawProject: unknown, media: RenderMedia): Promise<void> {
    this.unload();
    const project = renderProjectFromJSON(rawProject);
    const [demux, assets] = await Promise.all([
      DemuxedVideo.open(media.video),
      loadSceneAssets(rawProject as Record<string, unknown>, media),
    ]);
    this.project = project;
    this.media = demux;
    this.doc = rawProject as Record<string, unknown>;
    this.core = parseCore(rawProject);
    this.renderMedia = media;
    this.assets = assets;
    this.timeMap = createTimeMap(project, demux.info.duration, this.core);
    this.workingSpace = demux.info.workingSpace;
    this.canvasSpace = configureCanvas(this.context, this.gpu, this.workingSpace);
    this.stream = new VideoStream(demux, {
      onFrame: () => this.requestFrame(),
      onError: (e) => this.post({ type: "error", code: "decode", message: e.message }),
      cacheBytes: 256 * 1024 * 1024,
      lookahead: 8,
    });
    this.clock = new PlaybackClock();
    this.rebuildScene();
    this.applyLoopRange();
    const sourceSize = { width: demux.info.width, height: demux.info.height };
    const info: LoadedInfo = {
      codec: demux.info.codec,
      codecString: demux.info.codecString,
      width: demux.info.width,
      height: demux.info.height,
      naturalSize: { width: demux.info.naturalWidth, height: demux.info.naturalHeight },
      fps: demux.info.fps,
      frameCount: demux.info.frameCount,
      mediaDuration: demux.info.duration,
      outputDuration: this.timeMap.outputDuration,
      outputSize: resolvedOutputSize(project.settings.exportSettings, project.settings.aspectRatio, sourceSize),
      workingSpace: this.workingSpace,
      canvasColorSpace: this.canvasSpace,
      keyframeInterval: demux.info.keyframeInterval,
      hasBFrames: demux.info.hasBFrames,
      hasAudio: demux.info.hasAudio,
      hardwareDecode: demux.info.hardwareDecode,
      unsupportedFeatures: project.unsupportedFeatures,
    };
    this.post({ type: "loaded", requestId, info });
    this.postTransport();
    this.requestFrame(true);
  }

  private unload(): void {
    if (this.displayed && this.stream) this.stream.cache.unpin(this.displayed.index);
    this.displayed = null;
    this.stream?.dispose();
    this.media?.dispose();
    disposeSceneAssets(this.assets);
    this.assets = EMPTY_ASSETS;
    this.stream = null;
    this.media = null;
    this.timeMap = null;
    this.scene = null;
    for (const s of this.pendingSeeks) this.resolveSeek(s, -1, true);
    this.pendingSeeks = [];
  }

  dispose(): void {
    this.disposed = true;
    this.unload();
    if (this.statsTimer) clearInterval(this.statsTimer);
    this.graph?.destroy();
    this.gpu?.device.destroy();
  }

  setProject(raw: unknown): void {
    if (!this.media) return;
    const previousRefs = JSON.stringify(refsOf(this.doc));
    this.project = renderProjectFromJSON(raw);
    this.doc = raw as Record<string, unknown>;
    this.core = parseCore(raw);
    this.timeMap = createTimeMap(this.project, this.media.info.duration, this.core);
    this.rebuildScene();
    this.applyLoopRange();
    this.requestFrame(true);
    // A new image/sidecar reference (e.g. a different wallpaper) reloads the
    // assets, then re-renders with them.
    if (JSON.stringify(refsOf(this.doc)) !== previousRefs) {
      const media = this.renderMedia;
      void loadSceneAssets(this.doc, media).then((assets) => {
        if (this.disposed || media !== this.renderMedia) return assets.images.forEach((b) => b.close());
        disposeSceneAssets(this.assets);
        this.assets = assets;
        this.rebuildScene();
        this.requestFrame(true);
      });
    }
  }

  /** Swap in fresh media URLs (e.g. presigned GETs refreshed) without a reload. */
  setMediaFiles(files: Record<string, string>): void {
    this.renderMedia = { ...this.renderMedia, files };
  }

  /** What every pass sees about the project (shared with the exporter). */
  private sceneExtras(): SceneExtras {
    const fps = Math.max(1, Math.round(this.project?.settings.exportSettings.fps ?? 60));
    this.cameraPath = null;
    if (this.core && this.media && this.timeMap && this.project) {
      const sourceSize = { width: this.media.info.width, height: this.media.info.height };
      try {
        this.cameraPath = buildCameraPath(
          this.core,
          this.assets,
          this.timeMap,
          fps,
          sourceSize,
          resolvedOutputSize(this.project.settings.exportSettings, this.project.settings.aspectRatio, sourceSize),
        );
      } catch (error) {
        this.post({ type: "error", code: "camera", message: `Camera path failed: ${String(error)}` });
      }
    }
    return {
      doc: this.doc,
      project: this.core,
      media: this.renderMedia,
      assets: this.assets,
      fps,
      timeMap: this.timeMap!,
      cameraPath: this.cameraPath,
    };
  }

  // ── Viewport / scene ──────────────────────────────────────────────────────

  private applyViewport(v: ViewportSpec): void {
    this.viewport = v;
    const w = Math.max(1, Math.round(v.pixelWidth ?? v.cssWidth * v.dpr));
    const h = Math.max(1, Math.round(v.pixelHeight ?? v.cssHeight * v.dpr));
    if (this.canvas.width !== w) this.canvas.width = w;
    if (this.canvas.height !== h) this.canvas.height = h;
  }

  resize(v: ViewportSpec): void {
    this.applyViewport(v);
    this.rebuildScene();
    this.requestFrame(true);
  }

  private reference(): Size | null {
    const v = this.viewport;
    if (v.reference !== undefined) return v.reference;
    return { width: v.cssWidth, height: v.cssHeight };
  }

  private rebuildScene(): void {
    if (!this.project || !this.media) return;
    const target = { width: this.canvas.width, height: this.canvas.height };
    const sourceSize = { width: this.media.info.width, height: this.media.info.height };
    this.scene = {
      version: ++this.sceneVersion,
      target,
      targetFormat: this.gpu.preferredFormat,
      workingSpace: this.workingSpace,
      settings: this.project.settings,
      sourceSize,
      geometry: cardGeometry(sourceSize, target, this.project.settings, this.reference()),
      extras: this.sceneExtras(),
    };
    this.graph.setScene(this.scene);
    this.dirty = true;
  }

  // ── Transport ─────────────────────────────────────────────────────────────

  play(): void {
    if (!this.timeMap || !this.media) return;
    const t = this.clock.now();
    if (t >= this.timeMap.outputDuration - 1e-6) this.clock.seek(0);
    else {
      // Start on the displayed frame's boundary: playback picks the frame
      // nearest each vsync, which is only jitter-proof when the clock phase
      // sits on frame boundaries (a pause can land anywhere in a frame).
      const src = this.timeMap.sourceTime(t);
      const i = this.media.frameIndexAt(cmTime600(src));
      if (i >= 0) this.clock.seek(Math.max(0, t - (src - this.media.frames[i].pts)));
    }
    this.clock.play();
    this.continuity = false;
    this.postTransport();
    this.requestFrame();
  }

  pause(): void {
    this.clock.pause();
    this.postTransport();
    this.requestFrame(true);
  }

  seek(requestId: number, time: number): void {
    if (!this.timeMap || !this.media) {
      this.post({ type: "seeked", requestId, time, frameIndex: -1, superseded: true });
      return;
    }
    const t = Math.max(0, Math.min(this.timeMap.outputDuration, time));
    this.clock.seek(t);
    for (const s of this.pendingSeeks) this.resolveSeek(s, -1, true);
    this.pendingSeeks = [{ requestId, time: t, index: this.indexAt(t, false) }];
    this.continuity = false;
    this.postTransport();
    this.requestFrame(true);
  }

  setRate(rate: number): void {
    this.clock.setRate(rate);
    this.continuity = false;
    this.postTransport();
  }

  setLoop(enabled: boolean): void {
    this.loop = enabled;
    this.applyLoopRange();
    this.postTransport();
  }

  /** Tells the decoder where playback wraps so the loop head is decoded before the wrap. */
  private applyLoopRange(): void {
    if (!this.stream || !this.timeMap) return;
    if (!this.loop) {
      this.stream.setLoop(null);
      return;
    }
    const start = this.indexAt(0, false);
    const end = this.indexAt(Math.max(0, this.timeMap.outputDuration - 1e-4), false);
    this.stream.setLoop(start >= 0 && end > start ? { start, end } : null);
  }

  syncClock(mediaTime: number, wallMs: number): void {
    this.clock.externalMaster = true;
    this.clock.sync(mediaTime, wallMs);
  }

  setDebug(d: { camera?: { zoom: number; focalX: number; focalY: number } | null; forceLayer?: boolean }): void {
    if (d.camera !== undefined) this.debugCamera = d.camera;

    if (d.forceLayer !== undefined) this.graph.forceLayer = d.forceLayer;
    this.requestFrame(true);
  }

  snapshot(requestId: number, png: boolean): void {
    this.pendingSnapshots.push({ requestId, png });
    this.requestFrame(true);
  }

  /**
   * Posts the transport. While playing, the pair is the clock's own anchor
   * (the vsync the playhead started on) so the main thread's audio starts in
   * phase with the video; a play/seek waiting for its anchoring tick is posted
   * by that tick instead.
   */
  /** Per-presented-frame geometry for the stage's editing chrome (FrameInfo). */
  private postFrameInfo(frame: FrameState, playing: boolean): void {
    const g = this.scene?.geometry;
    if (!g) return;
    this.post({
      type: "frame",
      info: {
        outputTime: frame.outputTime,
        sourceTime: frame.sourceTime,
        playing,
        target: g.target,
        canvasScale: g.canvasScale,
        contentRect: g.contentRect,
        videoRect: g.videoRect,
        camera: [...frame.camera],
      },
    });
  }

  private postTransport(): void {
    if (this.clock.awaitingAnchor) return;
    const playing = this.clock.playing;
    const wall = playing ? this.clock.anchor.wall : wallNow();
    const state: TransportState = {
      playing,
      time: this.clock.now(wall),
      wallMs: wall,
      rate: this.clock.rate,
      loop: this.loop,
      duration: this.timeMap?.outputDuration ?? 0,
    };
    this.post({ type: "transport", state });
  }

  // ── Frame selection ───────────────────────────────────────────────────────

  /**
   * Source frame index for an output time. Paused/exact: the exporter's rule
   * (last frame with PTS ≤ CMTime(t, 600)). Playing: nearest frame to the
   * vsync (PTS ≤ t + ½ frame) — keeps cadence stable against rAF jitter
   * when content and display rates match.
   */
  private indexAt(outputTime: number, playing: boolean): number {
    const map = this.timeMap!;
    const media = this.media!;
    const src = map.sourceTime(outputTime);
    if (!map.hasVisibleVideo(src)) return -1;
    if (playing) return media.frameIndexAt(src + 0.5 / media.info.fps);
    return media.frameIndexAt(cmTime600(src));
  }

  private camera(t: number): CameraState {
    const c = this.debugCamera;
    const g = this.scene?.geometry;
    if (!c && g && this.core && this.cameraPath) {
      // The exporter's camera at the export frame on screen — preview == export.
      return cameraStateAt(this.cameraPath, g, this.core.settings, t);
    }
    if (!c || !g || Math.abs(c.zoom - 1) < 1e-4) return CAMERA_REST;
    // Card-only zoom about the focal point in the video rect (exporter's zoom
    // block, Y-down: anchor = videoRect.origin + focal × size).
    const vr = g.videoRect;
    return { ...CAMERA_REST, camera: scaleAbout(c.zoom, vr.x + c.focalX * vr.width, vr.y + c.focalY * vr.height) };
  }

  requestFrame(markDirty = false): void {
    if (markDirty) this.dirty = true;
    if (this.rafPending) return;
    this.rafPending = true;
    rAF(this.tick);
  }

  private tick = (ts: number): void => {
    this.rafPending = false;
    if (!this.media || !this.stream || !this.timeMap || !this.scene || this.exporting) return;
    const wall = performance.timeOrigin + ts;
    const playing = this.clock.playing;
    const anchoring = this.clock.awaitingAnchor;
    let t = this.clock.tick(wall);
    if (anchoring) this.postTransport();
    const dur = this.timeMap.outputDuration;
    if (playing && t >= dur) {
      if (this.loop) {
        // Wrap to exactly 0 (a frame boundary) so the vsync cadence stays locked.
        t = 0;
        this.clock.seek(t, wall);
        this.clock.tick(wall);
        this.continuity = false;
      } else {
        t = dur;
        this.clock.pause(wall);
        this.clock.seek(dur, wall);
      }
      this.postTransport();
    }

    const idx = this.indexAt(Math.min(t, dur), playing);
    this.targetIndex = idx;
    if (idx >= 0) this.stream.setTarget(idx, playing);

    let show: { index: number; frame: VideoFrame } | null = null;
    if (idx >= 0) {
      const exact = this.stream.frame(idx);
      if (exact) show = { index: idx, frame: exact };
      else if (this.displayed) {
        show = this.displayed; // keep the stale frame up until the wanted one decodes
        if (playing) this.lateFrames++;
      }
    }

    const camera = this.camera(Math.min(t, dur));
    // While playing, EVERY vsync renders: the camera, cursor, ripples and
    // overlays move between source frames. Paused, only a change renders.
    const changed =
      playing || this.dirty || (show?.index ?? -1) !== (this.displayed?.index ?? -1) || this.pendingSnapshots.length > 0;
    if (changed) this.renderFrame(t, show, camera, wall, playing);

    // Resolve seeks whose exact frame is now on screen.
    if (this.pendingSeeks.length) {
      const shown = show?.index ?? -1;
      this.pendingSeeks = this.pendingSeeks.filter((s) => {
        if (s.index === shown && (s.index < 0 || show?.frame === this.stream!.frame(s.index))) {
          this.resolveSeek(s, shown, false);
          return false;
        }
        return true;
      });
    }

    if (playing || this.pendingSeeks.length || this.pendingSnapshots.length || (idx >= 0 && show?.index !== idx)) {
      this.requestFrame();
    }
  };

  private renderFrame(
    t: number,
    show: { index: number; frame: VideoFrame } | null,
    camera: CameraState,
    wall: number,
    playing: boolean,
  ): void {
    const stream = this.stream!;
    // Pin the new frame before unpinning the old (the old one's GPU work is already submitted).
    if (show && show.index !== this.displayed?.index) stream.cache.pin(show.index);
    const prev = this.displayed;
    const frame: FrameState = {
      outputTime: t,
      sourceTime: this.timeMap!.sourceTime(t),
      video: show,
      ...camera,
    };
    const texture = this.context.getCurrentTexture();
    const snaps = this.pendingSnapshots.splice(0);
    const copies: PendingReadback[] = [];
    const timing = this.graph.render(
      frame,
      { texture, view: texture.createView(), format: this.gpu.preferredFormat },
      snaps.length ? (enc) => void copies.push(encodeCopy(this.gpu.device, enc, texture)) : undefined,
    );
    if (prev && prev.index !== show?.index) stream.cache.unpin(prev.index);
    this.displayed = show;
    this.dirty = false;
    this.rendered++;
    this.postFrameInfo(frame, playing);
    this.encodeMs.push(timing.encodeMs);
    if (this.graph.lastGpuMs !== null) {
      this.gpuMs.push(this.graph.lastGpuMs);
      this.graph.lastGpuMs = null;
    }
    if (playing) {
      if (this.lastPresentWall > 0 && this.continuity) this.intervals.push(wall - this.lastPresentWall);
      if (this.continuity && show && this.lastShownIndex >= 0 && this.clock.rate <= 1) {
        const gap = show.index - this.lastShownIndex - 1;
        if (gap > 0) this.skippedFrames += gap;
      }
      this.continuity = true;
    } else {
      this.continuity = false;
    }
    this.lastPresentWall = wall;
    if (show) this.lastShownIndex = show.index;
    this.presentTimes.push(wall);
    while (this.presentTimes.length && wall - this.presentTimes[0] > 1000) this.presentTimes.shift();

    if (copies.length && snaps.length) {
      const g = this.scene!.geometry;
      const meta: SnapshotResult["meta"] = {
        videoRect: g.videoRect,
        contentRect: g.contentRect,
        canvasScale: g.canvasScale,
        videoScale: g.videoScale,
        frameIndex: show?.index ?? -1,
        outputTime: t,
      };
      void copies[0].read().then(async (px) => {
        for (const s of snaps) {
          const rgba = px.rgba.slice(0);
          let png: Blob | undefined;
          if (s.png) png = await encodePng(px.width, px.height, px.rgba, this.canvasSpace);
          const result: SnapshotResult = {
            width: px.width,
            height: px.height,
            colorSpace: this.canvasSpace,
            rgba: rgba.buffer as ArrayBuffer,
            png,
            meta,
          };
          this.post({ type: "snapshot", requestId: s.requestId, result }, [result.rgba]);
        }
      });
    }
  }

  private resolveSeek(s: PendingSeek, frameIndex: number, superseded: boolean): void {
    this.post({ type: "seeked", requestId: s.requestId, time: s.time, frameIndex, superseded });
  }

  // ── Export ────────────────────────────────────────────────────────────────

  async export(requestId: number, options: ExportOptions): Promise<void> {
    if (!this.media || !this.project || !this.timeMap) throw new Error("Nothing loaded to export.");
    const wasPlaying = this.clock.playing;
    if (wasPlaying) this.pause();
    this.exporting = true;
    this.exportCancelled = false;
    // The project's audio mix — opened on the worker's own demuxer, with the
    // sidecars the passes already loaded (same inputs as playback's plan).
    let audio: ProjectAudio | null = null;
    try {
      if (options.audio !== false) {
        audio = await ProjectAudio.open(
          {
            recording: this.media.input,
            files: this.renderMedia.files ?? {},
            cursorJson: this.assets.cursor,
            keysJson: this.assets.keystrokes,
          },
          this.doc,
        ).catch((e) => {
          console.warn("[engine] export audio unavailable:", e);
          return null;
        });
      }
      const result = await exportVideo({
        audio: audio?.renderer ?? null,
        cancelled: () => this.exportCancelled,
        gpu: this.gpu,
        media: this.media,
        project: this.project,
        timeMap: this.timeMap,
        extras: this.sceneExtras(),
        workingSpace: this.workingSpace,
        options: { reference: this.reference(), ...options },
        onProgress: (done, total) => this.post({ type: "exportProgress", requestId, done, total }),
      });
      const transfer: Transferable[] = [result.buffer, ...result.captures.map((c) => c.rgba)];
      if (result.audio?.pcm) transfer.push(result.audio.pcm);
      this.post({ type: "exported", requestId, result }, transfer);
    } finally {
      audio?.dispose();
      this.exporting = false;
      this.requestFrame(true);
    }
  }

  /** Stops the running export at the next frame (its request rejects with "cancelled"). */
  cancelExport(): void {
    if (this.exporting) this.exportCancelled = true;
  }

  // ── Bench ─────────────────────────────────────────────────────────────────

  /**
   * GPU throughput of the frame graph: renders the displayed frame `frames`
   * times back-to-back into an offscreen target (no vsync, GPU clocks
   * saturate) and reports wall ms per frame. `refit` re-runs the Lanczos fit
   * every frame (the cost of a NEW video frame) instead of reusing it.
   */
  async bench(requestId: number, frames: number, refit: boolean): Promise<void> {
    const show = this.displayed;
    const scene = this.scene;
    if (!show || !scene) throw new Error("bench needs a displayed frame");
    const device = this.gpu.device;
    const texture = device.createTexture({
      size: scene.target,
      format: this.gpu.preferredFormat,
      usage: GPUTextureUsage.RENDER_ATTACHMENT,
    });
    const target = { texture, view: texture.createView(), format: this.gpu.preferredFormat };
    const t = this.clock.now();
    const frame: FrameState = { outputTime: t, sourceTime: this.timeMap!.sourceTime(t), video: show, ...this.camera(this.clock.now()) };
    const run = async (n: number) => {
      for (let i = 0; i < n; i++) {
        if (refit) this.graph.invalidateFrameCaches();
        this.graph.render(frame, target);
      }
      await device.queue.onSubmittedWorkDone();
    };
    await run(10);
    const t0 = performance.now();
    await run(frames);
    const msPerFrame = (performance.now() - t0) / frames;
    texture.destroy();
    this.post({
      type: "benchResult",
      requestId,
      result: { frames, refit, msPerFrame, target: scene.target, videoScale: scene.geometry.videoScale },
    });
  }

  // ── Stats ─────────────────────────────────────────────────────────────────

  getStats(): EngineStats {
    const now = wallNow();
    while (this.presentTimes.length && now - this.presentTimes[0] > 1000) this.presentTimes.shift();
    return {
      fps: this.presentTimes.length,
      frameMs: { median: this.encodeMs.quantile(0.5), p99: this.encodeMs.quantile(0.99), last: this.encodeMs.last },
      gpuMs: this.gpuMs.count
        ? { median: this.gpuMs.quantile(0.5), p99: this.gpuMs.quantile(0.99), last: this.gpuMs.last }
        : null,
      intervalMs: { median: this.intervals.quantile(0.5), p99: this.intervals.quantile(0.99) },
      rendered: this.rendered,
      lateFrames: this.lateFrames,
      skippedFrames: this.skippedFrames,
      displayedIndex: this.displayed?.index ?? -1,
      targetIndex: this.targetIndex,
      stream: this.stream?.getStats() ?? null,
      gpuResidentBytes: this.graph?.pool.residentBytes ?? 0,
      staticBakeMs: this.graph?.lastBakeMs ?? 0,
      clockSyncErrorMs: this.clock.lastSyncErrorMs,
    };
  }

  /** Clears the rolling perf counters (harness: measure a clean window). */
  resetStats(): void {
    this.encodeMs.clear();
    this.gpuMs.clear();
    this.intervals.clear();
    this.lateFrames = 0;
    this.skippedFrames = 0;
    this.rendered = 0;
  }
}

async function encodePng(w: number, h: number, rgba: Uint8Array, space: PredefinedColorSpace): Promise<Blob> {
  const c = new OffscreenCanvas(w, h);
  const ctx = c.getContext("2d", { colorSpace: space });
  if (!ctx) throw new Error("Canvas2D unavailable for PNG encode");
  // The canvas holds premultiplied pixels; ImageData is straight alpha.
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

/** Lossless core parse (Swift init(from:) semantics); null when the document
 *  is not a decodable project — the engine then runs on RenderProject alone. */
function parseCore(raw: unknown): Project | null {
  try {
    return parseProject(raw);
  } catch {
    return null;
  }
}
