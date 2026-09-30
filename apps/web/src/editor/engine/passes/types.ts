/**
 * Render-pass contracts for the frame graph.
 *
 * Mirrors the Mac exporter's frame structure (VideoExporter.export frame
 * loop) so features slot in without rewrites:
 *
 *   prepare   per-frame GPU work into intermediates (Lanczos video fit; later
 *             region blur, focus masks …)
 *   backdrop  the canvas background (+ baked card shadow when the camera is
 *             identity — `cachedBaseFrame`)
 *   card      CARD-SPACE layers, drawn through `FrameEncoder.cardToTarget`:
 *             video card now; cursor, click ripples, highlights, subtitles,
 *             annotations, curtain later — everything the Mac composites
 *             BEFORE the tilt/zoom warp.
 *   overlay   CANVAS-SPACE layers after the warp: camera bubble, watermark.
 *
 * Camera transform (zoom / tilt / offset / intro slide) is a homography on
 * `FrameState.camera`. When it is identity the card passes draw straight
 * onto the canvas over the baked base (Mac: the cheap path). Otherwise they
 * draw into a transparent card layer that is resampled through the camera
 * over the untouched background (Mac: `cachedCardStatics` + warp), so the
 * shadow, video and every card overlay move as one plane.
 */
import type { CameraKey } from "../../core/math/exportCameraPath";
import type { Project } from "../../core/model";
import type { WorkingSpace } from "../color";
import type { RenderMedia, RenderSettings } from "../contract";
import type { GpuContext } from "../gpu/device";
import type { PipelineCache, PooledTexture, TexturePool } from "../gpu/resources";
import type { CardGeometry, Size } from "../layout";
import type { Mat3 } from "../mat3";
import type { CameraPath, MotionBlurFrame } from "../camera";
import type { SceneAssets } from "../media/assets";
import type { TimeMap } from "../time";

/**
 * Everything a feature pass needs about the PROJECT, shared verbatim by the
 * preview engine and the exporter (preview == export by construction):
 * the raw document, the lossless core model (locked to Swift), the loaded
 * sidecar assets, the media URL map, the output clock and the time map.
 */
export interface SceneExtras {
  /** project.json as loaded/edited (raw keys). */
  doc: Record<string, unknown>;
  /** core/model parse of `doc` — Swift `init(from:)` semantics; null if it failed. */
  project: Project | null;
  media: RenderMedia;
  assets: SceneAssets;
  /** Export frame rate — the camera path and frame clock sample at i/fps. */
  fps: number;
  timeMap: TimeMap;
  /** The exporter's camera path (one key per export frame at `fps`); null
   *  when the core model could not parse the project. */
  cameraPath: CameraPath | null;
  /**
   * Points→pixels scale the backdrop bitmap is rendered at
   * (`BackgroundLook.cgImage(…, scale:)`): the Mac preview uses the backing
   * scale, the exporter 1. Undefined → `geometry.canvasScale` (preview).
   */
  pixelScale?: number;
}

/** Static render state — a change re-runs `sceneChanged` on every pass. */
export interface Scene {
  /** Monotonic; bumped whenever anything below changes. */
  version: number;
  target: Size;
  targetFormat: GPUTextureFormat;
  workingSpace: WorkingSpace;
  settings: RenderSettings;
  /** Natural size of the recording (display size of the video track). */
  sourceSize: Size;
  geometry: CardGeometry;
  extras: SceneExtras;
}

/**
 * Per-frame decisions — the web twin of the exporter's per-frame locals.
 * `editor/core/frame.frameStateAt(project, assets, outputTime)` will produce
 * the non-media half of this at merge time.
 */
export interface FrameState {
  outputTime: number;
  sourceTime: number;
  /** Decoded source frame shown at this time; null → background only (Mac: no sample yet / clip hidden). */
  video: { frame: VideoFrame; index: number } | null;
  /** Card → canvas homography (Y-down px). Identity when no camera move is active. */
  camera: Mat3;
  /**
   * Canvas → crop space of the exporter's post-zoom `cropped(to: outputRect)`
   * (applied before offset / intro); null or absent = no crop.
   */
  cameraClip?: Mat3 | null;
  /** Canvas → background sample point (zoom parallax); null or absent = background at rest. */
  parallax?: Mat3 | null;
  /** Card-layer motion blur (the CIMotionBlur twin); null or absent = none. */
  motionBlur?: MotionBlurFrame | null;
  /**
   * The exporter's per-frame camera sample (`cameraPath[frameIndex]`), when the
   * camera path is known. The webcam bubble reads the RAW smoothed `zoom` from
   * it (ReactiveCameraLayout shrinks/slides the bubble as the screen zooms);
   * absent = zoom 1.
   */
  cameraKey?: CameraKey;
  /**
   * Screen tilt the camera stage applied this frame (`cam.tiltPitch/tiltYaw`).
   * Optional: the device side slab follows it (TiltMath.deviceSideOffset,
   * visible when max(|pitch|, |yaw|) > 0.05°). Absent → no slab.
   */
  tilt?: FrameTilt;
  /**
   * Stitched take: a device source segment is framed this frame (core
   * `deviceSegmentFrame(…).active`) — the video clips to the segment's screen
   * squircle and the segment bezel / side slab / island replace the card
   * shadow. Resolved by the FrameGraph from `sourceTime`; absent = false.
   */
  deviceSegment?: boolean;
  /**
   * Opacity of the finished card layer (the keynote dip's `fadeImage`),
   * applied where the layer is resampled through `camera`. Absent = 1.
   * Resolved by the FrameGraph together with the dip's scale in `camera`.
   */
  cardOpacity?: number;
}

/** Baked scene-static textures (StaticLayers). */
export interface StaticTextures {
  /** Background in the working space, premultiplied rgba8unorm. */
  background: PooledTexture;
  /** Background with the card shadow composited (the Mac's `cachedBaseFrame`). */
  base: PooledTexture;
  /** Blurred shadow alpha (r16float), un-offset; null when the shadow guard fails. */
  shadow: PooledTexture | null;
  /** Squircle coverage mask for the outer frame clip (r8unorm), if any. */
  outerMask: { texture: GPUTexture; view: GPUTextureView; originX: number; originY: number; width: number; height: number } | null;
  /**
   * Framed device take: the bezel / side-slab / island sprites (card space).
   * The bezel is also baked into `base`; the card-statics pass draws side +
   * bezel into the card layer, the island pass draws above the video.
   */
  device?: import("./device/deviceRaster").DeviceSprites | null;
  /**
   * Stitched take with device source segments (`segmentDeviceAssets`): the
   * framing shared by every device segment, baked once per scene.
   */
  segment?: SegmentStatics | null;
}

/** `SegmentDeviceAssets` as GPU layers (VideoExporter segmentDeviceAssets). */
export interface SegmentStatics {
  /** Core framing (exporter rules, Y-down rects) — the per-frame resolver reads it. */
  framing: import("../../core/math/deviceSegmentDip").SegmentFraming;
  /**
   * The video clip during a device segment: the screen squircle (`screenMask`)
   * × the outer frame clip it follows in the exporter — one raster, so the card
   * shaders take it through their squircle slot unchanged.
   */
  mask: NonNullable<StaticTextures["outerMask"]>;
  /** The bezel's own blurred shadow alpha (r16float, un-offset); null when the shadow guard fails. */
  shadow: PooledTexture | null;
  /** Bezel / side slab / island for the screen rect. */
  sprites: import("./device/deviceRaster").DeviceSprites;
}

/** Card tilt the camera stage resolved for this frame (degrees). */
export interface FrameTilt {
  pitch: number;
  yaw: number;
}

/** Per-frame intermediates shared between passes. */
export interface FrameResources {
  external: GPUExternalTexture | null;
  /** Lanczos-fitted video (rgba8unorm), when the fit pass ran this frame. */
  fitted: PooledTexture | null;
  /**
   * The exporter's window-masked video LAYER with this frame's blur /
   * pixelate / Depth Focus regions applied (RegionVideoPass), in card pixels
   * over the integer rect `rect`; null → VideoCardPass samples the video
   * directly. When set, the card pass applies only the outer frame clip.
   */
  videoLayer?: { view: GPUTextureView; rect: { x: number; y: number; width: number; height: number } } | null;
}

export interface PassContext {
  gpu: GpuContext;
  device: GPUDevice;
  pipelines: PipelineCache;
  pool: TexturePool;
  scene: Scene;
  statics: StaticTextures;
  /** 1×1 transparent r8unorm, bound where an optional texture is absent. */
  dummy: GPUTextureView;
  /** Ask for another frame (e.g. an animation outside playback). No-op in export. */
  requestFrame: () => void;
}

export interface FrameEncoder {
  commands: GPUCommandEncoder;
  /**
   * Begin a render pass for this frame. Use instead of
   * `commands.beginRenderPass` so the frame's GPU timer brackets it.
   */
  beginPass(desc: GPURenderPassDescriptor, last?: boolean): GPURenderPassEncoder;
  /** The render pass for the current stage (null during `prepare`). */
  pass: GPURenderPassEncoder | null;
  /** Format of the attachment `pass` renders into. */
  format: GPUTextureFormat;
  /** Card → target transform for card-stage passes (identity when drawing into the card layer). */
  cardToTarget: Mat3;
  /**
   * True for the whole frame when it takes the card-layer path (camera
   * active): card passes draw into the transparent layer, the backdrop is the
   * bare background and the shadow rides the layer.
   */
  layerMode: boolean;
  resources: FrameResources;
}

/**
 * `cardTop`: card-space layers composited AFTER the card-local pre-transform
 * (`RenderPass.cardTransform`, the camera-layout squeeze) and BEFORE the
 * camera warp, drawn with an identity transform (Mac: the camera-layout tile,
 * "composited BEFORE the card transform stage so tilt/zoom move it").
 */
export type PassStage = "prepare" | "backdrop" | "card" | "cardTop" | "overlay";

export interface RenderPass {
  readonly name: string;
  readonly stage: PassStage;
  /** Scene-dependent (re)build: uniforms, pipelines, cached bind groups. */
  sceneChanged?(ctx: PassContext): void;
  /**
   * Card-local transform (Y-down px) applied to the whole card layer — every
   * "card" pass — before "cardTop" and the camera warp (Mac:
   * `CameraLayoutMath.cardTransform`, the side-by-side squeeze of the card
   * over transparency). Called once per frame, after `sceneChanged`, before
   * any stage encodes. null / identity = none; non-identity forces the
   * card-layer path.
   */
  cardTransform?(ctx: PassContext, frame: FrameState): Mat3 | null;
  /**
   * Export only: resolve async per-frame inputs (e.g. wait for the exact
   * frame of a second decode stream) before `render`. The preview never
   * calls it (it re-renders when late inputs land).
   */
  prefetch?(scene: Scene, frame: FrameState): Promise<void>;
  /** Drop per-frame caches (bench: force the full per-frame cost). */
  invalidate?(): void;
  /** Encode this frame's commands. Must not allocate pipelines. */
  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void;
  destroy?(): void;
}
