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
 *  - Camera looks (docs/camera-cutout.md §4/§5): wherever the camera draws (either
 *    stage, at `resolve`'s rect B), the group is three weighted STACKS —
 *    today's bubble × (1 − cutout − popOut), the cutout (camera × person
 *    mask, one crop to B) × cutout, the pop-out card (card shadow → gradient
 *    card → person clipped to B with rounded bottom corners) × popOut —
 *    SUMMED as a cross-dissolve (each stack composed over transparent in a
 *    scratch target, scaled premultiplied by its weight, added; drawn
 *    straight into the group when settled), then the name tag, unweighted.
 *    The person mask (camera-mask.ccmask) is looked up by the DRAWN camera
 *    frame's PTS; a missing or stale mask draws every look as the bubble.
 *  - Camera styles (docs/camera-cutout.md §12, core `cameraCardStyle`): the
 *    pop-out stack is card shadow → card fill (gradient / flat colour / the
 *    picked image aspect-filled into C / the camera's own UNMASKED frame,
 *    placed like the person, optionally portrait-blurred by a separable
 *    Gaussian in camera-texel space) → border ring → person. Edge softness /
 *    inset reshape the person mask for both looks (CameraMaskFeed). None of
 *    the keys set → exactly today's passes.
 *  - Full-height split (§12.11): while `resolve` carries a `cardClip`, the
 *    feature hands the FrameGraph the clip (`cardClip` hook — the squeezed
 *    card is cut to that rounded rect at the seam, riders included) and
 *    draws the TILE shadow under it (`seam`, the "cardSeam" stage): the
 *    exporter's makeFrameShadow on the clip rect with shadow radius
 *    shadowRadius × canvasScale × min(1, cardScale). The camera tile (cardTop)
 *    composites after, unclipped.
 *  - Vertical stack (§12.12): in a portrait output with
 *    `cameraPortraitStack` on, `exportFrameCamera` gets the content rect and
 *    resolves the stacked arrangement (camera row on top, the card filling
 *    and clipped to the screen row below); the feature reports the seam
 *    between the rows to the stage (`stackSeam` hit) for the height notch.
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
import { adjustmentsFromSettings, identityAdjustments, isIdentity as adjustmentsIdentity } from "../../core/math/cameraStyleMath";
import { arrangement, lookWeights, stackActive, type CameraLookWeights } from "../../core/math/cameraLayoutMath";
import { layoutZoom } from "../../core/math/reactiveCameraLayout";
import {
  bubbleWeight,
  cardBorderInner,
  cardShadowExportAlpha,
  maskIsFresh,
} from "../../core/math/cameraCutoutMath";
import { blurSigma, borderColors, cameraCardStyle, imageFillRect, type CameraCardStyle, type CardRGB } from "../../core/math/cameraCardStyle";
import type { CameraMaskTrack } from "../../core/mask/cameraMaskCodec";
import {
  compositeCameraGeometry,
  exportCameraStatics,
  exportFrameCamera,
  fadeAlpha,
  type ExportCameraStatics,
  type ExportFrameCamera,
} from "../../core/math/exportCameraBubble";
import { rectHeight, rectWidth, type AffineTransform } from "../../core/math/geometry";
import { perspectiveDistance, projectionTransform } from "../../core/math/tiltMath";
import type { Project, Rect } from "../../core/model";
import { srgbToWorking, type WorkingSpace } from "../color";
import { L, Uniforms } from "../gpu/resources";
import {
  cameraAssetWGSL,
  cameraBlurWGSL,
  cameraCardImageWGSL,
  cameraCardShadowWGSL,
  cameraCardWGSL,
  cameraComposeWGSL,
  cameraStackWGSL,
  cameraLiveWGSL,
  cameraPosterWGSL,
  cameraPrepLiveWGSL,
  cameraPrepPosterWGSL,
} from "../gpu/cameraShaders";
import { CAMERA_FILTER_LUTS, CAMERA_LUT_SIZE } from "../gpu/cameraFilterLuts";
import { apply, IDENTITY, invert, isIdentity, multiply, toRows, type Mat3 } from "../mat3";
import { CameraSource, type CameraFrame } from "../media/cameraSource";
import { CameraMaskFeed } from "../media/cameraMaskFeed";
import { stageHitRecorder } from "../stageHits";
import { bakeCameraAssets, measureTag, type BakedAsset } from "./cameraAssets";
import type { CardClip, FrameEncoder, FrameState, PassContext, RenderPass, Scene, StaticKeyParts } from "./types";
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
/** An analytic blurred rounded-rect shadow, cached in an r16float target ("card": the layout tile's, "look": the pop-out card's). */
interface ShadowLayer {
  kind: "shadow";
  slot: ShadowSlot;
}
/** How the camera layer is clipped (each matches a CoreImage mask the exporter builds). */
type CameraClip =
  | { kind: "asset"; xform: Mat3 }                 // the baked bubble shape mask, re-targeted
  | { kind: "roundedRect"; radius: number; maskRect?: Rect } // CIRoundedRectangleGenerator (layout tile); maskRect = a joined row's shape (§12.14)
  | { kind: "none" }                               // the cutout: one crop to B
  | { kind: "bottomRounded"; radius: number; maskRect: Rect } // the pop-out person: generator over B extended up, cropped to B
  | { kind: "card"; radius: number; rect: Rect };  // the §12.3 camera fill: one crop to B, then through the card mask (C, r)
interface CameraLayer {
  kind: "camera";
  clip: CameraClip;
  /** × the person mask (a look). */
  person: boolean;
  /** The §12.3 camera fill's portrait blur 0…1 (σ = blur × 0.03 × the frame's height, camera px). */
  blur?: number;
}
/** The pop-out card's gradient / flat fill, or its border ring (`ring`). sRGB colours. */
interface CardLayer {
  kind: "card";
  rect: Rect;
  radius: number;
  top: CardRGB;
  bottom: CardRGB;
  /** Border ring: the inner rounded rect it stops at (Y-down). */
  ring?: { rect: Rect; radius: number };
}
/** The §12.3 image card fill (project.json reference of the decoded image). */
interface CardImageLayer {
  kind: "cardImage";
  rect: Rect;
  radius: number;
  ref: string;
}
type Layer = AssetLayer | ShadowLayer | CameraLayer | CardLayer | CardImageLayer;
type ShadowSlot = "card" | "look" | "tile" | "under";

/** A weighted part of the group: composed as a whole, scaled by `weight` and summed with the others. */
interface Stack {
  weight: number;
  layers: Layer[];
}

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
  /** Camera tile rect (Y-down) — the looks' B. */
  rect: Rect;
  /** Weighted stacks, bottom to top (bubble, cutout, pop-out). */
  stacks: Stack[];
  /** Unweighted layers over every stack (the name tag). */
  top: Layer[];
  shadows: Record<ShadowSlot, CardShadowSpec | null>;
  /** The look weights drawn (zero when the mask is missing or stale). */
  looks: CameraLookWeights;
  /** Person-mask frame for the drawn camera frame (−1: no look drawn). */
  maskIndex: number;
  /** The §12 camera styles, resolved (defaults applied, clamped). */
  style: CameraCardStyle;
  /** The full-height split's card clip (§12.11, Y-down, radius clamped); null = none. */
  cardClip: CardClip | null;
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
  /** A stack being cross-faded renders here first (its weight scales the stack as a whole). */
  private scratch: { texture: GPUTexture; view: GPUTextureView; width: number; height: number } | null = null;
  private shadowCaches: Record<ShadowSlot, { texture: GPUTexture; view: GPUTextureView; width: number; height: number; key: string } | null> = { card: null, look: null, tile: null, under: null };
  /** The §12.3 camera fill's blurred frame (camera px): `a` holds the result, `b` the horizontal pass. */
  private cardBlur: { a: GPUTexture; b: GPUTexture; aView: GPUTextureView; bView: GPUTextureView; width: number; height: number; key: string } | null = null;
  private cardBlurWeights: { buffer: GPUBuffer; floats: number } | null = null;
  private prepU: Uniforms | null = null;
  private blurU: [Uniforms | null, Uniforms | null] = [null, null];
  /** The §12.3 image card fill's texture (re-made when the decoded image changes). */
  private cardImage: { bitmap: ImageBitmap; space: WorkingSpace; texture: GPUTexture; view: GPUTextureView } | null = null;
  private cardImageU: Uniforms[] = [];
  /** Bumped whenever the poster texture is rebuilt (the blur cache key). */
  private posterVersion = 0;
  /** camera-mask.ccmask for this renderer (null: none in the scene). */
  private maskFeed: CameraMaskFeed | null = null;
  /** Export: the person-mask frame prefetch decoded for this output time. */
  private exactMask: { outputTime: number; index: number } | null = null;
  private plan: Plan | null = null;
  private requestFrame: () => void = () => {};
  /** Export: the exact camera frame for this output time (set by prefetch). */
  private exact: { outputTime: number; frame: CameraFrame | null } | null = null;
  private lastTime = Number.NaN;
  private warned = false;
  private assetU: Uniforms[] = [];
  /** One uniform block per camera draw in a frame (a cross-fade draws up to three). */
  private camU: Uniforms[] = [];
  private cardU: Uniforms[] = [];
  private stackU: Uniforms[] = [];
  private shadowU: Record<ShadowSlot, Uniforms | null> = { card: null, look: null, tile: null, under: null };
  /** The tile shadow's draw at the seam (its own pass — not one of the group's asset slots). */
  private seamU: Uniforms | null = null;
  private underU: Uniforms | null = null;
  private composeU: Uniforms | null = null;
  /** The rect the bubble / tile was composited at this frame (stage hit-testing). */
  private readonly hit = stageHitRecorder("camera");
  /** The vertical stack's seam between the rows (§12.12) — the stage's height notch. */
  private readonly seamHit = stageHitRecorder("stackSeam");
  /**
   * Preview: the camera frame the last plan wanted vs. the one it drew. A
   * seek resolves only once they match (EditorPlaybackController seeks the
   * camera player with zero tolerance) — see `inputsReady`.
   */
  private wait = { wanted: -1, drawn: -1, waiting: false };

  readonly prepare: RenderPass;
  readonly seam: RenderPass;
  readonly tile: RenderPass;
  readonly overlay: RenderPass;

  constructor() {
    const self = this;
    this.prepare = {
      name: "camera-prepare",
      stage: "prepare",
      sceneChanged: (ctx) => self.sceneChanged(ctx),
      cardTransform: (ctx, frame) => self.cardTransform(ctx, frame),
      cardClip: (_ctx, frame) => (self.plan && self.plan.outputTime === frame.outputTime ? self.plan.cardClip : null),
      prefetch: (scene, frame) => self.prefetch(scene, frame),
      cameraStacking: (scene) => self.stacking(scene),
      staticKey: (scene, frame) => self.staticKey(scene, frame),
      encode: (ctx, frame, enc) => self.encodeGroup(ctx, frame, enc),
      destroy: () => self.destroy(),
      stageHit: this.hit,
      inputsReady: () => !self.wait.waiting,
    };
    this.seam = {
      name: "camera-split-seam",
      stage: "cardSeam",
      encode: (ctx, frame, enc) => self.encodeSeam(ctx, frame, enc),
    };
    this.tile = {
      name: "camera-tile",
      stage: "cardTop",
      stageHit: this.seamHit,
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
      /** Look weights drawn this frame (zero: no look, or the mask is missing / stale). */
      looks: this.plan?.looks ?? null,
      maskIndex: this.plan?.maskIndex ?? -1,
      maskUploaded: this.maskFeed?.uploadedIndex ?? -1,
      maskFresh: this.maskFeed && this.source ? maskIsFresh(this.maskFeed.track.header, this.source.fileFacts) : null,
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

  /** The stack's camera gate (§12.13) — `exportFrameCamera`'s: the camera
   *  stream for this scene is open (statics carry assets) and the stack is on. */
  private stacking(scene: Scene): boolean {
    const p = this.project(scene);
    const url = this.cameraUrl(scene);
    return !!p && !!url && this.source?.url === url && this.source.isOpen && stackActive(p.settings, scene.target);
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
    this.posterVersion++;
    return this.poster.view;
  }

  /** The scene's person mask as this renderer's feed (re-made when the asset changes). */
  private ensureMaskFeed(scene: Scene, device?: GPUDevice): CameraMaskFeed | null {
    const track: CameraMaskTrack | null = scene.extras.assets.cameraMask ?? null;
    if (this.maskFeed?.track === track) return this.maskFeed;
    this.maskFeed?.dispose(device);
    this.maskFeed = track ? new CameraMaskFeed(track, () => this.requestFrame()) : null;
    return this.maskFeed;
  }

  /** The person mask can be drawn (present, decodable, made from THIS camera file — §2). */
  private maskUsable(feed: CameraMaskFeed | null, source: CameraSource): feed is CameraMaskFeed {
    return !!feed && !feed.broken && feed.frameCount > 0 && maskIsFresh(feed.track.header, source.fileFacts);
  }

  /** Mask frame for the camera frame drawn: the live frame's PTS, or frame 0 under the poster (§2). */
  private maskIndexFor(feed: CameraMaskFeed, source: CameraSource, live: CameraFrame | null): number {
    if (!live) return 0;
    const pts = source.ptsOf(live.index);
    return pts === null ? 0 : feed.indexForPts(pts);
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
    // The person mask joins the exact-frame wait: decoded before this frame renders.
    this.exactMask = null;
    // The vertical stack's camera row wears the whole-video look, Side by Side included (§12.12).
    const w = lookWeights(frame.sourceTime, p.cameraLayoutRegions, p.settings.cameraLook, this.source.isOpen && stackActive(p.settings, scene.target));
    const feed = this.ensureMaskFeed(scene);
    if ((w.cutout > 0 || w.popOut > 0) && this.maskUsable(feed, this.source)) {
      const index = this.maskIndexFor(feed, this.source, f);
      try {
        await feed.load(index);
        this.exactMask = { outputTime: frame.outputTime, index };
      } catch {
        // feed.broken → the looks draw the plain bubble
      }
    }
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
      focalX: frame.cameraKey?.focalX,
      focalY: frame.cameraKey?.focalY,
      sourceVisible: frame.video !== null,
      cameraFrameDecoded: true,
      posterAvailable: false,
      maskAvailable: this.maskUsable(this.ensureMaskFeed(scene), source),
    }, contentRectYUp(scene));
    // The (gated) look weights end the key (docs/camera-cutout.md §11): a fading look never collapses.
    return { cameraSampleSeconds: source.exportSampleSeconds, cameraLayout: cameraLayoutKey(cam.layout, cam.lookWeights) };
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
    // The person mask gates the looks (§2): present, decodable, FRESH for this camera file.
    const feed = this.ensureMaskFeed(scene, ctx.device);
    const maskAvailable = this.maskUsable(feed, source);
    const cam = exportFrameCamera(statics.statics, s, project.cameraLayoutRegions, videoRectYUp, scene.target, project.cameraTimeOffset, {
      currentTime: frame.sourceTime,
      zoom: frame.cameraKey?.zoom ?? 1,
      focalX: frame.cameraKey?.focalX,
      focalY: frame.cameraKey?.focalY,
      sourceVisible: frame.video !== null,
      cameraFrameDecoded: live !== null,
      posterAvailable,
      maskAvailable,
    }, contentRectYUp(scene));
    // The vertical stack's seam (§12.12): the gap between the rows, card
    // space; `usable.height` = the two rows' heights, so a drag of dy moves
    // the ratio by dy ÷ usable.height. Only while the stack is the arrangement
    // and the row is not yielding to a zoom (§12.13 — a drag would set the
    // yielded height).
    const yielding = (s.cameraShrinkOnZoom ?? true) && layoutZoom(frame.cameraKey?.zoom ?? 1, true) > 1.001;
    if (cam.stack && !yielding && arrangement(frame.sourceTime, project.cameraLayoutRegions, true).stacked) {
      const top = rectYDown(cam.stack.camera, H);
      const bottom = rectYDown(cam.stack.screen, H);
      this.seamHit.current = {
        rect: { x: top.x, y: top.y + top.height, width: top.width, height: bottom.y - (top.y + top.height) },
        space: "card",
        usable: { width: top.width, height: top.height + bottom.height },
      };
    }
    const exporting = !!(this.exact && this.exact.outputTime === frame.outputTime);
    if (!exporting) {
      this.wait = previewWait(source, target, live, frame.video !== null, cam.layout.cameraOpacity);
    }
    const squeeze = yDown(cam.cardTransform, H);
    const planSource: Plan["source"] =
      cam.source === "live" && live ? { kind: "live", frame: live } : cam.source === "poster" ? { kind: "poster" } : null;

    // Camera looks (docs/camera-cutout.md §4/§5): exportFrameCamera's looks
    // stage — weights gated on the fresh mask, geometry at the drawn rect B —
    // and the mask frame of the camera frame actually DRAWN (frame 0 under
    // the poster).
    const zero: CameraLookWeights = { cutout: 0, popOut: 0 };
    const camLooks = planSource && maskAvailable && feed ? cam.looks : null;
    const looks: CameraLookWeights = camLooks ? cam.lookWeights : zero;
    let maskIndex = -1;
    if (camLooks && feed) {
      if (exporting) {
        maskIndex = this.exactMask?.outputTime === frame.outputTime ? this.exactMask.index : this.maskIndexFor(feed, source, live);
      } else {
        maskIndex = this.maskIndexFor(feed, source, camLooks.maskFrame === "live" ? live : null);
        feed.readAhead(maskIndex);
        // Seek gate: hold until the drawn frame's mask has decoded.
        if (!feed.peek(maskIndex)) this.wait = { ...this.wait, waiting: true };
      }
    }

    const plan: Plan = {
      outputTime: frame.outputTime,
      cam,
      squeeze,
      path: cam.path,
      source: planSource,
      rect: { x: 0, y: 0, width: 0, height: 0 },
      stacks: [],
      top: [],
      shadows: { card: null, look: null, tile: null, under: null },
      looks,
      maskIndex,
      style: cameraCardStyle(s),
      cardClip: null,
      bounds: { x: 0, y: 0, width: 0, height: 0 },
      tilt: IDENTITY,
      opacity: 1,
    };
    // Full-height split (§12.11): the card clip at the seam and its tile
    // shadow — whether or not the camera itself draws this frame.
    const clipUp = cam.layout.cardClip;
    if (clipUp && rectWidth(clipUp) > 0 && rectHeight(clipUp) > 0) {
      const rect = rectYDown(clipUp, H);
      const radius = Math.min(Math.max(0, cam.layout.cardClipCornerRadius), Math.min(rect.width, rect.height) / 2);
      // A joined stack (§12.14): the generator runs past the seam, cropped to the row.
      const shapeUp = cam.layout.cardClipShapeRect ?? null;
      const shape = shapeUp ? rectYDown(shapeUp, H) : null;
      plan.cardClip = shape
        ? { rect, radius, shape, shapeRadius: Math.min(Math.max(0, cam.layout.cardClipCornerRadius), Math.min(shape.width, shape.height) / 2) }
        : { rect, radius };
      // makeFrameShadow(extent: outputRect, rect: clip, cornerRadius: radius,
      // shadowRadius: max(0, shadowRadius × canvasScale) × min(1, cardScale), shadowOpacity: max(0, …)) —
      // a stack row scales the card UP; its shadow stays card-sized (§12.12).
      const shadowRadius = Math.max(0, s.shadowRadius * statics.statics.canvasScale) * Math.min(1, cam.layout.cardScale);
      const shadowOpacity = Math.max(0, s.shadowOpacity);
      if (shadowRadius > 0 && shadowOpacity > 0) {
        const spec = {
          rect,
          radius,
          sigma: shadowRadius / 2,
          alpha: shadowOpacity * 0.45,
          offsetY: shadowRadius / 3,
          extent: { x: 0, y: 0, width: scene.target.width, height: scene.target.height },
        };
        plan.shadows.tile = { ...spec, key: JSON.stringify(spec) };
      }
    }
    if (cam.path === "none" || !plan.source) {
      plan.path = "none";
      plan.looks = zero;
      plan.maskIndex = -1;
      return plan;
    }
    const a = statics.assets;
    const bubble: Layer[] = [];
    const asset = (list: Layer[], g: GpuAsset | null, xform: Mat3, fade = 1, alphaOnly = false) => {
      if (g) list.push({ kind: "asset", asset: g, xform, fade, alphaOnly });
    };
    let pitch = 0;
    let yaw = 0;
    let opacity = 1;
    if (cam.path === "plain" && cam.plain) {
      const x = yDown(cam.plain.assetTransform, H);
      plan.rect = rectYDown(cam.plain.rect, H);
      asset(bubble, a.shadow, x);
      asset(bubble, a.ring, x);
      bubble.push({ kind: "camera", clip: { kind: "asset", xform: x }, person: false });
      asset(bubble, a.stroke, x);
      asset(plan.top, a.tag, x);
      pitch = cam.plain.tiltPitch;
      yaw = cam.plain.tiltYaw;
      opacity = cam.plain.opacity;
    } else if (cam.path === "override" && cam.override) {
      const o = cam.override;
      const x = yDown(o.assetTransform, H);
      plan.rect = rectYDown(o.rect, H);
      const chrome = o.chromeVisible ? o.chrome : 0;
      if (o.chromeVisible) asset(bubble, a.shadow, x, chrome);
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
        plan.shadows.card = { ...spec, key: JSON.stringify(spec) };
        bubble.push({ kind: "shadow", slot: "card" });
      }
      if (o.underShadow) {
        // A joined stack row (§12.14): drawn at the seam, UNDER the card.
        const us = o.underShadow;
        const spec = {
          rect: rectYDown(us.rect, H),
          radius: us.cornerRadius,
          sigma: us.shadowRadius / 2,
          alpha: us.shadowOpacity * 0.45,
          offsetY: us.shadowRadius / 3,
          extent: rectYDown(us.extent, H),
        };
        plan.shadows.under = { ...spec, key: JSON.stringify(spec) };
      }
      if (o.chromeVisible) asset(bubble, a.ring, x, chrome);
      bubble.push({
        kind: "camera",
        clip: { kind: "roundedRect", radius: o.maskRadius, maskRect: o.maskShape ? rectYDown(o.maskShape, H) : undefined },
        person: false,
      });
      if (o.chromeVisible) {
        asset(bubble, a.stroke, x, chrome);
        asset(plan.top, a.tag, x, chrome);
      }
      pitch = o.tiltPitch;
      yaw = o.tiltYaw;
      opacity = o.opacity;
    }

    // The weighted stacks (§5): bubble × (1 − c − p), cutout × c, pop-out × p.
    const wb = camLooks ? camLooks.bubbleWeight : bubbleWeight(looks);
    if (wb > 0) plan.stacks.push({ weight: wb, layers: bubble });
    if (looks.cutout > 0) {
      plan.stacks.push({ weight: looks.cutout, layers: [{ kind: "camera", clip: { kind: "none" }, person: true }] });
    }
    const pop = camLooks?.popOut ?? null;
    if (looks.popOut > 0 && pop?.cardRect) {
      // The plan's Y-up geometry, flipped like every other camera rect.
      const card = rectYDown(pop.cardRect, H);
      const layers: Layer[] = [];
      if (camLooks!.shadowSigma > 0 && pop.cardShadowExtent) {
        const spec = {
          rect: card,
          radius: pop.cardCornerRadius,
          sigma: camLooks!.shadowSigma,
          alpha: cardShadowExportAlpha,
          offsetY: 0,
          extent: rectYDown(pop.cardShadowExtent, H),
        };
        plan.shadows.look = { ...spec, key: JSON.stringify(spec) };
        layers.push({ kind: "shadow", slot: "look" });
      }
      if (card.width > 0 && card.height > 0) {
        // §12.3: card fill → border ring, under the person.
        layers.push(cardFill(plan.style, card, pop.cardCornerRadius, scene));
        const inner = cardBorderInner(pop);
        if (inner) {
          const colors = borderColors(plan.style);
          layers.push({
            kind: "card",
            rect: card,
            radius: pop.cardCornerRadius,
            top: colors.top,
            bottom: colors.bottom,
            ring: { rect: rectYDown(inner.rect, H), radius: inner.radius },
          });
        }
      }
      layers.push({
        kind: "camera",
        clip: { kind: "bottomRounded", radius: pop.clipBottomCornerRadius, maskRect: rectYDown(pop.personClipMaskRect!, H) },
        person: true,
      });
      plan.stacks.push({ weight: looks.popOut, layers });
    }

    // Group bounds: every layer's footprint, clipped to the target.
    let b: Rect | null = { ...plan.rect };
    for (const l of [...plan.stacks.flatMap((st) => st.layers), ...plan.top]) {
      if (l.kind === "asset") b = union(b, boundsOf(l.xform, l.asset.baked.crop));
      else if (l.kind === "shadow" && plan.shadows[l.slot]) b = union(b, plan.shadows[l.slot]!.extent);
      else if (l.kind === "card" || l.kind === "cardImage") b = union(b, l.rect);
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

  private ensureScratch(device: GPUDevice, w: number, h: number) {
    if (this.scratch && this.scratch.width === w && this.scratch.height === h) return this.scratch;
    const old = this.scratch;
    if (old) void device.queue.onSubmittedWorkDone().then(() => old.texture.destroy());
    const texture = device.createTexture({ label: "camera-look-fade", size: { width: w, height: h }, format: GROUP_FORMAT, usage: RT });
    this.scratch = { texture, view: texture.createView(), width: w, height: h };
    return this.scratch;
  }

  private ensureShadowCache(device: GPUDevice, slot: ShadowSlot, w: number, h: number) {
    const hit = this.shadowCaches[slot];
    if (hit && hit.width === w && hit.height === h) return hit;
    if (hit) void device.queue.onSubmittedWorkDone().then(() => hit.texture.destroy());
    const texture = device.createTexture({ label: `camera-${slot}-shadow`, size: { width: w, height: h }, format: "r16float", usage: RT });
    const cache = { texture, view: texture.createView(), width: w, height: h, key: "" };
    this.shadowCaches[slot] = cache;
    return cache;
  }

  private uni(i: number, device: GPUDevice): Uniforms {
    while (this.assetU.length <= i) this.assetU.push(new Uniforms(device, 24, `camera-asset-u${this.assetU.length}`));
    return this.assetU[i];
  }

  /** Renders a blurred rounded-rect shadow into its r16float cache (only when its geometry changed). */
  private renderShadow(ctx: PassContext, enc: FrameEncoder, slot: ShadowSlot, cs: CardShadowSpec): void {
    const { device, pipelines } = ctx;
    const { width: W, height: H } = ctx.scene.target;
    const cache = this.ensureShadowCache(device, slot, W, H);
    if (cache.key === cs.key) return;
    const u = (this.shadowU[slot] ??= new Uniforms(device, 12, `camera-${slot}-shadow-u`));
    u.write([
      cs.rect.x, cs.rect.y, cs.rect.width, cs.rect.height,
      cs.radius, cs.sigma, cs.alpha, cs.offsetY,
      cs.extent.x, cs.extent.y, cs.extent.width, cs.extent.height,
    ]);
    const { pipeline, layout } = pipelines.get({
      id: "camera-card-shadow", code: cameraCardShadowWGSL, format: "r16float", blend: "replace", entries: [L.uniform(0)],
    });
    const pass = enc.beginPass({
      label: `camera-${slot}-shadow`,
      colorAttachments: [{ view: cache.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
    });
    const ex0 = Math.max(0, Math.floor(cs.extent.x));
    const ey0 = Math.max(0, Math.floor(cs.extent.y));
    const ex1 = Math.min(W, Math.ceil(cs.extent.x + cs.extent.width));
    const ey1 = Math.min(H, Math.ceil(cs.extent.y + cs.extent.height));
    if (ex1 > ex0 && ey1 > ey0) {
      pass.setScissorRect(ex0, ey0, ex1 - ex0, ey1 - ey0);
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, device.createBindGroup({ layout, entries: [{ binding: 0, resource: { buffer: u.buffer } }] }));
      pass.draw(3);
    }
    pass.end();
    cache.key = cs.key;
  }

  private encodeGroup(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    // The FrameGraph calls cardTransform first; a caller that did not still gets a plan.
    if (!this.plan || this.plan.outputTime !== frame.outputTime) this.plan = this.makePlan(ctx, frame);
    const plan = this.plan;
    if (!plan) return;
    // Shadow caches (re-rendered only when their geometry changes — morphs, a
    // moving bubble). The split's tile shadow is drawn at the seam even when
    // the camera itself does not draw.
    for (const slot of ["card", "look", "tile", "under"] as const) {
      const spec = plan.shadows[slot];
      if (spec) this.renderShadow(ctx, enc, slot, spec);
    }
    if (plan.path === "none" || !plan.source) return;
    const { device, pipelines } = ctx;
    const { width: W, height: H } = ctx.scene.target;
    const group = this.ensureGroup(device, W, H);
    const b = plan.bounds;
    // §12.3 camera fill blur: its own passes, before the group pass opens.
    const blurLayer = plan.stacks.flatMap((st) => st.layers).find((l): l is CameraLayer => l.kind === "camera" && (l.blur ?? 0) > 0);
    const blurView = blurLayer ? this.renderCardBlur(ctx, enc, plan, blurLayer.blur!) : null;

    const assetPipe = pipelines.get({
      id: "camera-asset", code: cameraAssetWGSL, format: GROUP_FORMAT, blend: "premultipliedOver",
      entries: [L.uniform(0), L.texture(1)],
    });
    let slot = 0;
    let camSlot = 0;
    let cardSlot = 0;
    let cardImageSlot = 0;
    let stackSlot = 0;
    const drawAsset = (pass: GPURenderPassEncoder, view: GPUTextureView, inv: Mat3, origin: { x: number; y: number }, crop: Rect, fade: number, alphaOnly: boolean) => {
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
    const full: Rect = { x: 0, y: 0, width: W, height: H };
    const drawLayers = (pass: GPURenderPassEncoder, layers: readonly Layer[]) => {
      for (const l of layers) {
        if (l.kind === "asset") {
          const bk = l.asset.baked;
          drawAsset(pass, l.asset.view, invert(l.xform), bk.origin, bk.crop, l.fade, l.alphaOnly);
        } else if (l.kind === "shadow") {
          const cache = this.shadowCaches[l.slot];
          if (cache && plan.shadows[l.slot]) drawAsset(pass, cache.view, IDENTITY, { x: 0, y: 0 }, full, 1, true);
        } else if (l.kind === "card") {
          this.drawCard(ctx, pass, l, cardSlot++);
        } else if (l.kind === "cardImage") {
          this.drawCardImage(ctx, pass, l, cardImageSlot++);
        } else if (l.kind === "camera") {
          this.drawCamera(ctx, pass, plan, l, camSlot++, l.blur ? blurView : null);
        }
      }
    };

    // The group: the weighted stacks SUMMED (a cross-dissolve, §5), then the
    // tag over them. A settled stack (weight 1, the others 0) draws straight
    // into the cleared group; a cross-fading one renders into the scratch
    // target and is ADDED scaled by its weight (premultiplied RGBA × w).
    let pass: GPURenderPassEncoder | null = null;
    let cleared = false;
    const open = (): GPURenderPassEncoder => {
      if (!pass) {
        pass = enc.beginPass({
          label: "camera-group",
          colorAttachments: [{ view: group.view, loadOp: cleared ? "load" : "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
        });
        cleared = true;
        pass.setScissorRect(b.x, b.y, b.width, b.height);
      }
      return pass;
    };
    const close = () => {
      if (pass) (pass as GPURenderPassEncoder).end();
      pass = null;
    };
    for (const stack of plan.stacks) {
      if (stack.weight >= 1) {
        drawLayers(open(), stack.layers);
        continue;
      }
      close();
      const scratch = this.ensureScratch(device, W, H);
      const sp = enc.beginPass({
        label: "camera-look-stack",
        colorAttachments: [{ view: scratch.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      });
      sp.setScissorRect(b.x, b.y, b.width, b.height);
      drawLayers(sp, stack.layers);
      sp.end();
      const gp = open();
      while (this.stackU.length <= stackSlot) this.stackU.push(new Uniforms(device, 4, `camera-stack-u${this.stackU.length}`));
      const su = this.stackU[stackSlot++]!;
      su.write([stack.weight, 0, 0, 0]);
      const sumPipe = pipelines.get({
        id: "camera-stack", code: cameraStackWGSL, format: GROUP_FORMAT, blend: "add", entries: [L.uniform(0), L.texture(1)],
      });
      gp.setPipeline(sumPipe.pipeline);
      gp.setBindGroup(0, device.createBindGroup({
        layout: sumPipe.layout,
        entries: [
          { binding: 0, resource: { buffer: su.buffer } },
          { binding: 1, resource: scratch.view },
        ],
      }));
      gp.draw(3);
    }
    drawLayers(open(), plan.top);
    close();
  }

  /**
   * The full-height split's tile shadow (§12.11) into the squeezed card layer,
   * UNDER the clipped card (the FrameGraph's "cardSeam" stage): the cached
   * makeFrameShadow alpha as black.
   */
  private encodeSeam(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const plan = this.plan;
    if (!plan || plan.outputTime !== frame.outputTime || !plan.cardClip || !enc.pass) return;
    // The tile shadow, then a joined stack row's shadow (§12.14) — the Mac
    // composites the card over the tile shadow, then that over the row's.
    for (const slot of ["tile", "under"] as const) {
      const cache = this.shadowCaches[slot];
      if (!plan.shadows[slot] || !cache) continue;
      const { device, pipelines, scene } = ctx;
      const { width: W, height: H } = scene.target;
      const u = slot === "tile" ? (this.seamU ??= new Uniforms(device, 24, "camera-seam-u")) : (this.underU ??= new Uniforms(device, 24, "camera-under-u"));
      u.write([...toRows(IDENTITY), 0, 0, 0, 0, 0, 0, W, H, 1, 1, 1, 1]);
      const { pipeline, layout } = pipelines.get({
        id: "camera-asset", code: cameraAssetWGSL, format: enc.format, blend: "premultipliedOver",
        entries: [L.uniform(0), L.texture(1)],
      });
      enc.pass.setPipeline(pipeline);
      enc.pass.setBindGroup(0, device.createBindGroup({
        layout,
        entries: [
          { binding: 0, resource: { buffer: u.buffer } },
          { binding: 1, resource: cache.view },
        ],
      }));
      enc.pass.draw(3);
    }
  }


  /** The pop-out card: gradient / flat colour through its rounded rect, or its border ring (cameraCardWGSL). */
  private drawCard(ctx: PassContext, pass: GPURenderPassEncoder, card: CardLayer, slot: number): void {
    const { device, pipelines, scene } = ctx;
    while (this.cardU.length <= slot) this.cardU.push(new Uniforms(device, 20, `camera-card-u${this.cardU.length}`));
    const u = this.cardU[slot]!;
    // sRGB as stored, alpha forced to 1 (§12.3), matched into the working space.
    const top = srgbToWorking([card.top.r, card.top.g, card.top.b], scene.workingSpace);
    const bottom = srgbToWorking([card.bottom.r, card.bottom.g, card.bottom.b], scene.workingSpace);
    const ring = card.ring;
    u.write([
      card.rect.x, card.rect.y, card.rect.width, card.rect.height,
      card.radius, ring ? 1 : 0, ring?.radius ?? 0, 0,
      top[0], top[1], top[2], 1,
      bottom[0], bottom[1], bottom[2], 1,
      ring?.rect.x ?? 0, ring?.rect.y ?? 0, ring?.rect.width ?? 0, ring?.rect.height ?? 0,
    ]);
    const { pipeline, layout } = pipelines.get({
      id: "camera-card", code: cameraCardWGSL, format: GROUP_FORMAT, blend: "premultipliedOver", entries: [L.uniform(0)],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, device.createBindGroup({ layout, entries: [{ binding: 0, resource: { buffer: u.buffer } }] }));
    pass.draw(3);
  }

  /** The §12.3 image fill: the decoded image aspect-filled into C through the card mask (cameraCardImageWGSL). */
  private drawCardImage(ctx: PassContext, pass: GPURenderPassEncoder, layer: CardImageLayer, slot: number): void {
    const { device, pipelines, scene } = ctx;
    const view = this.cardImageTexture(ctx, layer.ref);
    const bmp = scene.extras.assets.images.get(layer.ref);
    if (!view || !bmp) return;
    // s = max(C.width / iw, C.height / ih), centred on C (CameraCardStyle.imageFillRect).
    const place = imageFillRect({ width: bmp.width, height: bmp.height }, layer.rect);
    while (this.cardImageU.length <= slot) this.cardImageU.push(new Uniforms(device, 12, `camera-card-image-u${this.cardImageU.length}`));
    const u = this.cardImageU[slot]!;
    u.write([
      layer.rect.x, layer.rect.y, layer.rect.width, layer.rect.height,
      layer.radius, 0, 0, 0,
      place.x, place.y, place.width, place.height,
    ]);
    const { pipeline, layout } = pipelines.get({
      id: "camera-card-image", code: cameraCardImageWGSL, format: GROUP_FORMAT, blend: "premultipliedOver",
      entries: [L.uniform(0), L.sampler(1), L.texture(2)],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: u.buffer } },
        { binding: 1, resource: pipelines.linearSampler() },
        { binding: 2, resource: view },
      ],
    }));
    pass.draw(3);
  }

  /** The card image as a texture (sRGB 8-bit, EXIF-oriented by the decode, matched into the working space). */
  private cardImageTexture(ctx: PassContext, ref: string): GPUTextureView | null {
    const bitmap = ctx.scene.extras.assets.images.get(ref);
    if (!bitmap) return null;
    const space = ctx.scene.workingSpace;
    if (this.cardImage?.bitmap === bitmap && this.cardImage.space === space) return this.cardImage.view;
    const old = this.cardImage;
    if (old) void ctx.device.queue.onSubmittedWorkDone().then(() => old.texture.destroy());
    const texture = ctx.device.createTexture({
      label: "camera-card-image",
      size: { width: bitmap.width, height: bitmap.height },
      format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
    });
    ctx.device.queue.copyExternalImageToTexture(
      { source: bitmap },
      { texture, colorSpace: space, premultipliedAlpha: true },
      { width: bitmap.width, height: bitmap.height },
    );
    this.cardImage = { bitmap, space, texture, view: texture.createView() };
    return this.cardImage.view;
  }

  /**
   * The §12.3 camera fill's portrait blur: the drawn camera frame (adjusted,
   * unmirrored) at its own pixels → separable Gaussian σ = blur × 0.03 × H
   * (H = the frame's decoded height), kernel radius ceil(3σ), normalised
   * exp(−x² / 2σ²), clamp-to-edge — horizontal then vertical. Cached until
   * the frame, σ or the adjustments change. Null: nothing to blur.
   */
  private renderCardBlur(ctx: PassContext, enc: FrameEncoder, plan: Plan, blur: number): GPUTextureView | null {
    const { device, pipelines, scene } = ctx;
    const src = plan.source;
    if (!src) return null;
    let poster: GPUTextureView | null = null;
    let cw: number;
    let ch: number;
    let identity: string;
    if (src.kind === "live") {
      cw = src.frame.frame.displayWidth;
      ch = src.frame.frame.displayHeight;
      identity = `live:${src.frame.index}:${src.frame.frame.timestamp}`;
    } else {
      poster = this.posterTexture(ctx);
      const bmp = scene.extras.assets.images.get(CAMERA_POSTER_REF);
      if (!poster || !bmp) return null;
      cw = bmp.width;
      ch = bmp.height;
      identity = `poster:${this.posterVersion}`;
    }
    const sigma = blurSigma({ ...plan.style, backgroundBlur: blur }, ch);
    if (!(sigma > 0) || !(cw > 0 && ch > 0)) return null;
    const adj = adjustmentsFromSettings(scene.extras.project!.settings);
    const key = JSON.stringify([identity, cw, ch, sigma, adj, scene.workingSpace]);
    const cache = this.ensureCardBlur(device, cw, ch);
    // The camera runs slower than the output: most frames reuse the last blur.
    if (cache.key === key) return cache.aView;
    const binding: GPUExternalTexture | GPUTextureView =
      src.kind === "live" ? device.importExternalTexture({ source: src.frame.frame, colorSpace: scene.workingSpace }) : poster!;

    // 1. The adjusted frame at camera px → a.
    const preset = adj.filter !== "None" ? this.presetView(device, adj.filter as PresetName) : null;
    this.prepU ??= new Uniforms(device, 12, "camera-blur-prep-u");
    this.prepU.write([
      cw, ch, 0, 0,
      adj.brightness, adj.contrast, adj.saturation, (adj.hue * Math.PI) / 180,
      preset ? 1 : 0,
      adj.brightness !== 0 || adj.contrast !== 1 || adj.saturation !== 1 ? 1 : 0,
      adj.hue !== 0 ? 1 : 0,
      adjustmentsIdentity(adj) ? 1 : 0,
    ]);
    const live = src.kind === "live";
    const prep = pipelines.get({
      id: live ? "camera-blur-prep-live" : "camera-blur-prep-poster",
      code: live ? cameraPrepLiveWGSL : cameraPrepPosterWGSL,
      format: GROUP_FORMAT,
      blend: "replace",
      entries: [L.uniform(0), L.sampler(1), live ? L.external(3) : L.texture(3), LUT_ENTRY(4)],
    });
    const p0 = enc.beginPass({ label: "camera-blur-prep", colorAttachments: [{ view: cache.aView, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }] });
    p0.setPipeline(prep.pipeline);
    p0.setBindGroup(0, device.createBindGroup({
      layout: prep.layout,
      entries: [
        { binding: 0, resource: { buffer: this.prepU.buffer } },
        { binding: 1, resource: pipelines.linearSampler() },
        { binding: 3, resource: binding },
        { binding: 4, resource: preset ?? this.presetView(device, null) },
      ],
    }));
    p0.draw(3);
    p0.end();

    // 2. Normalised Gaussian weights, w[0] = centre … w[R].
    const radius = Math.ceil(3 * sigma);
    const weights = new Float32Array(radius + 1);
    let sum = 0;
    for (let x = -radius; x <= radius; x++) sum += Math.exp(-(x * x) / (2 * sigma * sigma));
    for (let x = 0; x <= radius; x++) weights[x] = Math.exp(-(x * x) / (2 * sigma * sigma)) / sum;
    const wbuf = this.ensureBlurWeights(device, radius + 1);
    device.queue.writeBuffer(wbuf, 0, weights);

    // 3. Horizontal a → b, vertical b → a.
    const blurPipe = pipelines.get({
      id: "camera-blur", code: cameraBlurWGSL, format: GROUP_FORMAT, blend: "replace", entries: [L.uniform(0), L.texture(1), L.storage(2)],
    });
    const passes: Array<[GPUTextureView, GPUTextureView, number, number]> = [
      [cache.aView, cache.bView, 1, 0],
      [cache.bView, cache.aView, 0, 1],
    ];
    passes.forEach(([from, to, dx, dy], k) => {
      const u = (this.blurU[k] ??= new Uniforms(device, 4, `camera-blur-u${k}`));
      u.write([dx, dy, radius, 0]);
      const bp = enc.beginPass({ label: "camera-blur", colorAttachments: [{ view: to, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }] });
      bp.setPipeline(blurPipe.pipeline);
      bp.setBindGroup(0, device.createBindGroup({
        layout: blurPipe.layout,
        entries: [
          { binding: 0, resource: { buffer: u.buffer } },
          { binding: 1, resource: from },
          { binding: 2, resource: { buffer: wbuf } },
        ],
      }));
      bp.draw(3);
      bp.end();
    });
    cache.key = key;
    return cache.aView;
  }

  private ensureCardBlur(device: GPUDevice, w: number, h: number) {
    const hit = this.cardBlur;
    if (hit && hit.width === w && hit.height === h) return hit;
    if (hit) void device.queue.onSubmittedWorkDone().then(() => (hit.a.destroy(), hit.b.destroy()));
    const make = (label: string) => device.createTexture({ label, size: { width: w, height: h }, format: GROUP_FORMAT, usage: RT });
    const a = make("camera-card-blur-a");
    const b = make("camera-card-blur-b");
    this.cardBlur = { a, b, aView: a.createView(), bView: b.createView(), width: w, height: h, key: "" };
    return this.cardBlur;
  }

  private ensureBlurWeights(device: GPUDevice, floats: number): GPUBuffer {
    const hit = this.cardBlurWeights;
    if (hit && hit.floats >= floats) return hit.buffer;
    if (hit) {
      const old = hit.buffer;
      void device.queue.onSubmittedWorkDone().then(() => old.destroy());
    }
    const size = Math.max(16, Math.ceil((floats * 4) / 16) * 16);
    const buffer = device.createBuffer({ label: "camera-blur-weights", size, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    this.cardBlurWeights = { buffer, floats: size / 4 };
    return buffer;
  }

  private drawCamera(
    ctx: PassContext,
    pass: GPURenderPassEncoder,
    plan: Plan,
    layer: CameraLayer,
    slot: number,
    /** The §12.3 camera fill's blurred frame (adjusted, camera px), when this layer is blurred. */
    blurred: GPUTextureView | null = null,
  ): void {
    const { device, pipelines, scene } = ctx;
    const H = scene.target.height;
    const src = plan.source!;
    let binding: GPUExternalTexture | GPUTextureView;
    let cw: number;
    let ch: number;
    if (src.kind === "live") {
      const vf = src.frame.frame;
      binding = blurred ?? device.importExternalTexture({ source: vf, colorSpace: scene.workingSpace });
      cw = vf.displayWidth;
      ch = vf.displayHeight;
    } else {
      const view = this.posterTexture(ctx);
      const bmp = scene.extras.assets.images.get(CAMERA_POSTER_REF);
      if (!view || !bmp) return;
      binding = blurred ?? view;
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
    // A blurred fill is already adjusted (renderCardBlur): drawn as is.
    const adj = blurred ? identityAdjustments : adjustmentsFromSettings(s);
    const identity = blurred ? true : adjustmentsIdentity(adj);
    const preset = adj.filter !== "None" ? this.presetView(device, adj.filter as PresetName) : null;
    const clip = layer.clip;
    const maskAsset = this.statics?.assets.mask ?? null;
    const mInv = clip.kind === "asset" ? invert(clip.xform) : IDENTITY;
    const mb = clip.kind === "asset" ? maskAsset?.baked : undefined;
    // bottomRounded / card: the generator rect (personClipMaskRect / the card, Y-down) rides the mask-crop slot.
    // roundedRect: a joined stack row's shape (§12.14) when present.
    const mCrop =
      clip.kind === "bottomRounded" || clip.kind === "roundedRect" ? clip.maskRect : clip.kind === "card" ? clip.rect : mb?.crop;
    // Clip kind (cameraShaders.ts CamU.mode): 0 baked shape, 1 generator, 2 none, 3 bottom-rounded generator, 4 card mask.
    const kind =
      clip.kind === "asset" ? (maskAsset ? 0 : 1) : clip.kind === "roundedRect" ? 1 : clip.kind === "none" ? 2 : clip.kind === "bottomRounded" ? 3 : 4;
    const radius = clip.kind === "roundedRect" || clip.kind === "bottomRounded" || clip.kind === "card" ? clip.radius : 0;
    while (this.camU.length <= slot) this.camU.push(new Uniforms(device, 56, `camera-u${this.camU.length}`));
    const u = this.camU[slot]!;
    u.write([
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
      mCrop?.x ?? 0, mCrop?.y ?? 0, mCrop?.width ?? 0, mCrop?.height ?? 0,
      kind,
      radius,
      Math.max(1e-6, Math.abs(mInv[0])),
      Math.max(1e-6, Math.abs(mInv[4])),
      layer.person ? 1 : 0,
      // B crops: one for the cutout and the card fill (`placed` crops once), two otherwise.
      clip.kind === "none" || clip.kind === "card" ? 1 : 2,
      0,
      0,
    ]);
    // §12.4: the person's edge (softness / inset) is processed on upload.
    const edge = { softness: plan.style.edgeSoftness, inset: plan.style.edgeInset };
    const personView = layer.person && this.maskFeed && plan.maskIndex >= 0 ? this.maskFeed.view(device, plan.maskIndex, edge) : this.dummyR8(device);
    const live = src.kind === "live" && !blurred;
    const { pipeline, layout } = pipelines.get({
      id: live ? "camera-live" : "camera-poster",
      code: live ? cameraLiveWGSL : cameraPosterWGSL,
      format: GROUP_FORMAT,
      blend: "premultipliedOver",
      entries: [L.uniform(0), L.sampler(1), L.texture(2), live ? L.external(3) : L.texture(3), LUT_ENTRY(4), L.texture(5)],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: u.buffer } },
        { binding: 1, resource: pipelines.linearSampler() },
        { binding: 2, resource: maskAsset?.view ?? this.dummyRGBA(device) },
        { binding: 3, resource: binding },
        { binding: 4, resource: preset ?? this.presetView(device, null) },
        { binding: 5, resource: personView },
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

  /** Bound to the person-mask slot when no look is drawn (never sampled then). */
  private dummyMask: GPUTextureView | null = null;
  private dummyR8(device: GPUDevice): GPUTextureView {
    if (!this.dummyMask) {
      const t = device.createTexture({ label: "camera-dummy-mask", size: { width: 1, height: 1 }, format: "r8unorm", usage: GPUTextureUsage.TEXTURE_BINDING });
      this.dummyMask = t.createView();
    }
    return this.dummyMask;
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
    for (const u of this.camU) u.destroy();
    this.camU = [];
    for (const u of this.cardU) u.destroy();
    this.cardU = [];
    for (const u of this.stackU) u.destroy();
    this.stackU = [];
    for (const u of this.cardImageU) u.destroy();
    this.cardImageU = [];
    this.prepU?.destroy();
    this.prepU = null;
    for (const u of this.blurU) u?.destroy();
    this.blurU = [null, null];
    this.cardBlur?.a.destroy();
    this.cardBlur?.b.destroy();
    this.cardBlur = null;
    this.cardBlurWeights?.buffer.destroy();
    this.cardBlurWeights = null;
    this.cardImage?.texture.destroy();
    this.cardImage = null;
    this.shadowU.card?.destroy();
    this.shadowU.look?.destroy();
    this.shadowU.tile?.destroy();
    this.shadowU.under?.destroy();
    this.shadowU = { card: null, look: null, tile: null, under: null };
    this.seamU?.destroy();
    this.seamU = null;
    this.underU?.destroy();
    this.underU = null;
    this.composeU?.destroy();
    this.group?.texture.destroy();
    this.scratch?.texture.destroy();
    this.scratch = null;
    this.shadowCaches.card?.texture.destroy();
    this.shadowCaches.look?.texture.destroy();
    this.shadowCaches.tile?.texture.destroy();
    this.shadowCaches.under?.texture.destroy();
    this.shadowCaches = { card: null, look: null, tile: null, under: null };
    this.maskFeed?.dispose();
    this.maskFeed = null;
    this.poster?.texture.destroy();
    for (const p of this.presets.values()) p.texture.destroy();
    this.presets.clear();
    if (this.statics) for (const a of Object.values(this.statics.assets)) a?.texture.destroy();
    this.statics = null;
    this.group = null;
    this.poster = null;
  }
}

/** The exporter's FrameLayout.contentRect (the vertical stack's area, §12.12) in its Y-up space. */
function contentRectYUp(scene: Scene): Rect {
  const c = scene.geometry.contentRect;
  return { x: c.x, y: scene.target.height - c.y - c.height, width: c.width, height: c.height };
}

/**
 * The §12.3 card fill layer for the resolved style: the gradient (default,
 * colours overridable), a flat colour, the decoded image (missing /
 * unreadable → the gradient), or the camera's own unmasked frame placed like
 * the person and cut by the card mask with the gradient's coverage.
 */
function cardFill(style: CameraCardStyle, card: Rect, radius: number, scene: Scene): Layer {
  switch (style.fill) {
    case "color":
      return { kind: "card", rect: card, radius, top: style.color, bottom: style.color };
    case "image":
      if (style.imagePath && scene.extras.assets.images.has(style.imagePath)) {
        return { kind: "cardImage", rect: card, radius, ref: style.imagePath };
      }
      break;
    case "camera":
      return { kind: "camera", clip: { kind: "card", radius, rect: card }, person: false, blur: style.backgroundBlur };
    case "gradient":
      break;
  }
  return { kind: "card", rect: card, radius, top: style.gradientTop, bottom: style.gradientBottom };
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
