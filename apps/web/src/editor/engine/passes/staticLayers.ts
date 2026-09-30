/**
 * Scene-static layers, baked once per scene (the Mac's `bakeStatic` block):
 *
 *   background  `BackgroundLook.ciImage` — every background type and look
 *               filter (passes/background/backgroundBake.ts), colour-matched
 *               into the working space. Cached by look: a scene rebuild that
 *               does not touch the backdrop does not re-bake it.
 *   shadow      `makeFrameShadow`: shape mask × (opacity·0.45) black →
 *               CIGaussianBlur(σ = radius/2) → translate down radius/3.
 *               Device takes: the mask is the BEZEL's continuous-corner rect.
 *   device      bezel / side / island sprites (framed device takes).
 *   base        shadow (+ bezel) composited over the background —
 *               `cachedBaseFrame`.
 *
 * Nothing here runs per frame; a settings change or resize re-bakes.
 */
import { L, Uniforms, type PooledTexture } from "../gpu/resources";
import { blurWGSL, shadowComposeWGSL, shapeMaskWGSL } from "../gpu/shaders";
import type { Rect } from "../layout";
import { rasterizeSquircle } from "../shapes";
import { BackgroundBaker } from "./background/backgroundBake";
import { makeDeviceSprites } from "./device/deviceRaster";
import { destroySprites, SpriteDrawer } from "./sprite";
import type { PassContext, Scene, StaticTextures } from "./types";

const RT = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING;

type Mask = NonNullable<StaticTextures["outerMask"]>;

export class StaticLayers {
  private textures: StaticTextures | null = null;
  private owned: PooledTexture[] = [];
  private maskTextures: GPUTexture[] = [];
  private maskU: Uniforms;
  private blurHU: Uniforms;
  private blurVU: Uniforms;
  private composeU: Uniforms;
  private readonly baker: BackgroundBaker;
  private readonly sprites = new SpriteDrawer();
  /** Last bake duration (ms, CPU encode + GPU completion). */
  lastBakeMs = 0;

  constructor(private readonly device: GPUDevice) {
    this.maskU = new Uniforms(device, 12, "mask-u");
    this.blurHU = new Uniforms(device, 4, "blur-h-u");
    this.blurVU = new Uniforms(device, 4, "blur-v-u");
    this.composeU = new Uniforms(device, 4, "compose-u");
    this.baker = new BackgroundBaker(device);
  }

  get current(): StaticTextures | null {
    return this.textures;
  }

  /** The background baker's last run (lab/HUD). */
  get backgroundStats() {
    return this.baker.lastStats;
  }

  private squircle(rect: Rect, radius: number): Mask {
    const raster = rasterizeSquircle(rect, radius);
    const texture = this.device.createTexture({
      label: "squircle-mask",
      size: { width: raster.width, height: raster.height },
      format: "r8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    this.device.queue.writeTexture(
      { texture },
      raster.coverage,
      { bytesPerRow: raster.width },
      { width: raster.width, height: raster.height },
    );
    this.maskTextures.push(texture);
    return {
      texture,
      view: texture.createView(),
      originX: raster.originX,
      originY: raster.originY,
      width: raster.width,
      height: raster.height,
    };
  }

  /** Re-bakes for `scene`; encodes into `commands` (submitted with the frame). */
  bake(ctx: Omit<PassContext, "statics">, scene: Scene, commands: GPUCommandEncoder): StaticTextures {
    const t0 = performance.now();
    this.releaseAll(ctx);
    const { device, pipelines, pool } = ctx;
    const { width: W, height: H } = scene.target;
    const g = scene.geometry;

    // ── background (all types + look; cached by the baker) ──
    const background = this.baker.bake(ctx, scene, commands);

    // ── squircle mask for the outer frame clip / device screen ──
    const outerMask: StaticTextures["outerMask"] =
      g.outer.kind === "squircle" ? this.squircle(g.videoRect, g.outer.radius) : null;

    // ── device chrome sprites ──
    const deviceSprites = g.device
      ? makeDeviceSprites(device, g.device.screenRect, g.device.bezelRect, g.device.isPhone)
      : null;

    // ── shadow ──
    let shadow: PooledTexture | null = null;
    let base = background;
    const sh = g.shadow;
    if (sh) {
      // The shadow's own squircle: shares the frame-clip raster when it is the
      // same shape (plain squircle frames), else its own (device bezel).
      let shadowMask: Mask | null = null;
      if (sh.shape === "squircle") {
        const same =
          outerMask && !g.device && sh.cornerRadius === g.outer.radius &&
          sh.rect.x === g.videoRect.x && sh.rect.y === g.videoRect.y &&
          sh.rect.width === g.videoRect.width && sh.rect.height === g.videoRect.height;
        shadowMask = same ? outerMask : this.squircle(sh.rect, sh.cornerRadius);
      }
      const usage = RT;
      const mask = pool.acquire(W, H, "r16float", usage, "shadow-mask");
      const blurH = pool.acquire(W, H, "r16float", usage, "shadow-blur-h");
      shadow = this.own(pool.acquire(W, H, "r16float", usage, "shadow"));
      const kind = sh.shape === "squircle" ? 2 : sh.shape === "roundedRect" ? 1 : 0;
      this.maskU.write([
        sh.rect.x, sh.rect.y, sh.rect.width, sh.rect.height,
        sh.cornerRadius, kind, sh.alpha, 0,
        shadowMask?.originX ?? 0, shadowMask?.originY ?? 0, shadowMask?.width ?? 1, shadowMask?.height ?? 1,
      ]);
      {
        const { pipeline, layout } = pipelines.get({
          id: "shape-mask", code: shapeMaskWGSL, format: "r16float", blend: "replace",
          entries: [L.uniform(0), L.texture(1)],
        });
        const pass = commands.beginRenderPass({
          label: "bake-shadow-mask",
          colorAttachments: [{ view: mask.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
        });
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, device.createBindGroup({
          layout,
          entries: [
            { binding: 0, resource: { buffer: this.maskU.buffer } },
            { binding: 1, resource: shadowMask?.view ?? ctx.dummy },
          ],
        }));
        pass.draw(3);
        pass.end();
      }
      const taps = Math.max(1, Math.ceil(sh.sigma * 3));
      const blur = pipelines.get({
        id: "blur", code: blurWGSL, format: "r16float", blend: "replace", entries: [L.uniform(0), L.texture(1)],
      });
      this.blurHU.write([1, 0, sh.sigma, taps]);
      this.blurVU.write([0, 1, sh.sigma, taps]);
      for (const [src, dst, u, label] of [
        [mask, blurH, this.blurHU, "bake-shadow-blur-h"],
        [blurH, shadow, this.blurVU, "bake-shadow-blur-v"],
      ] as const) {
        const pass = commands.beginRenderPass({
          label,
          colorAttachments: [{ view: dst.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
        });
        pass.setPipeline(blur.pipeline);
        pass.setBindGroup(0, device.createBindGroup({
          layout: blur.layout,
          entries: [
            { binding: 0, resource: { buffer: u.buffer } },
            { binding: 1, resource: src.view },
          ],
        }));
        pass.draw(3);
        pass.end();
      }
      // Intermediates go back to the pool once the GPU has consumed them;
      // releasing now is safe because pool reuse is only ever encoded later.
      pool.release(mask);
      pool.release(blurH);

      base = this.own(pool.acquire(W, H, "rgba8unorm", RT, "static-base"));
      this.composeU.write([sh.offsetY, 0, 0, 0]);
      const compose = pipelines.get({
        id: "shadow-compose", code: shadowComposeWGSL, format: "rgba8unorm", blend: "replace",
        entries: [L.uniform(0), L.texture(1), L.texture(2)],
      });
      const pass = commands.beginRenderPass({
        label: "bake-base",
        colorAttachments: [{ view: base.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      });
      pass.setPipeline(compose.pipeline);
      pass.setBindGroup(0, device.createBindGroup({
        layout: compose.layout,
        entries: [
          { binding: 0, resource: { buffer: this.composeU.buffer } },
          { binding: 1, resource: shadow.view },
          { binding: 2, resource: background.view },
        ],
      }));
      pass.draw(3);
      pass.end();
    }

    // ── device bezel over shadow + background (cachedBaseFrame) ──
    if (deviceSprites?.bezel) {
      if (base === background) {
        // No shadow: copy the background so the bezel never paints into it.
        base = this.own(pool.acquire(W, H, "rgba8unorm", RT | GPUTextureUsage.COPY_DST, "static-base"));
        commands.copyTextureToTexture({ texture: background.texture }, { texture: base.texture }, { width: W, height: H });
      }
      const pass = commands.beginRenderPass({
        label: "bake-bezel",
        colorAttachments: [{ view: base.view, loadOp: "load", storeOp: "store" }],
      });
      this.sprites.begin();
      this.sprites.draw(ctx, pass, "rgba8unorm", [1, 0, 0, 0, 1, 0, 0, 0, 1], scene.target, deviceSprites.bezel);
      pass.end();
    }

    this.textures = { background, base, shadow, outerMask, device: deviceSprites };
    this.lastBakeMs = performance.now() - t0;
    return this.textures;
  }

  private own(t: PooledTexture): PooledTexture {
    this.owned.push(t);
    return t;
  }

  private releaseAll(ctx: Omit<PassContext, "statics">) {
    for (const t of this.owned) ctx.pool.release(t);
    this.owned = [];
    // Destroy after the GPU is done with any frame still referencing them.
    const old = this.maskTextures;
    this.maskTextures = [];
    if (old.length) ctx.device.queue.onSubmittedWorkDone().then(() => old.forEach((t) => t.destroy()));
    const d = this.textures?.device;
    if (d) destroySprites(ctx.device, [d.bezel, d.side, d.island]);
    this.textures = null;
  }

  destroy(ctx: Omit<PassContext, "statics">): void {
    this.releaseAll(ctx);
    this.baker.destroy(ctx);
    this.sprites.destroy();
    this.maskU.destroy();
    this.blurHU.destroy();
    this.blurVU.destroy();
    this.composeU.destroy();
  }
}
