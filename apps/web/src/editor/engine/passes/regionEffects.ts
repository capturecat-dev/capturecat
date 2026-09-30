/**
 * RegionVideoPass (stage "prepare") — the exporter's per-frame VIDEO-LAYER
 * regions, in its order (VideoExporter.export ~1608-1659):
 *
 *   videoLayer = compositeFrame(...)            window-masked fitted video
 *   for blur  in activeBlurs  (project order):  applyRegionBlur
 *   for focus in activeFocus  (project order):  CIMaskedVariableBlur(FocusMath mask)
 *   → outer frame clip (VideoCardPass, layer branch) → over the card base …
 *
 * Only when a blur / focus region is active: the layer is rendered into a
 * texture over its CI extent E (contentRect with a window mask, else
 * videoRect ∩ contentRect — rounded out, the rect `clampedToExtent()` clamps
 * at), processed, and handed to VideoCardPass via `resources.videoLayer`.
 * Otherwise the card pass samples the video directly (zero cost here).
 *
 * Blur = CIGaussianBlur(σ = blurRadius, UNHALVED — the Mac export's known
 * preview/export mismatch, ported from the export) or CIPixellate, mixed
 * through the area-coverage (optionally Gaussian-feathered) rect mask.
 * Depth Focus = CoreImage's measured CIMaskedVariableBlur pyramid (see
 * regionPlan.ts) over FocusMath's mask.
 *
 * GPU budget (60 fps at 1080p): Gaussians are separable, two taps per
 * bilinear fetch, and large σ run on a 2×2-box mip level of a full-res
 * clamp-padded copy (σ corrected for the mip prefilter + bilinear upsample);
 * the finished layer is cached per (video frame, plans), so paused /
 * 30-fps-on-60-Hz frames cost nothing extra. Measured on this Mac at a
 * 1920×1080 target: +0.2 ms (blur + pixelate), +0.5 ms (Depth Focus) per new
 * video frame.
 */
import { L, Uniforms, type PooledTexture } from "../gpu/resources";
import {
  blurRegionWGSL,
  focusAccumWGSL,
  gaussianWGSL,
  layerDirectWGSL,
  layerFittedWGSL,
  mipWGSL,
  padWGSL,
} from "../gpu/regionShaders";
import { toRows, translate } from "../mat3";
import {
  blurLevel,
  blurOps,
  exportSpace,
  featherFactors,
  focusOps,
  maskedVariableBlurLevels,
  padFor,
  videoLayerExtent,
  type BlurOp,
  type FocusOp,
} from "./regionPlan";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "./types";

const RT = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING;
const LAYER_FORMAT: GPUTextureFormat = "rgba16float";

interface Rect4 {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

interface Pyramid {
  /** Full-res clamp padding on every side (a multiple of every level factor). */
  M: number;
  /** levels[0] = the padded full-res layer, levels[j] = 2^j downsample. */
  levels: PooledTexture[];
}

export class RegionVideoPass implements RenderPass {
  readonly name = "region-video";
  readonly stage = "prepare" as const;

  private uniforms: Uniforms[] = [];
  private uIdx = 0;
  private storage: GPUBuffer[] = [];
  private sIdx = 0;
  private out: PooledTexture | null = null;
  private key = "";
  private masks = new Map<string, { key: string; tex: GPUTexture; view: GPUTextureView }>();
  /** Frames actually processed (vs. served from the cache) — lab stats. */
  processed = 0;

  sceneChanged(ctx: PassContext): void {
    ctx.pool.release(this.out);
    this.out = null;
    this.key = "";
  }

  invalidate(): void {
    this.key = "";
  }

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    enc.resources.videoLayer = null;
    const project = ctx.scene.extras.project;
    const video = frame.video;
    if (!project || !video || !enc.resources.external) return this.drop(ctx);
    if (!project.blurRegions.length && !project.focusRegions.length) return this.drop(ctx);
    const scene = ctx.scene;
    const g = scene.geometry;
    const sp = exportSpace(scene);
    const t = frame.sourceTime;
    const blurs = blurOps(project, g.videoRect, t, sp);
    const focus = focusOps(project, g.videoRect, t, sp);
    if (!blurs.length && !focus.length) return this.drop(ctx);
    const E = videoLayerExtent(g.videoRect, g.contentRect, g.inner.kind !== "none", scene.target);
    if (E.width <= 0 || E.height <= 0) return this.drop(ctx);

    const key = JSON.stringify([
      video.index, video.frame.timestamp, scene.version, !!enc.resources.fitted, E,
      blurs.map((b) => [b.index, b.style, b.rect, b.sigma, b.block, b.gx, b.gy, b.featherSigma]),
      focus.map((f) => [f.index, f.maskKey, f.sigma]),
    ]);
    if (key === this.key && this.out) {
      enc.resources.videoLayer = { view: this.out.view, rect: E };
      return;
    }

    this.uIdx = 0;
    this.sIdx = 0;
    let cur = this.renderBaseLayer(ctx, enc, E, video.frame);
    for (const op of blurs) cur = this.applyBlur(ctx, enc, cur, op, E);
    for (const op of focus) cur = this.applyFocus(ctx, enc, cur, op, E);

    if (this.out && this.out !== cur) ctx.pool.release(this.out);
    this.out = cur;
    this.key = key;
    this.processed++;
    enc.resources.videoLayer = { view: cur.view, rect: E };
  }

  private drop(ctx: PassContext): void {
    if (this.out) ctx.pool.release(this.out);
    this.out = null;
    this.key = "";
  }

  // ── Resources ─────────────────────────────────────────────────────────────

  /** A fresh uniform buffer for this frame (each pass needs its own values). */
  private nextUniform(ctx: PassContext): Uniforms {
    let u = this.uniforms[this.uIdx];
    if (!u) this.uniforms.push((u = new Uniforms(ctx.device, 56, "region-u")));
    this.uIdx++;
    return u;
  }

  private nextStorage(ctx: PassContext, data: Float32Array<ArrayBuffer>): GPUBuffer {
    let b = this.storage[this.sIdx];
    if (!b || b.size < data.byteLength) {
      b?.destroy();
      b = ctx.device.createBuffer({
        label: "region-mask-factors",
        size: Math.max(256, Math.ceil(data.byteLength / 256) * 256),
        usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
      });
      this.storage[this.sIdx] = b;
    }
    this.sIdx++;
    ctx.device.queue.writeBuffer(b, 0, data);
    return b;
  }

  private fullscreen(
    ctx: PassContext,
    enc: FrameEncoder,
    target: PooledTexture,
    label: string,
    pipeline: GPURenderPipeline,
    group: GPUBindGroup,
    load: GPULoadOp = "clear",
    scissor?: Rect4,
  ): void {
    const pass = enc.beginPass({
      label,
      colorAttachments: [{ view: target.view, loadOp: load, storeOp: "store", clearValue: [0, 0, 0, 0] }],
    });
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, group);
    if (scissor) pass.setScissorRect(scissor.x0, scissor.y0, scissor.x1 - scissor.x0, scissor.y1 - scissor.y0);
    pass.draw(3);
    pass.end();
  }

  // ── The video layer (compositeFrame without the outer clip) ───────────────

  private renderBaseLayer(
    ctx: PassContext,
    enc: FrameEncoder,
    E: { x: number; y: number; width: number; height: number },
    video: VideoFrame,
  ): PooledTexture {
    const g = ctx.scene.geometry;
    const fitted = enc.resources.fitted;
    const frame = enc.resources.external!;
    const vr = g.videoRect;
    const cr = g.contentRect;
    const u = this.nextUniform(ctx);
    const inv = translate(E.x, E.y);
    const sampleW = fitted ? fitted.width : video.displayWidth;
    const sampleH = fitted ? fitted.height : video.displayHeight;
    u.write([
      ...toRows(translate(-E.x, -E.y)),
      ...toRows(inv),
      E.width, E.height, 1, 0,
      vr.x, vr.y, vr.width, vr.height,
      cr.x, cr.y, cr.width, cr.height,
      E.x, E.y, E.width, E.height,
      g.inner.radius, g.inner.kind === "none" ? 0 : 1, 0, 0,
      0, 0, 0, 0, // outer clip: applied by the card pass AFTER the regions
      0, 0, 1, 1,
      sampleW, sampleH, g.videoScale, 0,
    ]);
    const tex = ctx.pool.acquire(E.width, E.height, LAYER_FORMAT, RT, "region-layer");
    const { pipeline, layout } = ctx.pipelines.get({
      id: fitted ? "region-layer-fitted" : "region-layer-direct",
      code: fitted ? layerFittedWGSL : layerDirectWGSL,
      fragmentEntry: "fs_layer",
      format: LAYER_FORMAT,
      blend: "replace",
      entries: [L.uniform(0, true), L.sampler(1), L.texture(2), fitted ? L.texture(3) : L.external(3)],
    });
    const group = ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: u.buffer } },
        { binding: 1, resource: ctx.pipelines.linearSampler() },
        { binding: 2, resource: ctx.dummy },
        { binding: 3, resource: fitted ? fitted.view : frame },
      ],
    });
    this.fullscreen(ctx, enc, tex, "region-layer", pipeline, group);
    return tex;
  }

  // ── Mips + separable Gaussian ─────────────────────────────────────────────

  /**
   * A mip pyramid of `cur` padded by M px of clamp-to-edge replication at
   * FULL resolution (M a multiple of every level factor used): clamping a
   * coarse level instead would replicate a whole d-px band — a feature near
   * the edge would smear outward (seen as a dark bleed at the fixture's
   * bottom-edge strip before this).
   */
  private pyramid(ctx: PassContext, enc: FrameEncoder, cur: PooledTexture, M: number): Pyramid {
    const { pipeline, layout } = ctx.pipelines.get({
      id: "region-pad", code: padWGSL, format: LAYER_FORMAT, blend: "replace", entries: [L.uniform(0), L.texture(1)],
    });
    const u = this.nextUniform(ctx);
    u.write([M, M, 0, 0]);
    const base = ctx.pool.acquire(cur.width + 2 * M, cur.height + 2 * M, LAYER_FORMAT, RT, "region-pad");
    const group = ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: u.buffer } },
        { binding: 1, resource: cur.view },
      ],
    });
    this.fullscreen(ctx, enc, base, "region-pad", pipeline, group);
    return { M, levels: [base] };
  }

  private pyramidLevel(ctx: PassContext, enc: FrameEncoder, pyr: Pyramid, j: number): PooledTexture {
    const { pipeline, layout } = ctx.pipelines.get({
      id: "region-mip", code: mipWGSL, format: LAYER_FORMAT, blend: "replace", entries: [L.texture(0)],
    });
    while (pyr.levels.length <= j) {
      const src = pyr.levels[pyr.levels.length - 1];
      const dst = ctx.pool.acquire(Math.ceil(src.width / 2), Math.ceil(src.height / 2), LAYER_FORMAT, RT, "region-mip");
      const group = ctx.device.createBindGroup({ layout, entries: [{ binding: 0, resource: src.view }] });
      this.fullscreen(ctx, enc, dst, "region-mip", pipeline, group);
      pyr.levels.push(dst);
    }
    return pyr.levels[j];
  }

  private releasePyramid(ctx: PassContext, pyr: Pyramid | null): void {
    if (pyr) for (const t of pyr.levels) ctx.pool.release(t);
  }

  /**
   * Gaussian(σ full-res px) of the layer over the layer-px rect S: from the
   * layer itself (d = 1) or a padded pyramid level. Returns the blurred
   * texture + how layer px p maps into it: (p + off) / d − origin.
   */
  private blurredLevel(
    ctx: PassContext,
    enc: FrameEncoder,
    cur: PooledTexture,
    pyr: () => Pyramid,
    sigma: number,
    minLow: number,
    S: Rect4,
  ): { tex: PooledTexture; x: number; y: number; d: number; off: number } {
    const { j, d, sigmaLow } = blurLevel(sigma, minLow);
    let src = cur;
    let off = 0;
    if (j > 0) {
      const p = pyr();
      src = this.pyramidLevel(ctx, enc, p, j);
      off = p.M;
    }
    const out: Rect4 = {
      x0: Math.max(0, Math.floor((S.x0 + off) / d) - 1),
      y0: Math.max(0, Math.floor((S.y0 + off) / d) - 1),
      x1: Math.min(src.width, Math.ceil((S.x1 + off) / d) + 1),
      y1: Math.min(src.height, Math.ceil((S.y1 + off) / d) + 1),
    };
    return { tex: this.gaussian(ctx, enc, src, sigmaLow, out), x: out.x0, y: out.y0, d, off };
  }

  /** Gaussian(σ in `src` texels) of `src` over `out` (src texel rect), clamp-to-edge. */
  private gaussian(ctx: PassContext, enc: FrameEncoder, src: PooledTexture, sigma: number, out: Rect4): PooledTexture {
    const r = Math.max(1, Math.ceil(sigma * 3));
    const w = out.x1 - out.x0;
    const h = out.y1 - out.y0;
    const hy0 = Math.max(0, out.y0 - r);
    const hy1 = Math.min(src.height, out.y1 + r);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "region-gauss", code: gaussianWGSL, format: LAYER_FORMAT, blend: "replace",
      entries: [L.uniform(0), L.texture(1), L.sampler(2)],
    });
    const run = (from: PooledTexture, to: PooledTexture, dir: [number, number], ox: number, oy: number) => {
      const u = this.nextUniform(ctx);
      u.write([dir[0], dir[1], sigma, r, ox, oy, 0, 0]);
      const group = ctx.device.createBindGroup({
        layout,
        entries: [
          { binding: 0, resource: { buffer: u.buffer } },
          { binding: 1, resource: from.view },
          { binding: 2, resource: ctx.pipelines.linearSampler() },
        ],
      });
      this.fullscreen(ctx, enc, to, dir[0] ? "region-gauss-h" : "region-gauss-v", pipeline, group);
    };
    const H = ctx.pool.acquire(w, hy1 - hy0, LAYER_FORMAT, RT, "region-gauss-h");
    run(src, H, [1, 0], out.x0, hy0);
    const V = ctx.pool.acquire(w, h, LAYER_FORMAT, RT, "region-gauss-v");
    run(H, V, [0, 1], 0, out.y0 - hy0);
    ctx.pool.release(H);
    return V;
  }

  // ── applyRegionBlur ───────────────────────────────────────────────────────

  private applyBlur(
    ctx: PassContext,
    enc: FrameEncoder,
    cur: PooledTexture,
    op: BlurOp,
    E: { x: number; y: number; width: number; height: number },
  ): PooledTexture {
    // Mask support in layer px (the feathered mask reaches ~3σ past the rect).
    const m = op.featherSigma > 0 ? Math.ceil(op.featherSigma * 3) + 1 : 1;
    const S: Rect4 = {
      x0: Math.max(0, Math.floor(op.rect.x - E.x) - m),
      y0: Math.max(0, Math.floor(op.rect.y - E.y) - m),
      x1: Math.min(E.width, Math.ceil(op.rect.x + op.rect.width - E.x) + m),
      y1: Math.min(E.height, Math.ceil(op.rect.y + op.rect.height - E.y) + m),
    };
    if (S.x1 <= S.x0 || S.y1 <= S.y0) return cur;
    const { mx, my } = featherFactors(op.rect, op.featherSigma, E);
    const bx = this.nextStorage(ctx, mx as Float32Array<ArrayBuffer>);
    const by = this.nextStorage(ctx, my as Float32Array<ArrayBuffer>);

    let blurred: PooledTexture | null = null;
    let lvl = { x: 0, y: 0, d: 1, off: 0 };
    let pyr: Pyramid | null = null;
    if (op.style === "Blur" && op.sigma > 0) {
      const { d } = blurLevel(op.sigma, 3);
      const b = this.blurredLevel(ctx, enc, cur, () => (pyr ??= this.pyramid(ctx, enc, cur, padFor(op.sigma, d))), op.sigma, 3, S);
      blurred = b.tex;
      lvl = b;
    }

    const u = this.nextUniform(ctx);
    u.write([
      S.x0, S.y0, S.x1, S.y1,
      op.style === "Pixelate" ? 1 : 0, Math.max(1e-3, op.block), op.gx - E.x, op.gy - E.y,
      lvl.x, lvl.y, lvl.d, lvl.off,
    ]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "region-blur", code: blurRegionWGSL, format: LAYER_FORMAT, blend: "replace",
      entries: [L.uniform(0), L.texture(1), L.texture(2), L.sampler(3), L.storage(4), L.storage(5)],
    });
    const next = ctx.pool.acquire(E.width, E.height, LAYER_FORMAT, RT, "region-layer");
    const group = ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: u.buffer } },
        { binding: 1, resource: cur.view },
        { binding: 2, resource: blurred?.view ?? ctx.dummy },
        { binding: 3, resource: ctx.pipelines.linearSampler() },
        { binding: 4, resource: { buffer: bx } },
        { binding: 5, resource: { buffer: by } },
      ],
    });
    this.fullscreen(ctx, enc, next, "region-blur", pipeline, group);
    ctx.pool.release(blurred);
    this.releasePyramid(ctx, pyr);
    ctx.pool.release(cur);
    return next;
  }

  // ── Depth Focus ───────────────────────────────────────────────────────────

  private maskTexture(ctx: PassContext, op: FocusOp): GPUTextureView | null {
    const hit = this.masks.get(op.id);
    if (hit && hit.key === op.maskKey) return hit.view;
    const raster = op.mask();
    if (!raster) return null;
    hit?.tex.destroy();
    const tex = ctx.device.createTexture({
      label: "focus-mask",
      size: { width: raster.width, height: raster.height },
      format: "r8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    ctx.device.queue.writeTexture(
      { texture: tex },
      raster.pixels as Uint8Array<ArrayBuffer>,
      { bytesPerRow: raster.width },
      { width: raster.width, height: raster.height },
    );
    const entry = { key: op.maskKey, tex, view: tex.createView() };
    this.masks.set(op.id, entry);
    return entry.view;
  }

  private applyFocus(
    ctx: PassContext,
    enc: FrameEncoder,
    cur: PooledTexture,
    op: FocusOp,
    E: { x: number; y: number; width: number; height: number },
  ): PooledTexture {
    const maskView = this.maskTexture(ctx, op);
    // The CI pyramid is evaluated in EXPORT px (r = inputRadius × mask), its
    // level blurs drawn at target scale (σ × k).
    const levels = maskedVariableBlurLevels(op.radiusE);
    if (!maskView || levels.length < 2) return cur;
    const k = op.sigma / op.radiusE;
    const vr = { x: op.rect.x - E.x, y: op.rect.y - E.y, w: op.rect.width, h: op.rect.height };
    const S: Rect4 = {
      x0: Math.max(0, Math.floor(vr.x)),
      y0: Math.max(0, Math.floor(vr.y)),
      x1: Math.min(E.width, Math.ceil(vr.x + vr.w)),
      y1: Math.min(E.height, Math.ceil(vr.y + vr.h)),
    };
    if (S.x1 <= S.x0 || S.y1 <= S.y0) return cur;
    const { pipeline, layout } = ctx.pipelines.get({
      id: "region-focus-accum", code: focusAccumWGSL, format: LAYER_FORMAT, blend: "add",
      entries: [L.uniform(0), L.texture(1), L.texture(2), L.sampler(3)],
    });
    const acc = ctx.pool.acquire(E.width, E.height, LAYER_FORMAT, RT, "region-layer");
    const top = levels[levels.length - 1].sd * k;
    let pyr: Pyramid | null = null;
    const getPyr = () => (pyr ??= this.pyramid(ctx, enc, cur, padFor(top, blurLevel(top, 1.5).d)));
    const OPEN = -1e6;
    for (let i = 0; i < levels.length; i++) {
      // Hats in log2(r): knots at the neighbouring levels' radii.
      const lo = i === 0 ? OPEN : Math.log2(levels[i - 1].r);
      const mid = Math.log2(levels[i].r);
      const hi = i === levels.length - 1 ? OPEN : Math.log2(levels[i + 1].r);
      let levelTex = cur;
      let lvl = { x: 0, y: 0, d: 1, off: 0, original: 1 };
      let temp: PooledTexture | null = null;
      if (i > 0) {
        const b = this.blurredLevel(ctx, enc, cur, getPyr, levels[i].sd * k, 1.5, S);
        temp = b.tex;
        levelTex = temp;
        lvl = { ...b, original: 0 };
      }
      const u = this.nextUniform(ctx);
      u.write([vr.x, vr.y, vr.w, vr.h, op.radiusE, lo, mid, hi, lvl.x, lvl.y, lvl.d, lvl.original, lvl.off, 0, 0, 0]);
      const group = ctx.device.createBindGroup({
        layout,
        entries: [
          { binding: 0, resource: { buffer: u.buffer } },
          { binding: 1, resource: maskView },
          { binding: 2, resource: levelTex.view },
          { binding: 3, resource: ctx.pipelines.linearSampler() },
        ],
      });
      // Level 0 covers the whole extent (σ 0 outside the mask); blurred
      // levels only reach the video rect.
      this.fullscreen(ctx, enc, acc, `region-focus-${i}`, pipeline, group, i === 0 ? "clear" : "load", i === 0 ? undefined : S);
      ctx.pool.release(temp);
    }
    this.releasePyramid(ctx, pyr);
    ctx.pool.release(cur);
    return acc;
  }

  destroy(): void {
    for (const u of this.uniforms) u.destroy();
    for (const b of this.storage) b.destroy();
    for (const m of this.masks.values()) m.tex.destroy();
    this.masks.clear();
  }
}
