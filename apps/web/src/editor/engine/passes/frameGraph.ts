/**
 * FrameGraph — orders the passes for one output frame and owns the
 * scene-static bake. The preview (canvas) and the exporter each own one
 * instance with the SAME pass list, so preview == export by construction.
 *
 *   prepare passes                           (own render passes)
 *   camera identity:  [target]  backdrop(base) → card → cardTop → overlays
 *   camera active:    [layer]   card passes (shadow first) → cardTop
 *                     [target]  backdrop(bg) → layer∘camera → overlays
 *   card squeeze:     [layer]   card passes
 *                     [layer2]  layer∘squeeze → cardTop     (Mac: cardTransform, then the tile)
 *                     [target]  backdrop(bg) → layer2∘camera → overlays
 *
 * Stitched device segments (`withDeviceSegment`): a framed segment forces the
 * layer path; the keynote dip is the innermost factor of `camera` and fades
 * the layer (`cardOpacity`).
 */
import type { AffineTransform } from "../../core/math/geometry";
import { deviceSegmentFrame } from "../../core/math/deviceSegmentDip";
import type { GpuContext } from "../gpu/device";
import { PipelineCache, TexturePool } from "../gpu/resources";
import { IDENTITY, isIdentity, multiply, type Mat3 } from "../mat3";
import { BackdropPass, CardShadowPass } from "./backdrop";
import { DeviceBezelPass, DeviceIslandPass, DeviceSidePass } from "./device/devicePasses";
import { MenuBarPass } from "./menuBar";
import { CursorLayer } from "./cursor/cursorPasses";
import { KeystrokePillPass } from "./cursor/keystrokePass";
import { CameraFeature } from "./cameraBubble";
import { LayerComposePass } from "./layer";
import { StaticLayers } from "./staticLayers";
import type { FrameEncoder, FrameState, PassContext, RenderPass, Scene, StaticKeyParts, StaticTextures } from "./types";
import type { StageHits } from "../stageHits";
import { HighlightPass } from "./highlight";
import { RegionVideoPass } from "./regionEffects";
import { SubtitlePass } from "./subtitles";
import { VideoCardPass } from "./videoCard";
import { VideoFitPass } from "./videoFit";
import { AnnotationBackdropDimPass, AnnotationsPass } from "./annotations";
import { CurtainPass } from "./curtain";
import { WatermarkPass } from "./watermark";

export interface RenderTarget {
  view: GPUTextureView;
  texture: GPUTexture;
  format: GPUTextureFormat;
}

export interface FrameTiming {
  /** CPU ms spent encoding (import + passes + submit). */
  encodeMs: number;
  /** GPU ms for the frame (timestamp queries), when available — resolved async. */
  gpuMs?: number;
}

/**
 * Default pass list — the only place features are registered. Card-stage
 * order is the exporter's burn order (VideoExporter.export): video card
 * (with the region-processed layer) → cursor + click ripple → HIGHLIGHTS
 * (dim the cursor too) → SUBTITLES → keystrokes → annotations → curtain.
 */
export function defaultPasses(): RenderPass[] {
  const camera = new CameraFeature();
  const cursor = new CursorLayer();
  return [
    new VideoFitPass(),
    new RegionVideoPass(), // blur / pixelate / Depth Focus on the video layer (after the fit)
    cursor.shadowPass, // prepare: cursor drop-shadow silhouette + blur
    camera.prepare,
    new BackdropPass(),
    // Canvas half of the annotation blackout — dims the backdrop under the card (last backdrop pass).
    new AnnotationBackdropDimPass(),
    // Card statics (layer path): device side slab UNDER the shadow, bezel over it.
    new DeviceSidePass(),
    new CardShadowPass(),
    new DeviceBezelPass(),
    new VideoCardPass(),
    // Screen overlays in the exporter's order: menu bar, then the device island.
    new MenuBarPass(),
    new DeviceIslandPass(),
    cursor.spritePass,
    cursor.ripplePass,
    new HighlightPass(),
    new SubtitlePass(),
    new KeystrokePillPass(),
    // then annotations → curtain (topmost, pre-warp).
    new AnnotationsPass(),
    new CurtainPass(),
    // cardTop: the camera-layout tile (after the squeeze, before the warp).
    camera.tile,
    // overlay: the classic bubble (canvas space, after the warp), then the
    // brand watermark as the topmost layer.
    camera.overlay,
    new WatermarkPass(),
  ];
}

export class FrameGraph {
  readonly pipelines: PipelineCache;
  readonly pool: TexturePool;
  private readonly statics: StaticLayers;
  private readonly layer = new LayerComposePass();
  /** Resamples the card layer through the card-local squeeze (own uniforms). */
  private readonly squeeze = new LayerComposePass();
  private readonly passes: RenderPass[];
  private scene: Scene | null = null;
  private bakedVersion = -1;
  private dummy: GPUTexture;
  private dummyView: GPUTextureView;
  private timer: GpuTimer | null;
  lastGpuMs: number | null = null;
  /** Debug: force the card-layer path even for an identity camera (parity tests). */
  forceLayer = false;

  /** Set by the owner (Engine) — lets a pass ask for another frame. */
  requestFrame: () => void = () => {};

  constructor(private readonly gpu: GpuContext, passes: RenderPass[] = defaultPasses()) {
    const device = gpu.device;
    this.pipelines = new PipelineCache(device);
    this.pool = new TexturePool(device);
    this.statics = new StaticLayers(device);
    this.passes = passes;
    this.dummy = device.createTexture({
      label: "dummy-r8", size: { width: 1, height: 1 }, format: "r8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    this.dummyView = this.dummy.createView();
    this.timer = gpu.timestampQuery ? new GpuTimer(device, (ms) => (this.lastGpuMs = ms)) : null;
  }

  invalidateFrameCaches(): void {
    for (const p of this.passes) p.invalidate?.();
  }

  setScene(scene: Scene): void {
    this.scene = scene;
  }

  get currentScene(): Scene | null {
    return this.scene;
  }

  get lastBakeMs(): number {
    return this.statics.lastBakeMs;
  }

  /** The editor hit rects the passes drew in the last `render` (engine/stageHits.ts). */
  stageHits(): StageHits {
    const out: StageHits = {};
    for (const p of this.passes) if (p.stageHit?.current) out[p.stageHit.kind] = p.stageHit.current;
    return out;
  }

  /** Every pass had the inputs it wanted for the last rendered frame (seek resolution). */
  inputsReady(): boolean {
    return this.passes.every((p) => p.inputsReady?.() ?? true);
  }

  /** Export: let passes resolve async per-frame inputs (second decode stream) before `render`. */
  async prefetch(frame: FrameState): Promise<void> {
    const scene = this.scene;
    if (!scene) return;
    await Promise.all(this.passes.map((p) => p.prefetch?.(scene, frame)));
  }

  /** Export fast path: the passes' inputs to the static-span key for `frame` (after `prefetch`). */
  staticKeyParts(frame: FrameState): Partial<StaticKeyParts> {
    const scene = this.scene;
    if (!scene) return {};
    let parts: Partial<StaticKeyParts> = {};
    for (const p of this.passes) {
      const own = p.staticKey?.(scene, frame);
      if (own) parts = { ...parts, ...own };
    }
    return parts;
  }

  private context(statics: StaticTextures): PassContext {
    return {
      gpu: this.gpu,
      device: this.gpu.device,
      pipelines: this.pipelines,
      pool: this.pool,
      scene: this.scene!,
      statics,
      dummy: this.dummyView,
      requestFrame: () => this.requestFrame(),
    };
  }

  /**
   * Encodes + submits one frame into `target`. `extraCommands` runs after the
   * frame in the same submission (snapshot copies).
   */
  render(frame: FrameState, target: RenderTarget, extra?: (enc: GPUCommandEncoder) => void): FrameTiming {
    const t0 = performance.now();
    const scene = this.scene;
    if (!scene) throw new Error("FrameGraph.render before setScene");
    const device = this.gpu.device;
    const commands = device.createCommandEncoder({ label: "frame" });

    let statics = this.statics.current;
    let baked = false;
    if (!statics || this.bakedVersion !== scene.version) {
      baked = true;
      const base = { gpu: this.gpu, device, pipelines: this.pipelines, pool: this.pool, scene, dummy: this.dummyView, requestFrame: () => this.requestFrame() };
      statics = this.statics.bake(base, scene, commands);
      this.bakedVersion = scene.version;
      const ctx = this.context(statics);
      for (const p of this.passes) p.sceneChanged?.(ctx);
    }
    const ctx = this.context(statics);
    for (const p of this.passes) if (p.stageHit) p.stageHit.current = null;
    frame = withDeviceSegment(frame, statics, scene);

    const resources = {
      external: frame.video
        ? device.importExternalTexture({ source: frame.video.frame, colorSpace: scene.workingSpace })
        : null,
      fitted: null,
      videoLayer: null,
    };
    let passCount = 0;
    const timer = this.timer?.armed() ? this.timer : null;
    const enc: FrameEncoder = {
      commands,
      pass: null,
      format: target.format,
      cardToTarget: IDENTITY,
      layerMode: false,
      resources,
      // Timestamps ride the first and the last pass of the frame (Metal only
      // samples at real pass boundaries — empty passes report nothing).
      beginPass: (desc, last = false) => {
        const first = passCount++ === 0;
        if (timer && (first || last)) {
          desc = {
            ...desc,
            timestampWrites: {
              querySet: timer.querySet,
              beginningOfPassWriteIndex: first ? 0 : undefined,
              endOfPassWriteIndex: last ? 1 : undefined,
            },
          };
        }
        return commands.beginRenderPass(desc);
      },
    };

    // Card-local pre-transform (the camera-layout squeeze), resolved before any stage.
    let cardPre: Mat3 = IDENTITY;
    for (const p of this.passes) {
      const m = p.cardTransform?.(ctx, frame);
      if (m && !isIdentity(m)) cardPre = multiply(m, cardPre);
    }
    const squeezed = frame.video !== null && !isIdentity(cardPre);

    for (const p of this.passes) if (p.stage === "prepare") p.encode(ctx, frame, enc);

    const byStage = (stage: RenderPass["stage"]) => this.passes.filter((p) => p.stage === stage);
    // A framed device segment swaps the card's statics (no card shadow) — the
    // Mac always composites these takes as a card over transparency.
    const direct = isIdentity(frame.camera) && !frame.motionBlur && !squeezed && !frame.deviceSegment && !this.forceLayer;
    if (direct) {
      const pass = enc.beginPass({
        label: "canvas",
        colorAttachments: [{ view: target.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      }, true);
      enc.pass = pass;
      for (const p of byStage("backdrop")) p.encode(ctx, frame, enc);
      if (frame.video) {
        enc.cardToTarget = IDENTITY;
        for (const p of byStage("card")) p.encode(ctx, frame, enc);
        for (const p of byStage("cardTop")) p.encode(ctx, frame, enc);
      }
      for (const p of byStage("overlay")) p.encode(ctx, frame, enc);
      pass.end();
    } else {
      const { width, height } = scene.target;
      const usage = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING;
      const layer = this.pool.acquire(width, height, "rgba16float", usage, "card-layer");
      const lp = enc.beginPass({
        label: "card-layer",
        colorAttachments: [{ view: layer.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      });
      enc.pass = lp;
      enc.format = "rgba16float";
      enc.layerMode = true;
      enc.cardToTarget = IDENTITY;
      if (frame.video) for (const p of byStage("card")) p.encode(ctx, frame, enc);
      let composed = layer;
      let squeezeLayer: typeof layer | null = null;
      if (squeezed) {
        // Mac: `composited.transformed(by: CameraLayoutMath.cardTransform)` —
        // the finished card resampled (bilinear) through the squeeze, then
        // the camera tile composited over it.
        lp.end();
        squeezeLayer = this.pool.acquire(width, height, "rgba16float", usage, "card-layer-squeezed");
        const sp = enc.beginPass({
          label: "card-layer-squeezed",
          colorAttachments: [{ view: squeezeLayer.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
        });
        enc.pass = sp;
        this.squeeze.encode(ctx, { ...frame, camera: cardPre, cameraClip: null, motionBlur: null, cardOpacity: 1 }, sp, "rgba16float", layer);
        for (const p of byStage("cardTop")) p.encode(ctx, frame, enc);
        sp.end();
        composed = squeezeLayer;
      } else {
        if (frame.video) for (const p of byStage("cardTop")) p.encode(ctx, frame, enc);
        lp.end();
      }
      // Motion blur needs the warped card as a texture before the canvas pass.
      this.layer.prepare(ctx, frame, enc, composed);

      const cp = enc.beginPass({
        label: "canvas",
        colorAttachments: [{ view: target.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      }, true);
      enc.pass = cp;
      enc.format = target.format;
      for (const p of byStage("backdrop")) p.encode(ctx, frame, enc);
      if (frame.video) this.layer.encode(ctx, frame, cp, target.format, composed);
      for (const p of byStage("overlay")) p.encode(ctx, frame, enc);
      cp.end();
      this.layer.finish(ctx);
      this.pool.release(layer);
      this.pool.release(squeezeLayer);
    }

    if (timer) timer.resolve(commands);
    extra?.(commands);
    device.queue.submit([commands.finish()]);
    // Free-list textures of the old scene die only AFTER the submit that may
    // still reference them (bake intermediates are released mid-encode).
    if (baked) this.pool.trim();
    if (timer) timer.collect();
    return { encodeMs: performance.now() - t0 };
  }

  destroy(): void {
    const base = { gpu: this.gpu, device: this.gpu.device, pipelines: this.pipelines, pool: this.pool, scene: this.scene!, dummy: this.dummyView, requestFrame: () => this.requestFrame() };
    this.statics.destroy(base);
    for (const p of this.passes) p.destroy?.();
    this.layer.destroy();
    this.squeeze.destroy();
    this.pool.destroy();
    this.dummy.destroy();
    this.timer?.destroy();
  }
}

/**
 * Stitched takes (VideoExporter device segments), resolved ONCE per frame for
 * every pass from the SOURCE clock: `deviceSegment` (the segment framing is
 * on) and the keynote dip — its scale folded into `camera` as the innermost
 * card transform (the exporter dips the finished card after the camera-layout
 * squeeze and its tile, before tilt / zoom / offset / intro) and its fade as
 * `cardOpacity` on the layer resample.
 */
function withDeviceSegment(frame: FrameState, statics: StaticTextures, scene: Scene): FrameState {
  const seg = deviceSegmentFrame(statics.segment?.framing ?? null, frame.sourceTime, scene.geometry.videoRect);
  if (!seg.active && !seg.dip) return frame;
  const dip = seg.dip;
  return {
    ...frame,
    deviceSegment: seg.active,
    camera: dip ? multiply(frame.camera, affineMat3(dip.transform)) : frame.camera,
    cardOpacity: dip ? dip.alpha : frame.cardOpacity,
  };
}

/** CoreGraphics affine (x' = a·x + c·y + tx, y' = b·x + d·y + ty) → Mat3. */
function affineMat3(t: AffineTransform): Mat3 {
  return [t.a, t.c, t.tx, t.b, t.d, t.ty, 0, 0, 1];
}

/**
 * Frame GPU time from two timestamps bracketing every pass of the frame.
 * A small ring of readback buffers avoids ever waiting on a map.
 */
class GpuTimer {
  readonly querySet: GPUQuerySet;
  private resolveBuf: GPUBuffer;
  private ring: { buf: GPUBuffer; busy: boolean }[] = [];
  private pending: { buf: GPUBuffer; busy: boolean } | null = null;

  constructor(private readonly device: GPUDevice, private readonly onResult: (ms: number) => void) {
    this.querySet = device.createQuerySet({ type: "timestamp", count: 2 });
    this.resolveBuf = device.createBuffer({ size: 16, usage: GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC });
    for (let i = 0; i < 4; i++) {
      this.ring.push({
        buf: device.createBuffer({ size: 16, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST }),
        busy: false,
      });
    }
  }

  /** A readback slot is free, so this frame can be measured. */
  armed(): boolean {
    return this.ring.some((r) => !r.busy);
  }

  resolve(enc: GPUCommandEncoder): void {
    const slot = this.ring.find((r) => !r.busy);
    this.pending = null;
    if (!slot) return;
    enc.resolveQuerySet(this.querySet, 0, 2, this.resolveBuf, 0);
    enc.copyBufferToBuffer(this.resolveBuf, 0, slot.buf, 0, 16);
    slot.busy = true;
    this.pending = slot;
  }

  collect(): void {
    const slot = this.pending;
    if (!slot) return;
    this.pending = null;
    slot.buf
      .mapAsync(GPUMapMode.READ)
      .then(() => {
        const t = new BigUint64Array(slot.buf.getMappedRange());
        const ns = Number(t[1] - t[0]);
        slot.buf.unmap();
        slot.busy = false;
        if (ns > 0 && ns < 1e9) this.onResult(ns / 1e6);
      })
      .catch(() => {
        slot.busy = false;
      });
  }

  destroy(): void {
    this.querySet.destroy();
    this.resolveBuf.destroy();
    for (const r of this.ring) r.buf.destroy();
  }
}
