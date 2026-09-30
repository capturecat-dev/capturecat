/**
 * Webcam (camera recording) — the web twin of the Mac EXPORTER's camera
 * blocks in `VideoExporter.export`, 1:1:
 *
 *  - Static assets (`CameraStaticAssets`): mask / stroke / bubble shadow /
 *    ring light / name tag baked ONCE at the canonical bottom-right
 *    `baseRect` (core `exportCameraStatics` + cameraAssets.ts) and
 *    re-targeted per frame by the affine `assetTransform`.
 *  - Per frame (core `exportFrameCamera`): `ReactiveCameraLayout.cameraRect`
 *    from the RAW smoothed zoom (`FrameState.cameraKey.zoom`, the bubble
 *    shrinks / slides away as the screen zooms), `CameraLayoutMath.resolve`
 *    over the camera-layout regions, the camera frame at
 *    `sourceTime − cameraTimeOffset` (second decode stream) or the poster
 *    (`camera_poster.png`) before the camera starts, mirror, CameraStyleMath
 *    adjustments + filter preset.
 *  - Classic bubble (`isPlainBubble`): the group (shadow → ring → masked
 *    camera → stroke → tag, over transparency) → 3D bubble tilt → opacity →
 *    over the CANVAS after the warp ("overlay" stage).
 *  - Dynamic layouts (cameraOnly / sideBySide / mid-morph): the tile — a
 *    CIRoundedRectangle-masked camera with the chrome-faded bubble assets and
 *    a cardness-faded card shadow — is composed onto the card layer AFTER the
 *    side-by-side squeeze (`cardTransform` hook → FrameGraph) and BEFORE the
 *    camera warp ("cardTop" stage), so tilt / zoom move it with the card.
 *
 * Mac EXPORT behaviour ported on purpose (each measured against the real
 * exporter output — parity fixture 13 — or the real CoreImage filters):
 *  - `fadeImage` (CIColorMatrix) works on UNPREMULTIPLIED colour: a fade by a
 *    scales premultiplied RGB by a² and alpha by a, so the chrome-faded
 *    stroke / ring / tag and a bubble opacity < 1 DARKEN as they fade;
 *  - `cropped(to:)` and CIRoundedRectangleGenerator are area-coverage
 *    anti-aliased and nested crops multiply (tile edge = coverage⁴);
 *  - the bubble shadow's CIGaussianBlur sigma is 6·canvasScale (NOT halved
 *    like the frame shadow);
 *  - the camera is aspect-FILLED with CoreImage's bilinear affine resample
 *    (no mip / Lanczos), clear outside its extent;
 *  - filters: CoreImage colour cubes for the presets, exact CIColorControls
 *    (saturation → contrast → brightness) and CIHueAdjust kernels — GPU vs
 *    CoreImage ≤ 2/255 (see cameraShaders.ts).
 */
import { adjustmentsFromSettings, isIdentity as adjustmentsIdentity } from "../../core/math/cameraStyleMath";
import {
  compositeCameraGeometry,
  exportCameraStatics,
  exportFrameCamera,
  fadeAlpha,
  type ExportCameraStatics,
  type ExportFrameCamera,
} from "../../core/math/exportCameraBubble";
import type { AffineTransform } from "../../core/math/geometry";
import { perspectiveDistance, projectionTransform } from "../../core/math/tiltMath";
import type { Project, Rect } from "../../core/model";
import type { WorkingSpace } from "../color";
import { L, Uniforms } from "../gpu/resources";
import {
  cameraAssetWGSL,
  cameraCardShadowWGSL,
  cameraComposeWGSL,
  cameraLiveWGSL,
  cameraPosterWGSL,
} from "../gpu/cameraShaders";
import { CAMERA_FILTER_LUTS, CAMERA_LUT_SIZE } from "../gpu/cameraFilterLuts";
import { apply, IDENTITY, invert, isIdentity, multiply, toRows, type Mat3 } from "../mat3";
import { CameraSource, type CameraFrame } from "../media/cameraSource";
import { stageHitRecorder } from "../stageHits";
import { bakeCameraAssets, measureTag, type BakedAsset } from "./cameraAssets";
import type { FrameEncoder, FrameState, PassContext, RenderPass, Scene, StaticKeyParts } from "./types";
import { cameraLayoutKey } from "../../core/export/staticSpans";

/** The poster the Mac saves beside the project (Project.cameraPosterURL). */
export const CAMERA_POSTER_REF = "camera_poster.png";

const GROUP_FORMAT: GPUTextureFormat = "rgba16float";
const LUT_ENTRY = (binding: number): GPUBindGroupLayoutEntry => ({
  binding,
  visibility: GPUShaderStage.FRAGMENT,
  texture: { sampleType: "float", viewDimension: "3d" },
});
const RT = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING;

// ── Y-up (CoreImage) → Y-down conversions ───────────────────────────────────

/** CGAffineTransform (Y-up) → row-major Mat3. */
function affineMat(t: AffineTransform): Mat3 {
  return [t.a, t.c, t.tx, t.b, t.d, t.ty, 0, 0, 1];
}
const flip = (h: number): Mat3 => [1, 0, 0, 0, -1, h, 0, 0, 1];
/** The same map in a Y-down canvas of height H: F·M·F. */
function yDown(t: AffineTransform, H: number): Mat3 {
  return multiply(flip(H), multiply(affineMat(t), flip(H)));
}
const rectYDown = (r: Rect, H: number): Rect => ({ x: r.x, y: H - r.y - r.height, width: r.width, height: r.height });

function boundsOf(m: Mat3, r: Rect): Rect {
  const pts = [
    apply(m, r.x, r.y),
    apply(m, r.x + r.width, r.y),
    apply(m, r.x, r.y + r.height),
    apply(m, r.x + r.width, r.y + r.height),
  ];
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  const x = Math.min(...xs);
  const y = Math.min(...ys);
  return { x, y, width: Math.max(...xs) - x, height: Math.max(...ys) - y };
}
function union(a: Rect | null, b: Rect): Rect {
  if (!a) return b;
  const x = Math.min(a.x, b.x);
  const y = Math.min(a.y, b.y);
  return { x, y, width: Math.max(a.x + a.width, b.x + b.width) - x, height: Math.max(a.y + a.height, b.y + b.height) - y };
}

// ── Filter presets: CoreImage colour cubes ──────────────────────────────────

type PresetName = keyof typeof CAMERA_FILTER_LUTS;

/** RGBA8 17³ cube for a preset (r fastest, then g, then b = 3D texel order). */
function presetCube(name: PresetName): Uint8Array<ArrayBuffer> {
  const { grey, data } = CAMERA_FILTER_LUTS[name];
  const raw = atob(data);
  const n = CAMERA_LUT_SIZE ** 3;
  const out = new Uint8Array(n * 4);
  for (let i = 0; i < n; i++) {
    const r = raw.charCodeAt(grey ? i : i * 3);
    out[i * 4] = r;
    out[i * 4 + 1] = grey ? r : raw.charCodeAt(i * 3 + 1);
    out[i * 4 + 2] = grey ? r : raw.charCodeAt(i * 3 + 2);
    out[i * 4 + 3] = 255;
  }
  return out;
}

// ── Per-frame plan ──────────────────────────────────────────────────────────

interface AssetLayer {
  kind: "asset";
  asset: GpuAsset;
  /** asset px → output px (Y-down). */
  xform: Mat3;
  fade: number;
  alphaOnly: boolean;
}
interface CardShadowLayer {
  kind: "cardShadow";
}
interface CameraLayer {
  kind: "camera";
}
type Layer = AssetLayer | CardShadowLayer | CameraLayer;

interface GpuAsset {
  baked: BakedAsset;
  texture: GPUTexture;
  view: GPUTextureView;
}

interface CardShadowSpec {
  rect: Rect;
  radius: number;
  sigma: number;
  alpha: number;
  offsetY: number;
  extent: Rect;
  key: string;
}

interface Plan {
  outputTime: number;
  cam: ExportFrameCamera;
  squeeze: Mat3;
  /** "plain" → overlay stage, "override" → cardTop stage. */
  path: "plain" | "override" | "none";
  source: { kind: "live"; frame: CameraFrame } | { kind: "poster" } | null;
  /** Camera tile rect (Y-down). */
  rect: Rect;
  layers: Layer[];
  mask: { kind: "asset"; xform: Mat3 } | { kind: "roundedRect"; radius: number };
  cardShadow: CardShadowSpec | null;
  /** Group bounds (Y-down, integer, inside the target). */
  bounds: Rect;
  tilt: Mat3;
  opacity: number;
}

interface Statics {
  key: string;
  statics: ExportCameraStatics;
  assets: { mask: GpuAsset | null; stroke: GpuAsset | null; shadow: GpuAsset | null; ring: GpuAsset | null; tag: GpuAsset | null };
}

// ── The feature ─────────────────────────────────────────────────────────────

export class CameraFeature {
  private source: CameraSource | null = null;
  private statics: Statics | null = null;
  private poster: { bitmap: ImageBitmap; space: WorkingSpace; texture: GPUTexture; view: GPUTextureView } | null = null;
  private group: { texture: GPUTexture; view: GPUTextureView; width: number; height: number } | null = null;
  private shadowCache: { texture: GPUTexture; view: GPUTextureView; width: number; height: number; key: string } | null = null;
  private plan: Plan | null = null;
  private requestFrame: () => void = () => {};
  /** Export: the exact camera frame for this output time (set by prefetch). */
  private exact: { outputTime: number; frame: CameraFrame | null } | null = null;
  private lastTime = Number.NaN;
  private warned = false;
  private assetU: Uniforms[] = [];
  private camU: Uniforms | null = null;
  private shadowU: Uniforms | null = null;
  private composeU: Uniforms | null = null;
  /** The rect the bubble / tile was composited at this frame (stage hit-testing). */
  private readonly hit = stageHitRecorder("camera");
  /**
   * Preview: the camera frame the last plan wanted vs. the one it drew. A
   * seek resolves only once they match (EditorPlaybackController seeks the
   * camera player with zero tolerance) — see `inputsReady`.
   */
  private wait = { wanted: -1, drawn: -1, waiting: false };

  readonly prepare: RenderPass;
  readonly tile: RenderPass;
  readonly overlay: RenderPass;

  constructor() {
    const self = this;
    this.prepare = {
      name: "camera-prepare",
      stage: "prepare",
      sceneChanged: (ctx) => self.sceneChanged(ctx),
      cardTransform: (ctx, frame) => self.cardTransform(ctx, frame),
      prefetch: (scene, frame) => self.prefetch(scene, frame),
      staticKey: (scene, frame) => self.staticKey(scene, frame),
      encode: (ctx, frame, enc) => self.encodeGroup(ctx, frame, enc),
      destroy: () => self.destroy(),
      stageHit: this.hit,
      inputsReady: () => !self.wait.waiting,
    };
    this.tile = {
      name: "camera-tile",
      stage: "cardTop",
      encode: (ctx, frame, enc) => self.compose(ctx, frame, enc, "override"),
    };
    this.overlay = {
      name: "camera-bubble",
      stage: "overlay",
      encode: (ctx, frame, enc) => self.compose(ctx, frame, enc, "plain"),
    };
    // DEV: the lab harness reads decode counters from the worker global.
    if (import.meta.env?.DEV) ((globalThis as { __cameraFeatures?: CameraFeature[] }).__cameraFeatures ??= []).push(this);
  }

  /** Diagnostics for the lab (decode stream stats, current path). */
  debugState() {
    return {
      open: this.source?.isOpen ?? false,
      error: this.source?.error?.message ?? null,
      path: this.plan?.path ?? "none",
      source: this.plan?.source?.kind ?? null,
      liveIndex: this.plan?.source?.kind === "live" ? this.plan.source.frame.index : -1,
      /** VideoFrame.timestamp (µs) of the camera frame drawn. */
      liveTimestamp: this.plan?.source?.kind === "live" ? this.plan.source.frame.frame.timestamp : null,
      /** Sample index the playhead wants (−1: before the camera starts / no stream). */
      wantedIndex: this.wait.wanted,
      /** A seek is being held for the wanted camera frame. */
      waiting: this.wait.waiting,
      rect: this.plan?.rect ?? null,
      chrome: this.plan?.cam.layout.chromeOpacity ?? null,
      counters: this.source?.counters ?? null,
      stream: this.source?.stats ?? null,
    };
  }

  // ── Scene ────────────────────────────────────────────────────────────────

  private cameraUrl(scene: Scene): string | null {
    const p = scene.extras.project;
    if (!p || !p.settings.showCamera || !p.cameraVideoURL) return null;
    return scene.extras.media.files?.[p.cameraVideoURL] ?? null;
  }

  /** Opens / swaps / closes the camera decode stream for the scene's camera file. */
  private ensureSource(scene: Scene): CameraSource | null {
    const url = this.cameraUrl(scene);
    if (this.source && this.source.url !== url) {
      this.source.dispose();
      this.source = null;
    }
    if (!url) return null;
    if (!this.source) {
      this.source = new CameraSource(url, {
        onFrame: () => this.requestFrame(),
        onError: (e) => {
          // No bubble is drawn without a camera stream (Mac: cameraReader nil); say why once.
          if (!this.warned) console.warn(`[camera] ${e.message}`);
          this.warned = true;
          this.requestFrame();
        },
      });
      // Statics re-key on the opened track (natural size, reader present).
      void this.source.ready.then(() => this.requestFrame());
    }
    return this.source;
  }

  private sceneChanged(ctx: PassContext): void {
    this.requestFrame = ctx.requestFrame;
    this.ensureSource(ctx.scene);
  }

  private project(scene: Scene): Project | null {
    return scene.extras.project;
  }

  private ensureStatics(ctx: PassContext, source: CameraSource): Statics {
    const scene = ctx.scene;
    const s = this.project(scene)!.settings;
    const nat = source.naturalSize;
    // Re-bake only when an INPUT of the bake changes (not on every scene
    // version — an unrelated slider drag must not re-run the CPU blur).
    const key = JSON.stringify([
      scene.target.width, scene.target.height, scene.geometry.canvasScale, scene.workingSpace,
      source.isOpen, nat.width, nat.height,
      s.cameraSize, s.cameraShape, s.cameraOrientation, s.cameraCornerRadius, s.cameraBorderWidth,
      s.cameraBorderColor ?? null, s.cameraRingLight, s.cameraTagText, s.cameraTagSubtext, s.cameraTagFontName ?? null,
      s.cameraTagPosition, s.cameraTagTextColor, s.cameraTagBackgroundColor,
      // Loop range inputs (below).
      scene.extras.timeMap.outputDuration, scene.extras.timeMap.sourceTime(0), this.project(scene)!.cameraTimeOffset,
    ]);
    if (this.statics?.key === key) return this.statics;
    this.destroyStatics(ctx.device);
    const target = scene.target;
    const cs = scene.geometry.canvasScale;
    // The preview's reference canvas (headless export: none → the output itself).
    const reference = Math.abs(cs - 1) < 1e-9 ? { width: 0, height: 0 } : { width: target.width / cs, height: target.height / cs };
    const statics = exportCameraStatics(s, target, reference, nat, source.isOpen, measureTag);
    let assets: Statics["assets"] = { mask: null, stroke: null, shadow: null, ring: null, tag: null };
    if (statics.assets) {
      const baked = bakeCameraAssets(statics.assets, s, target, scene.workingSpace);
      const up = (b: BakedAsset | null): GpuAsset | null => {
        if (!b) return null;
        const texture = ctx.device.createTexture({
          label: "camera-asset",
          size: { width: b.width, height: b.height },
          format: "rgba8unorm",
          usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
        });
        ctx.device.queue.writeTexture({ texture }, b.rgba, { bytesPerRow: b.width * 4 }, { width: b.width, height: b.height });
        return { baked: b, texture, view: texture.createView() };
      };
      assets = { mask: up(baked.mask), stroke: up(baked.stroke), shadow: up(baked.shadow), ring: up(baked.ring), tag: up(baked.tag) };
    }
    this.statics = { key, statics, assets };
    // Loop-aware camera prefetch over the span the timeline covers (monotonic
    // timelines only — a clip reorder simply decodes on demand).
    const map = scene.extras.timeMap;
    const off = this.project(scene)!.cameraTimeOffset;
    const start = source.indexAt(Math.max(0, map.sourceTime(0) - off));
    const end = source.indexAt(map.sourceTime(Math.max(0, map.outputDuration - 1e-4)) - off);
    source.setLoop(start >= 0 && end > start ? { start, end } : null);
    return this.statics;
  }

  private destroyStatics(device: GPUDevice): void {
    const old = this.statics;
    this.statics = null;
    if (!old) return;
    const textures = Object.values(old.assets).filter((a): a is GpuAsset => a !== null).map((a) => a.texture);
    if (textures.length) void device.queue.onSubmittedWorkDone().then(() => textures.forEach((t) => t.destroy()));
  }

  private posterTexture(ctx: PassContext): GPUTextureView | null {
    const bitmap = ctx.scene.extras.assets.images.get(CAMERA_POSTER_REF);
    if (!bitmap) return null;
    const space = ctx.scene.workingSpace;
    if (this.poster?.bitmap === bitmap && this.poster.space === space) return this.poster.view;
    const old = this.poster;
    if (old) void ctx.device.queue.onSubmittedWorkDone().then(() => old.texture.destroy());
    const texture = ctx.device.createTexture({
      label: "camera-poster",
      size: { width: bitmap.width, height: bitmap.height },
      format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
    });
    // CIImage(cgImage:, options: [.colorSpace: sRGB]) colour-matched into the working space.
    ctx.device.queue.copyExternalImageToTexture(
      { source: bitmap },
      { texture, colorSpace: space, premultipliedAlpha: true },
      { width: bitmap.width, height: bitmap.height },
    );
    this.poster = { bitmap, space, texture, view: texture.createView() };
    return this.poster.view;
  }

  // ── Per frame ────────────────────────────────────────────────────────────

  private async prefetch(scene: Scene, frame: FrameState): Promise<void> {
    const url = this.cameraUrl(scene);
    if (!url) return;
    if (!this.source || this.source.url !== url) {
      this.source?.dispose();
      this.source = new CameraSource(url, { label: "camera-export" });
    }
    await this.source.ready;
    const p = scene.extras.project!;
    const f = await this.source.exact(frame.sourceTime - p.cameraTimeOffset);
    this.exact = { outputTime: frame.outputTime, frame: f };
  }

  /**
   * Export fast path (StaticSpanCollapse.FrameKey): the camera sample the
   * forward-only reader sits on and this frame's resolved layout as the key
   * string — the same `exportFrameCamera` math `makePlan` renders with, over
   * the pure statics (no GPU bake: a skipped frame never renders). Null when
   * the project has no open camera stream (Mac: `cameraReaderOutput == nil`).
   */
  private keyStatics: { key: string; statics: ExportCameraStatics } | null = null;
  private staticKey(scene: Scene, frame: FrameState): StaticKeyParts | null {
    const project = this.project(scene);
    const source = this.source;
    if (!project || !source || !source.isOpen || source.url !== this.cameraUrl(scene)) return null;
    const s = project.settings;
    const target = scene.target;
    const cs = scene.geometry.canvasScale;
    const nat = source.naturalSize;
    const key = JSON.stringify([target.width, target.height, cs, nat.width, nat.height, s.cameraSize, s.cameraShape, s.cameraOrientation]);
    if (this.keyStatics?.key !== key) {
      const reference = Math.abs(cs - 1) < 1e-9 ? { width: 0, height: 0 } : { width: target.width / cs, height: target.height / cs };
      this.keyStatics = { key, statics: exportCameraStatics(s, target, reference, nat, source.isOpen, measureTag) };
    }
    const vr = scene.geometry.videoRect;
    const videoRectYUp: Rect = { x: vr.x, y: target.height - vr.y - vr.height, width: vr.width, height: vr.height };
    const cam = exportFrameCamera(this.keyStatics.statics, s, project.cameraLayoutRegions, videoRectYUp, target, project.cameraTimeOffset, {
      currentTime: frame.sourceTime,
      zoom: frame.cameraKey?.zoom ?? 1,
      sourceVisible: frame.video !== null,
      cameraFrameDecoded: true,
      posterAvailable: false,
    });
    return { cameraSampleSeconds: source.exportSampleSeconds, cameraLayout: cameraLayoutKey(cam.layout) };
  }

  private cardTransform(ctx: PassContext, frame: FrameState): Mat3 | null {
    this.plan = this.makePlan(ctx, frame);
    return this.plan?.squeeze ?? null;
  }

  private makePlan(ctx: PassContext, frame: FrameState): Plan | null {
    this.wait = { wanted: -1, drawn: -1, waiting: false };
    const scene = ctx.scene;
    const project = this.project(scene);
    const source = this.ensureSource(scene);
    if (!project || !source) return null;
    const s = project.settings;
    const H = scene.target.height;
    const statics = this.ensureStatics(ctx, source);

    // Camera frame: export → the exact frame prefetch resolved; preview →
    // random access with decode-ahead while the clock advances.
    const target = frame.sourceTime - project.cameraTimeOffset;
    let live: CameraFrame | null = null;
    if (this.exact && this.exact.outputTime === frame.outputTime) {
      live = this.exact.frame;
    } else {
      const dt = frame.outputTime - this.lastTime;
      const playing = dt > 0 && dt < 0.25;
      live = source.preview(target, playing);
    }
    this.lastTime = frame.outputTime;
    const posterAvailable = ctx.scene.extras.assets.images.has(CAMERA_POSTER_REF);

    const vr = scene.geometry.videoRect;
    const videoRectYUp: Rect = { x: vr.x, y: H - vr.y - vr.height, width: vr.width, height: vr.height };
    const cam = exportFrameCamera(statics.statics, s, project.cameraLayoutRegions, videoRectYUp, scene.target, project.cameraTimeOffset, {
      currentTime: frame.sourceTime,
      zoom: frame.cameraKey?.zoom ?? 1,
      sourceVisible: frame.video !== null,
      cameraFrameDecoded: live !== null,
      posterAvailable,
    });
    if (!(this.exact && this.exact.outputTime === frame.outputTime)) {
      this.wait = previewWait(source, target, live, frame.video !== null, cam.layout.cameraOpacity);
    }
    const squeeze = yDown(cam.cardTransform, H);
    const plan: Plan = {
      outputTime: frame.outputTime,
      cam,
      squeeze,
      path: cam.path,
      source: cam.source === "live" && live ? { kind: "live", frame: live } : cam.source === "poster" ? { kind: "poster" } : null,
      rect: { x: 0, y: 0, width: 0, height: 0 },
      layers: [],
      mask: { kind: "roundedRect", radius: 0 },
      cardShadow: null,
      bounds: { x: 0, y: 0, width: 0, height: 0 },
      tilt: IDENTITY,
      opacity: 1,
    };
    if (cam.path === "none" || !plan.source) {
      plan.path = "none";
      return plan;
    }
    const a = statics.assets;
    const layers: Layer[] = [];
    const asset = (g: GpuAsset | null, xform: Mat3, fade = 1, alphaOnly = false) => {
      if (g) layers.push({ kind: "asset", asset: g, xform, fade, alphaOnly });
    };
    let pitch = 0;
    let yaw = 0;
    let opacity = 1;
    if (cam.path === "plain" && cam.plain) {
      const x = yDown(cam.plain.assetTransform, H);
      plan.rect = rectYDown(cam.plain.rect, H);
      asset(a.shadow, x);
      asset(a.ring, x);
      layers.push({ kind: "camera" });
      asset(a.stroke, x);
      asset(a.tag, x);
      plan.mask = { kind: "asset", xform: x };
      pitch = cam.plain.tiltPitch;
      yaw = cam.plain.tiltYaw;
      opacity = cam.plain.opacity;
    } else if (cam.path === "override" && cam.override) {
      const o = cam.override;
      const x = yDown(o.assetTransform, H);
      plan.rect = rectYDown(o.rect, H);
      const chrome = o.chromeVisible ? o.chrome : 0;
      if (o.chromeVisible) asset(a.shadow, x, chrome);
      if (o.cardShadow) {
        const cs = o.cardShadow;
        const spec = {
          rect: rectYDown(cs.rect, H),
          radius: cs.cornerRadius,
          sigma: cs.shadowRadius / 2,
          alpha: cs.shadowOpacity * 0.45,
          offsetY: cs.shadowRadius / 3,
          extent: rectYDown(cs.extent, H),
        };
        plan.cardShadow = { ...spec, key: JSON.stringify(spec) };
        layers.push({ kind: "cardShadow" });
      }
      if (o.chromeVisible) asset(a.ring, x, chrome);
      layers.push({ kind: "camera" });
      if (o.chromeVisible) {
        asset(a.stroke, x, chrome);
        asset(a.tag, x, chrome);
      }
      plan.mask = { kind: "roundedRect", radius: o.maskRadius };
      pitch = o.tiltPitch;
      yaw = o.tiltYaw;
      opacity = o.opacity;
    }
    plan.layers = layers;

    // Group bounds: every layer's footprint, clipped to the target.
    let b: Rect | null = { ...plan.rect };
    for (const l of layers) {
      if (l.kind === "asset") b = union(b, boundsOf(l.xform, l.asset.baked.crop));
      else if (l.kind === "cardShadow" && plan.cardShadow) b = union(b, plan.cardShadow.extent);
    }
    const x0 = Math.max(0, Math.floor(b.x));
    const y0 = Math.max(0, Math.floor(b.y));
    const x1 = Math.min(scene.target.width, Math.ceil(b.x + b.width));
    const y1 = Math.min(scene.target.height, Math.ceil(b.y + b.height));
    plan.bounds = { x: x0, y: y0, width: Math.max(0, x1 - x0), height: Math.max(0, y1 - y0) };
    if (plan.bounds.width <= 0 || plan.bounds.height <= 0) {
      plan.path = "none";
      return plan;
    }

    // compositeCamera: 3D tilt (|pitch| or |yaw| > 0.01) about the rect —
    // applyPerspectiveTilt maps the extent corners through TiltMath, which is
    // exactly this homography (Y-down twin of the Y-up projection) — then
    // fadeImage when opacity < 1.
    if (Math.abs(pitch) > 0.01 || Math.abs(yaw) > 0.01) {
      const r = plan.rect;
      const h = projectionTransform(pitch, yaw, 0, { x: r.x + r.width / 2, y: r.y + r.height / 2 }, perspectiveDistance({ width: r.width, height: r.height }));
      plan.tilt = [h.m11, h.m21, h.m31, h.m12, h.m22, h.m32, h.m13, h.m23, h.m33];
    }
    plan.opacity = opacity < 1 ? fadeAlpha(opacity) : 1;
    return plan;
  }

  // ── GPU: group ───────────────────────────────────────────────────────────

  private ensureGroup(device: GPUDevice, w: number, h: number) {
    if (this.group && this.group.width === w && this.group.height === h) return this.group;
    const old = this.group;
    if (old) void device.queue.onSubmittedWorkDone().then(() => old.texture.destroy());
    const texture = device.createTexture({ label: "camera-group", size: { width: w, height: h }, format: GROUP_FORMAT, usage: RT });
    this.group = { texture, view: texture.createView(), width: w, height: h };
    return this.group;
  }

  private ensureShadowCache(device: GPUDevice, w: number, h: number) {
    if (this.shadowCache && this.shadowCache.width === w && this.shadowCache.height === h) return this.shadowCache;
    const old = this.shadowCache;
    if (old) void device.queue.onSubmittedWorkDone().then(() => old.texture.destroy());
    const texture = device.createTexture({ label: "camera-card-shadow", size: { width: w, height: h }, format: "r16float", usage: RT });
    this.shadowCache = { texture, view: texture.createView(), width: w, height: h, key: "" };
    return this.shadowCache;
  }

  private uni(i: number, device: GPUDevice): Uniforms {
    while (this.assetU.length <= i) this.assetU.push(new Uniforms(device, 24, `camera-asset-u${this.assetU.length}`));
    return this.assetU[i];
  }

  private encodeGroup(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    // The FrameGraph calls cardTransform first; a caller that did not still gets a plan.
    if (!this.plan || this.plan.outputTime !== frame.outputTime) this.plan = this.makePlan(ctx, frame);
    const plan = this.plan;
    if (!plan || plan.path === "none" || !plan.source) return;
    const { device, pipelines } = ctx;
    const { width: W, height: H } = ctx.scene.target;
    const group = this.ensureGroup(device, W, H);
    const b = plan.bounds;

    // Card shadow cache (re-rendered only when its geometry changes — morphs).
    if (plan.cardShadow) {
      const cache = this.ensureShadowCache(device, W, H);
      if (cache.key !== plan.cardShadow.key) {
        const cs = plan.cardShadow;
        this.shadowU ??= new Uniforms(device, 12, "camera-card-shadow-u");
        this.shadowU.write([
          cs.rect.x, cs.rect.y, cs.rect.width, cs.rect.height,
          cs.radius, cs.sigma, cs.alpha, cs.offsetY,
          cs.extent.x, cs.extent.y, cs.extent.width, cs.extent.height,
        ]);
        const { pipeline, layout } = pipelines.get({
          id: "camera-card-shadow", code: cameraCardShadowWGSL, format: "r16float", blend: "replace", entries: [L.uniform(0)],
        });
        const pass = enc.beginPass({
          label: "camera-card-shadow",
          colorAttachments: [{ view: cache.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
        });
        const ex0 = Math.max(0, Math.floor(cs.extent.x));
        const ey0 = Math.max(0, Math.floor(cs.extent.y));
        const ex1 = Math.min(W, Math.ceil(cs.extent.x + cs.extent.width));
        const ey1 = Math.min(H, Math.ceil(cs.extent.y + cs.extent.height));
        if (ex1 > ex0 && ey1 > ey0) {
          pass.setScissorRect(ex0, ey0, ex1 - ex0, ey1 - ey0);
          pass.setPipeline(pipeline);
          pass.setBindGroup(0, device.createBindGroup({ layout, entries: [{ binding: 0, resource: { buffer: this.shadowU.buffer } }] }));
          pass.draw(3);
        }
        pass.end();
        cache.key = cs.key;
      }
    }

    const pass = enc.beginPass({
      label: "camera-group",
      colorAttachments: [{ view: group.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
    });
    pass.setScissorRect(b.x, b.y, b.width, b.height);
    const assetPipe = pipelines.get({
      id: "camera-asset", code: cameraAssetWGSL, format: GROUP_FORMAT, blend: "premultipliedOver",
      entries: [L.uniform(0), L.texture(1)],
    });
    let slot = 0;
    const drawAsset = (view: GPUTextureView, inv: Mat3, origin: { x: number; y: number }, crop: Rect, fade: number, alphaOnly: boolean) => {
      const u = this.uni(slot++, device);
      // Pixel footprint in asset px (axis-aligned scale): the CI crop's AA coverage.
      const fpx = Math.max(1e-6, Math.abs(inv[0]));
      const fpy = Math.max(1e-6, Math.abs(inv[4]));
      u.write([...toRows(inv), origin.x, origin.y, 0, 0, crop.x, crop.y, crop.width, crop.height, fade, alphaOnly ? 1 : 0, fpx, fpy]);
      pass.setPipeline(assetPipe.pipeline);
      pass.setBindGroup(0, device.createBindGroup({
        layout: assetPipe.layout,
        entries: [
          { binding: 0, resource: { buffer: u.buffer } },
          { binding: 1, resource: view },
        ],
      }));
      pass.draw(3);
    };

    for (const l of plan.layers) {
      if (l.kind === "asset") {
        const bk = l.asset.baked;
        drawAsset(l.asset.view, invert(l.xform), bk.origin, bk.crop, l.fade, l.alphaOnly);
      } else if (l.kind === "cardShadow" && this.shadowCache && plan.cardShadow) {
        drawAsset(this.shadowCache.view, IDENTITY, { x: 0, y: 0 }, { x: 0, y: 0, width: W, height: H }, 1, true);
      } else if (l.kind === "camera") {
        this.drawCamera(ctx, pass, plan, H);
      }
    }
    pass.end();
  }

  private drawCamera(ctx: PassContext, pass: GPURenderPassEncoder, plan: Plan, H: number): void {
    const { device, pipelines, scene } = ctx;
    const src = plan.source!;
    let binding: GPUExternalTexture | GPUTextureView;
    let cw: number;
    let ch: number;
    if (src.kind === "live") {
      const vf = src.frame.frame;
      binding = device.importExternalTexture({ source: vf, colorSpace: scene.workingSpace });
      cw = vf.displayWidth;
      ch = vf.displayHeight;
    } else {
      const view = this.posterTexture(ctx);
      const bmp = scene.extras.assets.images.get(CAMERA_POSTER_REF);
      if (!view || !bmp) return;
      binding = view;
      cw = bmp.width;
      ch = bmp.height;
    }
    const rectUp = plan.cam.path === "plain" ? plan.cam.plain!.rect : plan.cam.override!.rect;
    const g = compositeCameraGeometry({ x: 0, y: 0, width: cw, height: ch }, rectUp, 1, 0, 0);
    if (!g) return;
    // camera px (Y-down) → CI Y-up → fill transform → output Y-up → output Y-down.
    const camToOut = multiply(flip(H), multiply(affineMat(g.transform), flip(ch)));
    const inv = invert(camToOut);
    const s = scene.extras.project!.settings;
    const adj = adjustmentsFromSettings(s);
    const identity = adjustmentsIdentity(adj);
    const preset = adj.filter !== "None" ? this.presetView(device, adj.filter as PresetName) : null;
    const mask = plan.mask;
    const maskAsset = this.statics?.assets.mask ?? null;
    const mInv = mask.kind === "asset" ? invert(mask.xform) : IDENTITY;
    const mb = maskAsset?.baked;
    this.camU ??= new Uniforms(device, 52, "camera-u");
    this.camU.write([
      ...toRows(inv),
      cw, ch, s.cameraMirrored ? 1 : 0, 0,
      plan.rect.x, plan.rect.y, plan.rect.width, plan.rect.height,
      adj.brightness, adj.contrast, adj.saturation, (adj.hue * Math.PI) / 180,
      preset ? 1 : 0,
      adj.brightness !== 0 || adj.contrast !== 1 || adj.saturation !== 1 ? 1 : 0,
      adj.hue !== 0 ? 1 : 0,
      identity ? 1 : 0,
      ...toRows(mInv),
      mb?.origin.x ?? 0, mb?.origin.y ?? 0, 0, 0,
      mb?.crop.x ?? 0, mb?.crop.y ?? 0, mb?.crop.width ?? 0, mb?.crop.height ?? 0,
      mask.kind === "roundedRect" || !maskAsset ? 1 : 0,
      mask.kind === "roundedRect" ? mask.radius : 0,
      Math.max(1e-6, Math.abs(mInv[0])),
      Math.max(1e-6, Math.abs(mInv[4])),
    ]);
    const live = src.kind === "live";
    const { pipeline, layout } = pipelines.get({
      id: live ? "camera-live" : "camera-poster",
      code: live ? cameraLiveWGSL : cameraPosterWGSL,
      format: GROUP_FORMAT,
      blend: "premultipliedOver",
      entries: [L.uniform(0), L.sampler(1), L.texture(2), live ? L.external(3) : L.texture(3), LUT_ENTRY(4)],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: this.camU.buffer } },
        { binding: 1, resource: pipelines.linearSampler() },
        { binding: 2, resource: maskAsset?.view ?? this.dummyRGBA(device) },
        { binding: 3, resource: binding },
        { binding: 4, resource: preset ?? this.presetView(device, null) },
      ],
    }));
    pass.draw(3);
  }

  private presets = new Map<string, { texture: GPUTexture; view: GPUTextureView }>();
  /** The preset's 3D colour cube (null → a 1³ placeholder bound when no preset is active). */
  private presetView(device: GPUDevice, name: PresetName | null): GPUTextureView {
    const key = name ?? "none";
    let hit = this.presets.get(key);
    if (!hit) {
      const n = name ? CAMERA_LUT_SIZE : 1;
      const texture = device.createTexture({
        label: `camera-lut-${key}`,
        size: { width: n, height: n, depthOrArrayLayers: n },
        dimension: "3d",
        format: "rgba8unorm",
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
      });
      const data = name ? presetCube(name) : new Uint8Array(4);
      device.queue.writeTexture({ texture }, data, { bytesPerRow: n * 4, rowsPerImage: n }, { width: n, height: n, depthOrArrayLayers: n });
      hit = { texture, view: texture.createView({ dimension: "3d" }) };
      this.presets.set(key, hit);
    }
    return hit.view;
  }

  private dummy: GPUTextureView | null = null;
  private dummyRGBA(device: GPUDevice): GPUTextureView {
    if (!this.dummy) {
      const t = device.createTexture({ label: "camera-dummy", size: { width: 1, height: 1 }, format: "rgba8unorm", usage: GPUTextureUsage.TEXTURE_BINDING });
      this.dummy = t.createView();
    }
    return this.dummy;
  }

  // ── GPU: composite ───────────────────────────────────────────────────────

  private compose(ctx: PassContext, frame: FrameState, enc: FrameEncoder, path: "plain" | "override"): void {
    const plan = this.plan;
    if (!plan || plan.path !== path || plan.outputTime !== frame.outputTime || !this.group || !enc.pass) return;
    const { device, pipelines, scene } = ctx;
    // Hit rect = the rect the group was built at: canvas space for the bubble
    // (overlay, after the warp), card space for the layout tile (cardTop).
    // Usable span = ReactiveCameraLayout.cameraRect's (W − 2·padding − w).
    const pad = this.statics?.statics.cameraPadding ?? 0;
    this.hit.current = {
      rect: plan.rect,
      space: path === "plain" ? "canvas" : "card",
      usable: {
        width: scene.target.width - 2 * pad - plan.rect.width,
        height: scene.target.height - 2 * pad - plan.rect.height,
      },
    };
    this.composeU ??= new Uniforms(device, 32, "camera-compose-u");
    const b = plan.bounds;
    this.composeU.write([
      ...toRows(plan.tilt),
      ...toRows(isIdentity(plan.tilt) ? IDENTITY : invert(plan.tilt)),
      b.x, b.y, b.width, b.height,
      scene.target.width, scene.target.height, plan.opacity, 0,
    ]);
    const { pipeline, layout } = pipelines.get({
      id: "camera-compose", code: cameraComposeWGSL, vertexEntry: "vs_quad", format: enc.format, blend: "premultipliedOver",
      entries: [L.uniform(0, true), L.texture(1)],
    });
    enc.pass.setPipeline(pipeline);
    enc.pass.setBindGroup(0, device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: this.composeU.buffer } },
        { binding: 1, resource: this.group.view },
      ],
    }));
    enc.pass.draw(6);
  }

  // ── Lifetime ─────────────────────────────────────────────────────────────

  private destroy(): void {
    const reg = (globalThis as { __cameraFeatures?: CameraFeature[] }).__cameraFeatures;
    const at = reg?.indexOf(this) ?? -1;
    if (reg && at >= 0) reg.splice(at, 1);
    this.source?.dispose();
    this.source = null;
    for (const u of this.assetU) u.destroy();
    this.assetU = [];
    this.camU?.destroy();
    this.shadowU?.destroy();
    this.composeU?.destroy();
    this.group?.texture.destroy();
    this.shadowCache?.texture.destroy();
    this.poster?.texture.destroy();
    for (const p of this.presets.values()) p.texture.destroy();
    this.presets.clear();
    if (this.statics) for (const a of Object.values(this.statics.assets)) a?.texture.destroy();
    this.statics = null;
    this.group = null;
    this.shadowCache = null;
    this.poster = null;
  }
}

/**
 * Preview seek gate: does the frame just planned still want a camera sample
 * that has not decoded? Nothing to wait for when no camera is drawn (before
 * the camera starts, clip hidden, layout fades it out) or the stream failed;
 * while the stream is still opening, wait (the plan draws no live frame yet).
 */
function previewWait(
  source: CameraSource,
  cameraTime: number,
  live: CameraFrame | null,
  sourceVisible: boolean,
  cameraOpacity: number,
): { wanted: number; drawn: number; waiting: boolean } {
  const drawn = live?.index ?? -1;
  if (!source.isOpen) return { wanted: -1, drawn, waiting: source.error === null };
  const wanted = source.indexAt(cameraTime);
  const needed = wanted >= 0 && sourceVisible && cameraOpacity > 0.001;
  return { wanted, drawn, waiting: needed && drawn !== wanted };
}
