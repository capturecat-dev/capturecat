/**
 * BackgroundBaker — `BackgroundLook.cgImage(for:size:scale:)` (the Mac
 * preview's backdrop bitmap and the exporter's `createBackground`) on the
 * GPU, baked ONCE per distinct look (cached by a spec key; a scene rebuild
 * that does not touch the backdrop reuses the texture — no per-frame work,
 * no re-bake on unrelated edits).
 *
 *   fill      gradient / mesh / solid / image (aspect-fill) / wallpaper fallback
 *             → base8 (the 8-bit CG bitmap, premultiplied sRGB)
 *   styled    (non-plain looks) pixellate → halftone → blur → colour controls
 *             → hue → tint → vignette in LINEAR light → styled8
 *   grain     exact integer grain on the bytes (non-zero noise)
 *   resolve   sRGB bytes → working space (Display P3 for P3 recordings)
 *
 * The order and every constant follow `testing/backgroundLookReference.ts`,
 * which is checked against real Mac bitmaps (backgroundLook.test.ts).
 *
 * Image / Wallpaper: the bitmap is `scene.extras.assets.images` keyed by
 * `settings.backgroundImagePath` (already decoded with EXIF orientation and
 * capped at `maxImageEdge`, see media/assets.ts). Missing image → the Mac's
 * fallback (Wallpaper: vertical Oklab ramp white 0.16 → 0.09; Image: black).
 */
import {
  aspectFillRect,
  baseFill,
  blurSigma,
  grainAmplitude,
  grainCell,
  grainDelta,
  halftoneWidth,
  meshPools,
  pixelateScale,
  renderPath,
  specFromSettings,
  type BackgroundSpec,
} from "../../../core/math/backgroundLook";
import { drawPoints } from "../../../core/math/backgroundGradientRenderer";
import { gradientTableFromTo } from "../../../core/math/oklabGradient";
import type { RenderSettings } from "../../contract";
import { L, Uniforms, type PooledTexture } from "../../gpu/resources";
import { ciBlurSigma, DOT_SCREEN_GAIN, DOT_SCREEN_SHARPNESS, hueMatrix, lin, VIGNETTE_FALLOFF } from "./ciLook";
import type { PassContext, Scene } from "../types";
import {
  downsampleWGSL,
  fillWGSL,
  gaussWGSL,
  grainWGSL,
  halftoneWGSL,
  imageResampleWGSL,
  postWGSL,
  preWGSL,
  resolveWGSL,
  upsampleWGSL,
} from "./shaders";

const RT = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING;
type BakeContext = Omit<PassContext, "statics">;

/** The look spec for a scene: the lossless core settings when parsed, else the engine subset (plain look). */
export function sceneBackgroundSpec(scene: Scene): BackgroundSpec {
  const core = scene.extras.project?.settings;
  if (core) return specFromSettings(core);
  const s: RenderSettings = scene.settings;
  const c = (v: RenderSettings["solidColor"]) => ({ red: v.red, green: v.green, blue: v.blue, alpha: v.opacity });
  return {
    type: s.backgroundType,
    gradientStart: c(s.gradientStartColor),
    gradientEnd: c(s.gradientEndColor),
    gradientAngle: s.gradientAngle,
    solid: c(s.solidColor),
    imagePath: null,
    blur: 0, brightness: 0, saturation: 1, tint: { red: 0, green: 0, blue: 0, alpha: 1 }, tintOpacity: 0,
    vignette: 0, pixelate: 0, halftone: 0, noise: 0, contrast: 1, hue: 0,
  };
}

/** Points→pixels scale of the bitmap: Mac preview = backing scale, export = 1. */
export function sceneBackgroundScale(scene: Scene): number {
  return scene.extras.pixelScale ?? scene.geometry.canvasScale;
}

export interface BakeStats {
  path: string;
  ms: number;
  blurFactor: number;
  blurTaps: number;
}

export class BackgroundBaker {
  private out: PooledTexture | null = null;
  private key = "";
  private tableTex: GPUTexture | null = null;
  private imageTex: { bitmap: ImageBitmap; texture: GPUTexture } | null = null;
  private buffers: GPUBuffer[] = [];
  private uniforms: Uniforms[] = [];
  lastStats: BakeStats | null = null;

  constructor(private readonly device: GPUDevice) {}

  /**
   * The working-space background for `scene` (rgba8unorm, premultiplied).
   * Encodes into `commands` when the look changed; otherwise returns the
   * cached texture untouched.
   */
  bake(ctx: BakeContext, scene: Scene, commands: GPUCommandEncoder): PooledTexture {
    const t0 = performance.now();
    const { width: W, height: H } = scene.target;
    const spec = sceneBackgroundSpec(scene);
    const scale = sceneBackgroundScale(scene);
    const bitmap = spec.imagePath ? scene.extras.assets.images.get(spec.imagePath) ?? null : null;
    const imageId = bitmap ? `${bitmap.width}x${bitmap.height}#${this.bitmapId(bitmap)}` : "none";
    const key = JSON.stringify([spec, W, H, scale, scene.workingSpace, imageId]);
    if (this.out && key === this.key) return this.out;

    this.releaseTransient(ctx);
    ctx.pool.release(this.out);
    this.out = null;

    const pixelSize = { width: W, height: H };
    const path = renderPath(spec, pixelSize, 1);
    const fill = baseFill(spec, bitmap !== null);
    const stats: BakeStats = { path: `${path}/${fill.kind}`, ms: 0, blurFactor: 1, blurTaps: 0 };

    // ── base fill → base8 ──
    const base8 = ctx.pool.acquire(W, H, "rgba8unorm", RT, "bg-base8");
    if (path === "nil") {
      this.clear(commands, base8);
    } else if (fill.kind === "image" && bitmap) {
      this.drawImage(ctx, commands, bitmap, base8);
    } else {
      this.drawFill(ctx, commands, spec, fill, base8);
    }

    let bytes = base8;
    const temps: PooledTexture[] = [];
    if (path === "styled" || path === "styledGrain") {
      bytes = this.styled(ctx, commands, spec, base8, temps, stats);
      temps.push(base8);
    }
    if (path === "baseGrain" || path === "styledGrain") {
      const grained = ctx.pool.acquire(W, H, "rgba8unorm", RT, "bg-grain8");
      this.grain(ctx, commands, spec.noise, scale, bytes, grained);
      temps.push(bytes);
      bytes = grained;
    }

    // ── resolve into the working space ──
    const out = ctx.pool.acquire(W, H, "rgba8unorm", RT, "static-bg");
    const ru = this.u(4, "bg-resolve-u");
    ru.write([scene.workingSpace === "display-p3" ? 1 : 0, 0, 0, 0]);
    this.run(ctx, commands, "bg-resolve", resolveWGSL, "rgba8unorm", out, [
      { binding: 0, resource: { buffer: ru.buffer } },
      { binding: 1, resource: bytes.view },
    ], [L.uniform(0), L.texture(1)]);
    temps.push(bytes);
    for (const t of new Set(temps)) if (t !== out) ctx.pool.release(t);

    this.out = out;
    this.key = key;
    stats.ms = performance.now() - t0;
    this.lastStats = stats;
    return out;
  }

  // ── stages ────────────────────────────────────────────────────────────────

  private drawFill(
    ctx: BakeContext,
    commands: GPUCommandEncoder,
    spec: BackgroundSpec,
    fill: ReturnType<typeof baseFill>,
    target: PooledTexture,
  ) {
    const { width: W, height: H } = target;
    const rect = { x: 0, y: 0, width: W, height: H };
    const u = this.u(4 + 4 + 4 + 6 * 8, "bg-fill-u");
    const data = new Array(4 + 4 + 4 + 6 * 8).fill(0);
    data[0] = W;
    data[1] = H;
    let tableFrom = spec.gradientStart;
    let tableTo = spec.gradientEnd;
    switch (fill.kind) {
      case "solid":
        data[2] = 1;
        data.splice(8, 4, fill.color.red, fill.color.green, fill.color.blue, fill.color.alpha);
        break;
      case "gradient":
      case "mesh": {
        data[2] = fill.kind === "mesh" ? 3 : 2;
        const axis = fill.kind === "mesh" ? { kind: "diagonal" as const } : fill.axis;
        tableFrom = fill.start;
        tableTo = fill.end;
        const pts = drawPoints(rect, axis);
        if (pts) data.splice(4, 4, pts.p0.x, pts.p0.y, pts.p1.x, pts.p1.y);
        if (fill.kind === "mesh") {
          meshPools(fill.start, fill.end, { width: W, height: H }).forEach((p, k) => {
            const o = 12 + k * 8;
            data.splice(o, 8, p.center.x, p.center.y, p.radius, p.stops[0].alpha, p.color.red, p.color.green, p.color.blue, 0);
          });
        }
        break;
      }
      default:
        data[2] = 0;
    }
    u.write(data);
    const table = this.gradientTable(tableFrom, tableTo);
    this.run(ctx, commands, "bg-fill", fillWGSL, "rgba8unorm", target, [
      { binding: 0, resource: { buffer: u.buffer } },
      { binding: 1, resource: table.createView() },
    ], [L.uniform(0), L.unfilterable(1)]);
  }

  private drawImage(ctx: BakeContext, commands: GPUCommandEncoder, bitmap: ImageBitmap, target: PooledTexture) {
    const { width: W, height: H } = target;
    const src = this.imageTexture(bitmap);
    const r = aspectFillRect(bitmap.width, bitmap.height, { width: W, height: H });
    const scale = r.width / bitmap.width;
    // Only the source rows the vertical pass reads (visible range ± support).
    const support = 3 / Math.min(scale, 1) + 2;
    const row0 = Math.max(0, Math.floor((0 - r.y) / scale - support));
    const row1 = Math.min(bitmap.height, Math.ceil((H - r.y) / scale + support));
    const rows = Math.max(1, row1 - row0);
    const mid = ctx.pool.acquire(W, rows, "rgba16float", RT, "bg-image-h");
    const uh = this.u(8, "bg-image-h-u");
    uh.write([0, scale, r.x, bitmap.width, row0, 0, 0, 0]);
    this.run(ctx, commands, "bg-image", imageResampleWGSL, "rgba16float", mid, [
      { binding: 0, resource: { buffer: uh.buffer } },
      { binding: 1, resource: src.createView() },
    ], [L.uniform(0), L.unfilterable(1)]);
    const uv = this.u(8, "bg-image-v-u");
    uv.write([1, scale, r.y, bitmap.height, row0, 0, 0, 0]);
    this.run(ctx, commands, "bg-image", imageResampleWGSL, "rgba8unorm", target, [
      { binding: 0, resource: { buffer: uv.buffer } },
      { binding: 1, resource: mid.view },
    ], [L.uniform(0), L.unfilterable(1)]);
    ctx.pool.release(mid);
  }

  private styled(
    ctx: BakeContext,
    commands: GPUCommandEncoder,
    spec: BackgroundSpec,
    base8: PooledTexture,
    temps: PooledTexture[],
    stats: BakeStats,
  ): PooledTexture {
    const { width: W, height: H } = base8;
    const px = { width: W, height: H };
    const F = "rgba16float" as const;
    let cur = ctx.pool.acquire(W, H, F, RT, "bg-lin-a");
    const block = pixelateScale(spec.pixelate, px);
    const pu = this.u(4, "bg-pre-u");
    pu.write([W, H, block >= 1 ? block : 0, 0]);
    this.run(ctx, commands, "bg-pre", preWGSL, F, cur, [
      { binding: 0, resource: { buffer: pu.buffer } },
      { binding: 1, resource: base8.view },
    ], [L.uniform(0), L.unfilterable(1)]);

    if (spec.halftone > 0) {
      const s = DOT_SCREEN_SHARPNESS;
      const hu = this.u(4, "bg-halftone-u");
      hu.write([H, (2 * Math.PI) / halftoneWidth(spec.halftone, px), 1 / (1 - s), (DOT_SCREEN_GAIN * s) / (4 * (1 - s))]);
      const next = ctx.pool.acquire(W, H, F, RT, "bg-lin-b");
      this.run(ctx, commands, "bg-halftone", halftoneWGSL, F, next, [
        { binding: 0, resource: { buffer: hu.buffer } },
        { binding: 1, resource: cur.view },
      ], [L.uniform(0), L.unfilterable(1)]);
      ctx.pool.release(cur);
      cur = next;
    }

    const sigma = blurSigma(spec.blur, px);
    if (sigma > 0.01) cur = this.blur(ctx, commands, cur, ciBlurSigma(sigma), stats);

    const out8 = ctx.pool.acquire(W, H, "rgba8unorm", RT, "bg-styled8");
    const flags =
      (Math.abs(spec.brightness) >= 0.0005 || Math.abs(spec.saturation - 1) >= 0.0005 || Math.abs(spec.contrast - 1) >= 0.0005 ? 1 : 0) |
      (Math.abs(spec.hue) >= 0.0005 ? 2 : 0) |
      (spec.tintOpacity > 0 ? 4 : 0) |
      (spec.vignette > 0 ? 8 : 0);
    const hm = hueMatrix((spec.hue * Math.PI) / 180);
    const ta = spec.tint.alpha * Math.max(0, Math.min(1, spec.tintOpacity));
    const v = Math.max(0, Math.min(1, spec.vignette));
    const post = this.u(28, "bg-post-u");
    post.write([
      W, H, flags, 0,
      spec.saturation, spec.contrast, spec.brightness, 0,
      hm[0], hm[1], hm[2], 0,
      hm[3], hm[4], hm[5], 0,
      hm[6], hm[7], hm[8], 0,
      lin(spec.tint.red) * ta, lin(spec.tint.green) * ta, lin(spec.tint.blue) * ta, ta,
      v, Math.hypot(W, H) * 0.5 * (1.1 - 0.5 * v), 0.5 + VIGNETTE_FALLOFF, 0,
    ]);
    this.run(ctx, commands, "bg-post", postWGSL, "rgba8unorm", out8, [
      { binding: 0, resource: { buffer: post.buffer } },
      { binding: 1, resource: cur.view },
    ], [L.uniform(0), L.unfilterable(1)]);
    temps.push(cur);
    return out8;
  }

  /**
   * Gaussian σ on `src` (linear). σ ≥ 12: box-downsample by a power of two f
   * (σ/f ≥ 6), blur at σ' = √(σ² − f²/4)/f, bilinear upsample — the added
   * variance of the box (f²−1)/12 + the tent f²/6 ≈ f²/4 is subtracted.
   */
  private blur(ctx: BakeContext, commands: GPUCommandEncoder, src: PooledTexture, sigma: number, stats: BakeStats): PooledTexture {
    const F = "rgba16float" as const;
    const { width: W, height: H } = src;
    let f = 1;
    while (sigma / (f * 2) >= 6 && f < 32) f *= 2;
    let work = src;
    let sLow = sigma;
    if (f > 1) {
      const dw = Math.ceil(W / f);
      const dh = Math.ceil(H / f);
      const small = ctx.pool.acquire(dw, dh, F, RT, "bg-blur-down");
      const du = this.u(4, "bg-down-u");
      du.write([f, 0, 0, 0]);
      this.run(ctx, commands, "bg-down", downsampleWGSL, F, small, [
        { binding: 0, resource: { buffer: du.buffer } },
        { binding: 1, resource: src.view },
      ], [L.uniform(0), L.unfilterable(1)]);
      work = small;
      sLow = Math.sqrt(Math.max(0.25, sigma * sigma - (f * f) / 4)) / f;
    }
    const r = Math.max(1, Math.ceil(sLow * 4));
    const w = new Float32Array(r + 1);
    let sum = 0;
    for (let i = 0; i <= r; i++) {
      w[i] = Math.exp(-(i * i) / (2 * sLow * sLow));
      sum += i === 0 ? w[i] : 2 * w[i];
    }
    for (let i = 0; i <= r; i++) w[i] /= sum;
    const wb = this.device.createBuffer({ label: "bg-gauss-w", size: Math.max(16, w.byteLength), usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    this.device.queue.writeBuffer(wb, 0, w);
    this.buffers.push(wb);
    const tmp = ctx.pool.acquire(work.width, work.height, F, RT, "bg-blur-h");
    const out = ctx.pool.acquire(work.width, work.height, F, RT, "bg-blur-v");
    const gh = this.u(4, "bg-gauss-h-u");
    const gv = this.u(4, "bg-gauss-v-u");
    gh.write([1, 0, r, 0]);
    gv.write([0, 1, r, 0]);
    const layout = [L.uniform(0), L.unfilterable(1), L.storage(2)];
    this.run(ctx, commands, "bg-gauss", gaussWGSL, F, tmp, [
      { binding: 0, resource: { buffer: gh.buffer } },
      { binding: 1, resource: work.view },
      { binding: 2, resource: { buffer: wb } },
    ], layout);
    this.run(ctx, commands, "bg-gauss", gaussWGSL, F, out, [
      { binding: 0, resource: { buffer: gv.buffer } },
      { binding: 1, resource: tmp.view },
      { binding: 2, resource: { buffer: wb } },
    ], layout);
    ctx.pool.release(tmp);
    stats.blurFactor = f;
    stats.blurTaps = 2 * r + 1;
    if (f === 1) {
      ctx.pool.release(src);
      return out;
    }
    ctx.pool.release(work);
    const full = ctx.pool.acquire(W, H, F, RT, "bg-blur-up");
    const uu = this.u(4, "bg-up-u");
    uu.write([f, 0, 0, 0]);
    this.run(ctx, commands, "bg-up", upsampleWGSL, F, full, [
      { binding: 0, resource: { buffer: uu.buffer } },
      { binding: 1, resource: out.view },
    ], [L.uniform(0), L.unfilterable(1)]);
    ctx.pool.release(out);
    ctx.pool.release(src);
    return full;
  }

  private grain(ctx: BakeContext, commands: GPUCommandEncoder, amount: number, scale: number, src: PooledTexture, dst: PooledTexture) {
    const amplitude = grainAmplitude(amount);
    const table = new Int32Array(65536);
    const f32 = Math.fround;
    for (let k = 0; k < 65536; k++) table[k] = grainDelta(f32(f32(f32(f32(k) / 65535) * 2) - 1), amplitude);
    const buf = this.device.createBuffer({ label: "bg-grain-deltas", size: table.byteLength, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    this.device.queue.writeBuffer(buf, 0, table);
    this.buffers.push(buf);
    const gu = this.u(4, "bg-grain-u");
    gu.write([grainCell(scale), 0, 0, 0]);
    this.run(ctx, commands, "bg-grain", grainWGSL, "rgba8unorm", dst, [
      { binding: 0, resource: { buffer: gu.buffer } },
      { binding: 1, resource: src.view },
      { binding: 2, resource: { buffer: buf } },
    ], [L.uniform(0), L.unfilterable(1), L.storage(2)]);
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  private run(
    ctx: BakeContext,
    commands: GPUCommandEncoder,
    id: string,
    code: string,
    format: GPUTextureFormat,
    target: PooledTexture,
    entries: GPUBindGroupEntry[],
    layoutEntries: GPUBindGroupLayoutEntry[],
  ) {
    const { pipeline, layout } = ctx.pipelines.get({ id, code, format, blend: "replace", entries: layoutEntries });
    const pass = commands.beginRenderPass({
      label: id,
      colorAttachments: [{ view: target.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({ layout, entries }));
    pass.draw(3);
    pass.end();
  }

  private clear(commands: GPUCommandEncoder, target: PooledTexture) {
    commands
      .beginRenderPass({ label: "bg-clear", colorAttachments: [{ view: target.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }] })
      .end();
  }

  /** A fresh uniform buffer for this bake (destroyed with the next bake). */
  private u(floats: number, label: string): Uniforms {
    const u = new Uniforms(this.device, floats, label);
    this.uniforms.push(u);
    return u;
  }

  /** 257-stop Oklab table (core `gradientTableFromTo`) as a 257×1 rgba32float texture. */
  private gradientTable(from: BackgroundSpec["gradientStart"], to: BackgroundSpec["gradientEnd"]): GPUTexture {
    const table = gradientTableFromTo(from, to);
    const data = new Float32Array(257 * 4);
    table.forEach((s, i) => data.set([s.color.red, s.color.green, s.color.blue, s.color.alpha], i * 4));
    this.tableTex?.destroy();
    const tex = this.device.createTexture({
      label: "bg-gradient-table",
      size: { width: 257, height: 1 },
      format: "rgba32float",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    this.device.queue.writeTexture({ texture: tex }, data, { bytesPerRow: 257 * 16 }, { width: 257, height: 1 });
    this.tableTex = tex;
    return tex;
  }

  private imageTexture(bitmap: ImageBitmap): GPUTexture {
    if (this.imageTex?.bitmap === bitmap) return this.imageTex.texture;
    this.imageTex?.texture.destroy();
    const texture = this.device.createTexture({
      label: "bg-image",
      size: { width: bitmap.width, height: bitmap.height },
      format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
    });
    // The bitmap is already premultiplied (media/assets.ts); CG draws the
    // image colour-matched into its sRGB bitmap context.
    this.device.queue.copyExternalImageToTexture(
      { source: bitmap },
      { texture, colorSpace: "srgb", premultipliedAlpha: true },
      { width: bitmap.width, height: bitmap.height },
    );
    this.imageTex = { bitmap, texture };
    return texture;
  }

  private ids = new WeakMap<ImageBitmap, number>();
  private nextId = 1;
  private bitmapId(b: ImageBitmap): number {
    let id = this.ids.get(b);
    if (!id) {
      id = this.nextId++;
      this.ids.set(b, id);
    }
    return id;
  }

  /** Buffers of the previous bake die once the GPU is done with them. */
  private releaseTransient(ctx: BakeContext) {
    const bufs = this.buffers;
    const us = this.uniforms;
    this.buffers = [];
    this.uniforms = [];
    if (bufs.length || us.length) {
      ctx.device.queue.onSubmittedWorkDone().then(() => {
        bufs.forEach((b) => b.destroy());
        us.forEach((u) => u.destroy());
      });
    }
  }

  destroy(ctx: BakeContext): void {
    this.releaseTransient(ctx);
    ctx.pool.release(this.out);
    this.out = null;
    this.key = "";
    const table = this.tableTex;
    const image = this.imageTex?.texture;
    this.tableTex = null;
    this.imageTex = null;
    ctx.device.queue.onSubmittedWorkDone().then(() => {
      table?.destroy();
      image?.destroy();
    });
  }
}
