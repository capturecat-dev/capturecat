/**
 * The cursor layer — `renderCursorCI` (+ `manualDropShadow`) and
 * `renderClickRipple` of VideoExporter, as frame-graph passes:
 *
 *   CursorShadowPass  (prepare)  silhouette → H blur → V blur, into small
 *                                 r16float intermediates over the sprite's
 *                                 region (card pixels)
 *   CursorSpritePass  (card)     sprite source-over its offset shadow,
 *                                 source-over the card
 *   ClickRipplePass   (card)     the ripple overlay, after the cursor
 *
 * Card stage → they ride the camera (zoom/tilt) warp with the video card, in
 * the exporter's order: video card → cursor → ripples → (highlights,
 * subtitles, keystroke pill, annotations, curtain — other passes).
 *
 * Every number (position, pose, shadow parameters, ripple geometry) comes from
 * the core ports (`cursorFrameDraw` → core/math/exportCursor); this file only
 * rasterizes them, reproducing CoreImage's sampling as probed on macOS 26.2:
 *   - the sprite is sampled bilinearly (clear outside its extent) through the
 *     placement ∘ physics affine — after CI's per-axis 2× box pre-downsample
 *     whenever an axis scale is < 0.4375 (passMath.ciDownsampleLevels; hit by
 *     zoom-heavy projects, whose raster carries maxZoom × 1.25 slack);
 *   - shadow: this Mac has no `CIDropShadow` filter, so the exporter takes its
 *     `manualDropShadow` twin — silhouette alpha × 0.3, CIGaussianBlur
 *     σ = 2·canvasScale·½ (CI's pixel-integrated kernel), offset
 *     1·canvasScale px down — and the web follows it.
 */
import { L, Uniforms } from "../../gpu/resources";
import type { FrameEncoder, FrameState, PassContext, RenderPass, Scene } from "../types";
import { spriteRaster, type SpriteRaster } from "./cursorArt";
import { cursorFrameDraw, type CursorFrameDraw } from "./cursorFrame";
import { cursorSceneData, type CursorSceneData } from "./cursorScene";
import { ciDownsampleLevels, ciGaussianWeights, inverseRows, quadBlock, spriteLevel } from "./passMath";
import { genericRGBToSRGB } from "./rippleColor";
import { cursorBlurWGSL, cursorCompositeWGSL, cursorSilhouetteWGSL, RIPPLE_MAX_OPS, rippleWGSL } from "./shaders";

// ── helpers ─────────────────────────────────────────────────────────────────

/** Grow-only r16float scratch texture. */
class Scratch {
  texture: GPUTexture | null = null;
  view: GPUTextureView | null = null;
  width = 0;
  height = 0;
  ensure(device: GPUDevice, w: number, h: number, label: string): void {
    if (this.texture && this.width >= w && this.height >= h) return;
    this.texture?.destroy();
    this.width = Math.max(64, Math.ceil(w / 64) * 64, this.width);
    this.height = Math.max(64, Math.ceil(h / 64) * 64, this.height);
    this.texture = device.createTexture({
      label,
      size: { width: this.width, height: this.height },
      format: "r16float",
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
    });
    this.view = this.texture.createView();
  }
  destroy(): void {
    this.texture?.destroy();
    this.texture = null;
  }
}

interface SpriteTexture {
  texture: GPUTexture;
  view: GPUTextureView;
  width: number;
  height: number;
  /** Base texel → this texture's texel: (u·sx, v·sy + oy). */
  sx: number;
  sy: number;
  oy: number;
}

interface ShadowFrame {
  /** Region R (card px, integer origin) the blurred silhouette covers. */
  rx: number;
  ry: number;
  rw: number;
  rh: number;
  offsetX: number;
  offsetY: number;
}

// ── shared layer state ──────────────────────────────────────────────────────

/**
 * State shared by the three passes: the scene's cursor data + sprite texture
 * and the current frame's draw decisions (computed once per FrameState).
 */
export class CursorLayer {
  readonly shadowPass: CursorShadowPass;
  readonly spritePass: CursorSpritePass;
  readonly ripplePass: ClickRipplePass;

  data: CursorSceneData | null = null;
  sprite: { texture: GPUTexture; view: GPUTextureView; width: number; height: number; key: string; origin: SpriteRaster["origin"]; rgba: Uint8Array } | null = null;
  /** CI pre-downsampled sprite levels by "lx,ly" (see passMath.ciDownsampleLevels). */
  private levels = new Map<string, SpriteTexture>();
  shadow: ShadowFrame | null = null;
  readonly blurA = new Scratch();
  readonly blurB = new Scratch();
  private frame: FrameState | null = null;
  private scene: Scene | null = null;
  private draw: CursorFrameDraw = { sprite: null, ripple: null };

  constructor() {
    this.shadowPass = new CursorShadowPass(this);
    this.spritePass = new CursorSpritePass(this);
    this.ripplePass = new ClickRipplePass(this);
  }

  /** Scene (re)build: cursor data + the sprite raster on the export's pixel grid. */
  sceneChanged(ctx: PassContext): void {
    if (this.scene === ctx.scene) return;
    this.scene = ctx.scene;
    this.frame = null;
    const data = cursorSceneData(ctx.scene);
    this.data = data;
    const px = data?.asset.rasterPixelSize;
    if (!data || !px || !data.settings.showCursor || data.events.length === 0) return;
    const key = `${data.settings.cursorStyle}|${px.width}x${px.height}`;
    if (this.sprite?.key === key) return;
    const raster = spriteRaster(data.settings.cursorStyle, px, ctx.scene.extras.assets.cursorArt ?? null);
    if (!raster) return;
    this.sprite?.texture.destroy();
    for (const l of this.levels.values()) l.texture.destroy();
    this.levels.clear();
    const texture = ctx.device.createTexture({
      label: `cursor-sprite ${key}`,
      size: { width: raster.width, height: raster.height },
      format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
    });
    ctx.device.queue.writeTexture(
      { texture },
      raster.rgba as Uint8Array<ArrayBuffer>,
      { bytesPerRow: raster.width * 4, rowsPerImage: raster.height },
      { width: raster.width, height: raster.height },
    );
    this.sprite = { texture, view: texture.createView(), width: raster.width, height: raster.height, key, origin: raster.origin, rgba: raster.rgba };
  }

  /**
   * The texture CoreImage effectively samples for a placement transform:
   * the raster itself, or its CI box-halved level when the transform
   * minifies an axis below 0.4375 (passMath.ciDownsampleLevels).
   */
  spriteFor(ctx: PassContext, t: import("../../../core/math/geometry").AffineTransform): SpriteTexture | null {
    const s = this.sprite;
    if (!s) return null;
    const { lx, ly } = ciDownsampleLevels(t);
    if (lx === 0 && ly === 0) return { view: s.view, texture: s.texture, width: s.width, height: s.height, sx: 1, sy: 1, oy: 0 };
    const key = `${lx},${ly}`;
    let level = this.levels.get(key);
    if (!level) {
      const l = spriteLevel(s.rgba, s.width, s.height, lx, ly);
      const texture = ctx.device.createTexture({
        label: `cursor-sprite-level ${key}`,
        size: { width: l.width, height: l.height },
        format: "rgba32float",
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
      });
      const norm = new Float32Array(l.data.length);
      for (let i = 0; i < norm.length; i++) norm[i] = l.data[i] / 255;
      ctx.device.queue.writeTexture({ texture }, norm, { bytesPerRow: l.width * 16, rowsPerImage: l.height }, { width: l.width, height: l.height });
      level = { texture, view: texture.createView(), width: l.width, height: l.height, sx: l.sx, sy: l.sy, oy: l.oy };
      this.levels.set(key, level);
    }
    return level;
  }

  /** This frame's cursor + ripple decisions (memoized per FrameState object). */
  frameDraw(ctx: PassContext, frame: FrameState): CursorFrameDraw {
    if (this.frame === frame) return this.draw;
    this.frame = frame;
    this.shadow = null;
    this.draw = this.data ? cursorFrameDraw(this.data, frame.sourceTime, frame.video !== null) : { sprite: null, ripple: null };
    void ctx;
    return this.draw;
  }

  destroy(): void {
    this.sprite?.texture.destroy();
    this.sprite = null;
    for (const l of this.levels.values()) l.texture.destroy();
    this.levels.clear();
    this.blurA.destroy();
    this.blurB.destroy();
  }
}

// ── prepare: silhouette + blur ──────────────────────────────────────────────

export class CursorShadowPass implements RenderPass {
  readonly name = "cursor-shadow";
  readonly stage = "prepare" as const;
  private silU: Uniforms | null = null;
  private hU: Uniforms | null = null;
  private vU: Uniforms | null = null;
  constructor(private readonly layer: CursorLayer) {}

  sceneChanged(ctx: PassContext): void {
    this.layer.sceneChanged(ctx);
  }

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const layer = this.layer;
    const draw = layer.frameDraw(ctx, frame);
    const c = draw.sprite;
    const sprite = c ? layer.spriteFor(ctx, c.spriteTransformYDown) : null;
    if (!c || !sprite || !frame.video) return;
    const H = ctx.scene.target.height;
    const sigma = c.shadow.sigma;
    const weights = ciGaussianWeights(sigma);
    const r = weights.length - 1;
    // Sprite bounds (CI Y-up) → card px (Y-down), padded by the kernel.
    const b = c.spriteBounds;
    const margin = r + 2;
    const rx = Math.floor(b.x) - margin;
    const ry = Math.floor(H - (b.y + b.height)) - margin;
    const rw = Math.ceil(b.x + b.width) + margin - rx;
    const rh = Math.ceil(H - b.y) + margin - ry;
    if (!(rw > 0 && rh > 0) || rw > 4096 || rh > 4096) return;
    layer.blurA.ensure(ctx.device, rw, rh, "cursor-shadow-a");
    layer.blurB.ensure(ctx.device, rw, rh, "cursor-shadow-b");

    // A: silhouette = sprite alpha × opacity on R's pixel grid.
    this.silU ??= new Uniforms(ctx.device, 20, "cursor-sil-u");
    this.silU.write([
      ...inverseRows(c.spriteTransformYDown), rx, ry, c.shadow.opacity, 0, sprite.width, sprite.height, 0, 0,
      sprite.sx, sprite.sy, sprite.oy, 0,
    ]);
    const sil = ctx.pipelines.get({
      id: "cursor-silhouette", code: cursorSilhouetteWGSL, format: "r16float", blend: "replace",
      entries: [L.uniform(0), L.unfilterable(1)],
    });
    let pass = enc.beginPass({
      label: "cursor-silhouette",
      colorAttachments: [{ view: layer.blurA.view!, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
    });
    pass.setPipeline(sil.pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({
      layout: sil.layout,
      entries: [{ binding: 0, resource: { buffer: this.silU.buffer } }, { binding: 1, resource: sprite.view }],
    }));
    pass.draw(3);
    pass.end();

    // B/C: separable CIGaussianBlur (A → B horizontal, B → A vertical).
    const blur = ctx.pipelines.get({
      id: "cursor-blur", code: cursorBlurWGSL, format: "r16float", blend: "replace",
      entries: [L.uniform(0), L.unfilterable(1)],
    });
    const w = new Array(64).fill(0);
    weights.forEach((v, i) => (w[i] = v));
    this.hU ??= new Uniforms(ctx.device, 72, "cursor-blur-h");
    this.vU ??= new Uniforms(ctx.device, 72, "cursor-blur-v");
    this.hU.write([1, 0, r, 0, rw, rh, 0, 0, ...w]);
    this.vU.write([0, 1, r, 0, rw, rh, 0, 0, ...w]);
    for (const [u, src, dst] of [
      [this.hU, layer.blurA, layer.blurB],
      [this.vU, layer.blurB, layer.blurA],
    ] as const) {
      pass = enc.beginPass({
        label: "cursor-blur",
        colorAttachments: [{ view: dst.view!, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      });
      pass.setPipeline(blur.pipeline);
      pass.setBindGroup(0, ctx.device.createBindGroup({
        layout: blur.layout,
        entries: [{ binding: 0, resource: { buffer: u.buffer } }, { binding: 1, resource: src.view! }],
      }));
      pass.draw(3);
      pass.end();
    }
    layer.shadow = { rx, ry, rw, rh, offsetX: c.shadow.offsetX, offsetY: c.shadow.offsetYDown };
  }

  destroy(): void {
    this.silU?.destroy();
    this.hU?.destroy();
    this.vU?.destroy();
  }
}

// ── card: sprite over shadow ────────────────────────────────────────────────

export class CursorSpritePass implements RenderPass {
  readonly name = "cursor";
  readonly stage = "card" as const;
  private u: Uniforms | null = null;
  constructor(private readonly layer: CursorLayer) {}

  sceneChanged(ctx: PassContext): void {
    this.layer.sceneChanged(ctx);
  }

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const layer = this.layer;
    const draw = layer.frameDraw(ctx, frame);
    const c = draw.sprite;
    const sprite = c ? layer.spriteFor(ctx, c.spriteTransformYDown) : null;
    if (!c || !sprite) return;
    const H = ctx.scene.target.height;
    const sh = layer.shadow;
    const b = c.spriteBounds;
    let x0 = Math.floor(b.x) - 1;
    let y0 = Math.floor(H - (b.y + b.height)) - 1;
    let x1 = Math.ceil(b.x + b.width) + 1;
    let y1 = Math.ceil(H - b.y) + 1;
    if (sh) {
      x0 = Math.min(x0, Math.floor(sh.rx + Math.min(0, sh.offsetX)));
      y0 = Math.min(y0, Math.floor(sh.ry + Math.min(0, sh.offsetY)));
      x1 = Math.max(x1, Math.ceil(sh.rx + sh.rw + Math.max(0, sh.offsetX)));
      y1 = Math.max(y1, Math.ceil(sh.ry + sh.rh + Math.max(0, sh.offsetY)));
    }
    this.u ??= new Uniforms(ctx.device, 56, "cursor-comp-u");
    this.u.write([
      ...quadBlock(enc.cardToTarget, ctx.scene.target, { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }),
      ...inverseRows(c.spriteTransformYDown),
      sprite.width, sprite.height, 0, 0,
      sh?.rx ?? 0, sh?.ry ?? 0, sh?.offsetX ?? 0, sh?.offsetY ?? 0,
      sh?.rw ?? 1, sh?.rh ?? 1, sh ? 1 : 0, 0,
      sprite.sx, sprite.sy, sprite.oy, 0,
    ]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "cursor-composite", code: cursorCompositeWGSL, vertexEntry: "vs_quad", format: enc.format,
      blend: "premultipliedOver", entries: [L.uniform(0, true), L.unfilterable(1), L.unfilterable(2)],
    });
    const pass = enc.pass!;
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: this.u.buffer } },
        { binding: 1, resource: sprite.view },
        { binding: 2, resource: layer.blurA.view ?? this.fallback(ctx) },
      ],
    }));
    pass.draw(6);
  }

  private dummy: GPUTexture | null = null;
  private fallback(ctx: PassContext): GPUTextureView {
    this.dummy ??= ctx.device.createTexture({
      size: { width: 1, height: 1 }, format: "r16float", usage: GPUTextureUsage.TEXTURE_BINDING,
    });
    return this.dummy.createView();
  }

  destroy(): void {
    this.u?.destroy();
    this.dummy?.destroy();
    this.layer.destroy();
  }
}

// ── card: click ripples ─────────────────────────────────────────────────────

export class ClickRipplePass implements RenderPass {
  readonly name = "click-ripple";
  readonly stage = "card" as const;
  private u: Uniforms | null = null;
  constructor(private readonly layer: CursorLayer) {}

  sceneChanged(ctx: PassContext): void {
    this.layer.sceneChanged(ctx);
  }

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const draw = this.layer.frameDraw(ctx, frame);
    const data = this.layer.data;
    const ripple = draw.ripple;
    if (!ripple || !data) return;
    const H = ctx.scene.target.height;
    const ops = ripple.ops.slice(0, RIPPLE_MAX_OPS);
    const packed = new Float64Array(RIPPLE_MAX_OPS * 8);
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    ops.forEach((op, i) => {
      // CG standardizes the ellipse rect; every op here is a circle.
      const w = Math.abs(op.rect.width);
      const h = Math.abs(op.rect.height);
      const cx = op.rect.x + op.rect.width / 2;
      const cyUp = op.rect.y + op.rect.height / 2;
      const cy = H - cyUp;
      const radius = Math.min(w, h) / 2;
      const lw = op.lineWidth ?? 0;
      packed.set([cx, cy, radius, lw, op.alpha, 0, 0, 0], i * 8);
      const ext = radius + lw / 2 + 2;
      x0 = Math.min(x0, cx - ext);
      y0 = Math.min(y0, cy - ext);
      x1 = Math.max(x1, cx + ext);
      y1 = Math.max(y1, cy + ext);
    });
    if (!(x1 > x0 && y1 > y0)) return;
    const rc = data.settings.clickRippleColor;
    const [r, g, b] = genericRGBToSRGB(rc.red, rc.green, rc.blue);
    this.u ??= new Uniforms(ctx.device, 32 + 8 + RIPPLE_MAX_OPS * 8, "ripple-u");
    this.u.write([
      ...quadBlock(enc.cardToTarget, ctx.scene.target, {
        x: Math.floor(x0), y: Math.floor(y0), w: Math.ceil(x1) - Math.floor(x0), h: Math.ceil(y1) - Math.floor(y0),
      }),
      r, g, b, ops.length,
      ctx.scene.workingSpace === "display-p3" ? 1 : 0, 0, 0, 0,
      ...packed,
    ]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "click-ripple", code: rippleWGSL, vertexEntry: "vs_quad", format: enc.format,
      blend: "premultipliedOver", entries: [L.uniform(0, true)],
    });
    const pass = enc.pass!;
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({ layout, entries: [{ binding: 0, resource: { buffer: this.u.buffer } }] }));
    pass.draw(6);
  }

  destroy(): void {
    this.u?.destroy();
  }
}
