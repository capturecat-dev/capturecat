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
 *   segment     stitched takes with device source segments
 *               (`segmentDeviceAssets`): the segment screen mask (× the outer
 *               frame clip), the bezel's own shadow, bezel / side / island
 *               sprites for the FIRST device segment's content rect.
 *
 * Nothing here runs per frame; a settings change or resize re-bakes.
 */
import { L, Uniforms, type PooledTexture } from "../gpu/resources";
import { blurWGSL, shadowComposeWGSL, shapeMaskWGSL } from "../gpu/shaders";
import type { CardGeometry, Rect } from "../layout";
import { multiplyRaster, rasterCoverageAt, rasterizeSquircle, sdRoundRect, type ShapeRaster } from "../shapes";
import { segmentFramingYDown } from "../../core/math/deviceSegmentDip";
import { BackgroundBaker } from "./background/backgroundBake";
import { makeDeviceSprites } from "./device/deviceRaster";
import { destroySprites, SpriteDrawer } from "./sprite";
import type { PassContext, Scene, SegmentStatics, StaticTextures } from "./types";

const RT = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING;

type Mask = NonNullable<StaticTextures["outerMask"]>;
type ShadowSpec = NonNullable<CardGeometry["shadow"]>;

/** One shadow bake's uniforms — separate per shadow: queue writes land before the submit. */
interface ShadowUniforms {
  mask: Uniforms;
  blurH: Uniforms;
  blurV: Uniforms;
}

export class StaticLayers {
  private textures: StaticTextures | null = null;
  private owned: PooledTexture[] = [];
  private maskTextures: GPUTexture[] = [];
  private cardShadowU: ShadowUniforms;
  private segmentShadowU: ShadowUniforms;
  private composeU: Uniforms;
  private readonly baker: BackgroundBaker;
  private readonly sprites = new SpriteDrawer();
  /** Last bake duration (ms, CPU encode + GPU completion). */
  lastBakeMs = 0;

  constructor(private readonly device: GPUDevice) {
    const shadowUniforms = (label: string): ShadowUniforms => ({
      mask: new Uniforms(device, 12, `${label}-mask-u`),
      blurH: new Uniforms(device, 4, `${label}-blur-h-u`),
      blurV: new Uniforms(device, 4, `${label}-blur-v-u`),
    });
    this.cardShadowU = shadowUniforms("shadow");
    this.segmentShadowU = shadowUniforms("segment-shadow");
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
    return this.upload(rasterizeSquircle(rect, radius));
  }

  private upload(raster: ShapeRaster): Mask {
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
    const outerRaster = g.outer.kind === "squircle" ? rasterizeSquircle(g.videoRect, g.outer.radius) : null;
    const outerMask: StaticTextures["outerMask"] = outerRaster ? this.upload(outerRaster) : null;

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
      shadow = this.encodeShadow(ctx, commands, W, H, sh, shadowMask, this.cardShadowU, "shadow");

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

    // ── stitched device segments (VideoExporter segmentDeviceAssets) ──
    const segment = this.bakeSegment(ctx, scene, commands, outerRaster);

    this.textures = { background, base, shadow, outerMask, device: deviceSprites, segment };
    this.lastBakeMs = performance.now() - t0;
    return this.textures;
  }

  /**
   * The layers a device segment of a stitched take swaps in (VideoExporter
   * `segmentDeviceAssets`, built for the FIRST device segment's content rect):
   *   - `screenMask`: the continuous-corner screen (`screenCornerRadius`) —
   *     multiplied here by the outer frame clip the exporter blends the video
   *     with just before it (`cachedOuterMask`), so the card shaders apply
   *     both through their one squircle slot;
   *   - the bezel's own shadow (`makeFrameShadow` over `bezelRect(subRect)`,
   *     `bezelCornerRadius`, squircle, the card's shadow radius / opacity);
   *   - bezel / side slab / island sprites for the screen rect.
   * Null unless the project is NOT a framed device take, shows device frames,
   * and has a `.device` source segment.
   */
  private bakeSegment(
    ctx: Omit<PassContext, "statics">,
    scene: Scene,
    commands: GPUCommandEncoder,
    outerRaster: ShapeRaster | null,
  ): SegmentStatics | null {
    const p = scene.extras.project;
    const g = scene.geometry;
    if (!p || p.sourceSegments.length === 0) return null;
    const framing = segmentFramingYDown(
      p.recordingSourceKind, p.settings.showDeviceFrame, p.sourceSegments, g.videoRect, scene.target.height,
    );
    if (!framing) return null;

    let raster = rasterizeSquircle(framing.screenRect, framing.screenCornerRadius);
    if (g.outer.kind !== "none") {
      raster = outerRaster
        ? multiplyRaster(raster, (x, y) => rasterCoverageAt(outerRaster, x, y))
        : multiplyRaster(raster, (x, y) => Math.max(0, Math.min(1, 0.5 - sdRoundRect(x, y, g.videoRect, g.outer.radius))));
    }
    const mask = this.upload(raster);

    const sh = g.shadow;
    const spec: ShadowSpec | null = sh
      ? { ...sh, rect: framing.bezelRect, shape: "squircle", cornerRadius: framing.bezelCornerRadius }
      : null;
    const shadow = spec
      ? this.encodeShadow(ctx, commands, scene.target.width, scene.target.height, spec,
          this.squircle(spec.rect, spec.cornerRadius), this.segmentShadowU, "segment-shadow")
      : null;

    const sprites = makeDeviceSprites(ctx.device, framing.screenRect, framing.bezelRect, framing.isPhone);
    return { framing, mask, shadow, sprites };
  }

  /**
   * `makeFrameShadow`: shape mask × (opacity·0.45) black → CIGaussianBlur
   * (σ = radius / 2), un-offset (the compose applies radius / 3). Returns the
   * blurred alpha (r16float, owned by this bake).
   */
  private encodeShadow(
    ctx: Omit<PassContext, "statics">,
    commands: GPUCommandEncoder,
    W: number,
    H: number,
    sh: ShadowSpec,
    shadowMask: Mask | null,
    u: ShadowUniforms,
    label: string,
  ): PooledTexture {
    const { device, pipelines, pool } = ctx;
    const mask = pool.acquire(W, H, "r16float", RT, `${label}-mask`);
    const blurH = pool.acquire(W, H, "r16float", RT, `${label}-blur-h`);
    const shadow = this.own(pool.acquire(W, H, "r16float", RT, label));
    const kind = sh.shape === "squircle" ? 2 : sh.shape === "roundedRect" ? 1 : 0;
    u.mask.write([
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
        label: `bake-${label}-mask`,
        colorAttachments: [{ view: mask.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      });
      pass.setPipeline(pipeline);
      pass.setBindGroup(0, device.createBindGroup({
        layout,
        entries: [
          { binding: 0, resource: { buffer: u.mask.buffer } },
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
    u.blurH.write([1, 0, sh.sigma, taps]);
    u.blurV.write([0, 1, sh.sigma, taps]);
    for (const [src, dst, bu, pass_] of [
      [mask, blurH, u.blurH, `bake-${label}-blur-h`],
      [blurH, shadow, u.blurV, `bake-${label}-blur-v`],
    ] as const) {
      const pass = commands.beginRenderPass({
        label: pass_,
        colorAttachments: [{ view: dst.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      });
      pass.setPipeline(blur.pipeline);
      pass.setBindGroup(0, device.createBindGroup({
        layout: blur.layout,
        entries: [
          { binding: 0, resource: { buffer: bu.buffer } },
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
    return shadow;
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
    const s = this.textures?.segment?.sprites;
    if (s) destroySprites(ctx.device, [s.bezel, s.side, s.island]);
    this.textures = null;
  }

  destroy(ctx: Omit<PassContext, "statics">): void {
    this.releaseAll(ctx);
    this.baker.destroy(ctx);
    this.sprites.destroy();
    for (const u of [this.cardShadowU, this.segmentShadowU]) {
      u.mask.destroy();
      u.blurH.destroy();
      u.blurV.destroy();
    }
    this.composeU.destroy();
  }
}
