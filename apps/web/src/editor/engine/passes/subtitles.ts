/**
 * SubtitlePass (stage "card") — the exporter's `renderSubtitle` burn (after
 * the highlights, before keystrokes / annotations / curtain; card space, so
 * it rides the camera warp exactly like the Mac's pre-warp burn).
 *
 * Every non-text number is the core port `subtitleRecipe` (locked to the
 * private Swift by `exportSubtitleLayout` vectors): font size, pill padding /
 * corner, edge inset, free / anchored placement, the Background pill colour
 * (alpha 0.75), karaoke run colours (active = highlight, pending = text at
 * 0.4 α), uppercase, Outline (black, σ 2·scale) / Glow (text colour at
 * 0.8 α, σ 6·scale) silhouettes. The text itself is measured and drawn with
 * Canvas2D (engine/text/subtitleText.ts — calibrated to AppKit's advances
 * and line fragments), rasterised into a texture only when the exporter's
 * cache key (segment id + active word count) changes; the silhouette blur
 * runs once per raster on the GPU. Per frame: one textured quad.
 *
 * Layout is evaluated at the EXPORT resolution (line breaks, rounded line
 * heights) and drawn scaled by k = target / export, so the preview is the
 * export, scaled.
 */
import { activeSubtitle, subtitleRecipe, type SubtitleRecipe } from "../../core/math/exportText";
import { L, Uniforms, type PooledTexture } from "../gpu/resources";
import { gaussianWGSL, silhouetteWGSL, subtitleWGSL } from "../gpu/regionShaders";
import { invert, inverseFootprint, toRows } from "../mat3";
import {
  canvasMeasurer,
  layoutSubtitleText,
  onFaceLoaded,
  resolveSubtitleFont,
  type SubtitleTextLayout,
  type TextMeasurer,
} from "../text/subtitleText";
import { exportSpace, fromExportRect } from "./regionPlan";
import { stageHitRecorder } from "../stageHits";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "./types";

const RT = GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING;

interface Raster {
  key: string;
  text: GPUTexture;
  textView: GPUTextureView;
  blurred: PooledTexture | null;
  /** Card-space rect of the raster (integer px). */
  x: number;
  y: number;
  width: number;
  height: number;
  shadow: [number, number, number, number];
}

const css = (c: { r: number; g: number; b: number; a: number }) =>
  `rgba(${c.r * 255}, ${c.g * 255}, ${c.b * 255}, ${Math.max(0, Math.min(1, c.a))})`;

export class SubtitlePass implements RenderPass {
  readonly name = "subtitles";
  readonly stage = "card" as const;
  private measurer: TextMeasurer | null = null;
  private canvas: OffscreenCanvas | null = null;
  private raster: Raster | null = null;
  private quadU: Uniforms | null = null;
  private subU: Uniforms | null = null;
  private blurU: Uniforms[] = [];
  private layouts = new Map<string, SubtitleTextLayout>();
  private fontGen = 0;
  private requestFrame: (() => void) | null = null;
  private unsubscribe: (() => void) | null = null;
  /** Rasters built (vs. reused) — lab stats. */
  rasters = 0;
  readonly stageHit = stageHitRecorder("subtitle");

  sceneChanged(ctx: PassContext): void {
    this.dropRaster(ctx);
  }

  private dropRaster(ctx: PassContext): void {
    if (!this.raster) return;
    this.raster.text.destroy();
    ctx.pool.release(this.raster.blurred);
    this.raster = null;
  }

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const project = ctx.scene.extras.project;
    if (!project || !frame.video || !project.subtitles.length) return;
    const s = project.settings;
    const sub = activeSubtitle(project.subtitles, frame.sourceTime, s.showSubtitles);
    if (!sub) return;
    const scene = ctx.scene;
    const sp = exportSpace(scene);
    const canvasScaleE = scene.geometry.canvasScale / sp.k;
    if (!this.measurer) {
      this.measurer = canvasMeasurer();
      // An exact Mac face finished loading → re-measure, re-raster, re-render.
      this.unsubscribe = onFaceLoaded(() => {
        this.fontGen++;
        this.layouts.clear();
        this.requestFrame?.();
      });
    }
    this.requestFrame = ctx.requestFrame;
    const m = this.measurer;
    let layout: SubtitleTextLayout | null = null;
    const recipe = subtitleRecipe(sub, frame.sourceTime, { width: sp.widthE, height: sp.heightE }, canvasScaleE, s, (req) => {
      // Layout depends on the text + font only (karaoke colours don't wrap).
      const lk = JSON.stringify([req.runs.map((r) => r.text), req.fontName, req.fontSize, req.weight, req.constraintWidth]);
      layout = this.layouts.get(lk) ?? null;
      if (!layout) {
        layout = layoutSubtitleText(m, req);
        if (this.layouts.size > 64) this.layouts.clear();
        if (!layout.font.pending) this.layouts.set(lk, layout);
      }
      return { x: 0, y: 0, width: layout.width, height: layout.height };
    });
    if (!recipe.drawn || !layout) return;
    const key = `${recipe.cacheKey}|${scene.version}|${sp.k}|${this.fontGen}`;
    if (this.raster?.key !== key) {
      this.dropRaster(ctx);
      this.raster = this.build(ctx, recipe, layout, sp.k, sp.heightE, key);
      this.rasters++;
    }
    const r = this.raster;
    if (!r) return;
    // The pill rect (the Mac's lastSubtitleRect) whatever the style, in card
    // px (Y-up export → Y-down), and the free-placement span it moves in.
    this.stageHit.current = {
      rect: fromExportRect({ x: recipe.xPosition, y: recipe.yPosition, width: recipe.bgWidth, height: recipe.bgHeight }, sp),
      space: "card",
      usable: { width: recipe.usableW * sp.k, height: recipe.usableH * sp.k },
    };
    this.draw(ctx, enc, r);
  }

  /** Rasterises the pill + text (Canvas2D) and pre-blurs the silhouette (GPU). */
  private build(
    ctx: PassContext,
    recipe: SubtitleRecipe,
    layout: SubtitleTextLayout,
    k: number,
    heightE: number,
    key: string,
  ): Raster | null {
    // Y-up export → Y-down card px.
    const toCard = (r: { x: number; y: number; width: number; height: number }) => ({
      x: r.x * k,
      y: (heightE - (r.y + r.height)) * k,
      width: r.width * k,
      height: r.height * k,
    });
    const text = toCard(recipe.textRect);
    const pill = recipe.background ? toCard(recipe.background.rect) : null;
    const sigma = recipe.effect ? recipe.effect.radius * k : 0;
    const margin = Math.ceil(sigma * 3) + 2;
    const r0 = pill ?? text;
    const x0 = Math.floor(Math.min(r0.x, text.x)) - margin;
    const y0 = Math.floor(Math.min(r0.y, text.y)) - margin;
    const x1 = Math.ceil(Math.max(r0.x + r0.width, text.x + text.width)) + margin;
    const y1 = Math.ceil(Math.max(r0.y + r0.height, text.y + text.height)) + margin;
    const W = Math.max(1, Math.min(x1 - x0, 8192));
    const H = Math.max(1, Math.min(y1 - y0, 8192));

    this.canvas ??= new OffscreenCanvas(W, H);
    if (this.canvas.width !== W) this.canvas.width = W;
    if (this.canvas.height !== H) this.canvas.height = H;
    const c = this.canvas.getContext("2d", { colorSpace: "srgb" }) as OffscreenCanvasRenderingContext2D | null;
    if (!c) return null;
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.clearRect(0, 0, W, H);
    c.translate(-x0, -y0);

    if (pill && recipe.background) {
      c.fillStyle = css(recipe.background.color);
      c.beginPath();
      c.roundRect(pill.x, pill.y, pill.width, pill.height, recipe.background.cornerRadius * k);
      c.fill();
    }

    // Text: first line at the rect's visual top, each line centred in the
    // rect's width (NSParagraphStyle .center), baseline = line top + ascent.
    const font = resolveSubtitleFont(recipe.fontName, recipe.weight, recipe.fontSize * k, this.measurer!);
    c.font = font.css;
    c.textBaseline = "alphabetic";
    c.textAlign = "left";
    const runs = recipe.runs;
    const bounds: [number, number][] = [];
    let at = 0;
    for (const run of runs) {
      bounds.push([at, at + run.text.length]);
      at += run.text.length;
    }
    // AppKit draws into the CGBitmapContext with each glyph's origin snapped
    // DOWN to whole pixels (the Mac frames' stem edges all share one
    // sub-pixel phase; floor matched the lossless fixture-11 frames to
    // ~0.1 px, round was 1 px off on half the glyphs), Chrome at ¼ px — so
    // each grapheme is drawn at floor(pen); the pen itself advances by the
    // measured (kerned) prefix, so the line keeps AppKit's advances.
    const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    layout.lines.forEach((line, li) => {
      const top = text.y + li * layout.lineHeight * k;
      const baseline = Math.round(top + layout.ascent * k);
      const lx = text.x + ((layout.width - line.width) / 2) * k;
      for (const g of graphemes.segment(line.text)) {
        if (/^\s+$/u.test(g.segment)) continue;
        const at = line.start + g.index;
        const ri = bounds.findIndex(([rs, re]) => at >= rs && at < re);
        const pen = g.index ? c.measureText(line.text.slice(0, g.index)).width : 0;
        c.fillStyle = css(runs[Math.max(0, ri)].color);
        c.fillText(g.segment, Math.floor(lx + pen), baseline);
      }
    });

    const device = ctx.device;
    const tex = device.createTexture({
      label: "subtitle-raster",
      size: { width: W, height: H },
      format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
    });
    device.queue.copyExternalImageToTexture({ source: this.canvas }, { texture: tex, premultipliedAlpha: true }, { width: W, height: H });
    const textView = tex.createView();

    let blurred: PooledTexture | null = null;
    let shadow: [number, number, number, number] = [0, 0, 0, 0];
    if (recipe.effect && sigma > 0) {
      const e = recipe.effect.color;
      shadow = [e.r, e.g, e.b, Math.max(0, Math.min(1, e.a))];
      blurred = this.blurSilhouette(ctx, textView, W, H, sigma);
    }
    return { key, text: tex, textView, blurred, x: x0, y: y0, width: W, height: H, shadow };
  }

  /**
   * subtitleDropShadow: silhouette (a, a²) → CIGaussianBlur(σ). Encoded in
   * its own command buffer, submitted before the frame's (queue order).
   */
  private blurSilhouette(ctx: PassContext, text: GPUTextureView, W: number, H: number, sigma: number): PooledTexture {
    const device = ctx.device;
    const enc = device.createCommandEncoder({ label: "subtitle-silhouette" });
    const pool = ctx.pool;
    const run = (target: PooledTexture, pipeline: GPURenderPipeline, group: GPUBindGroup) => {
      const p = enc.beginRenderPass({
        colorAttachments: [{ view: target.view, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }],
      });
      p.setPipeline(pipeline);
      p.setBindGroup(0, group);
      p.draw(3);
      p.end();
    };
    const sil = ctx.pipelines.get({ id: "subtitle-silhouette", code: silhouetteWGSL, format: "rgba16float", blend: "replace", entries: [L.texture(0)] });
    const seed = pool.acquire(W, H, "rgba16float", RT, "subtitle-sil");
    run(seed, sil.pipeline, device.createBindGroup({ layout: sil.layout, entries: [{ binding: 0, resource: text }] }));
    const g = ctx.pipelines.get({
      id: "region-gauss", code: gaussianWGSL, format: "rgba16float", blend: "replace",
      entries: [L.uniform(0), L.texture(1), L.sampler(2)],
    });
    const taps = Math.max(1, Math.ceil(sigma * 3));
    const pass = (i: number, from: PooledTexture, to: PooledTexture, dir: [number, number]) => {
      const u = (this.blurU[i] ??= new Uniforms(device, 8, "subtitle-blur-u"));
      u.write([dir[0], dir[1], sigma, taps, 0, 0, 0, 0]);
      run(to, g.pipeline, device.createBindGroup({
        layout: g.layout,
        entries: [
          { binding: 0, resource: { buffer: u.buffer } },
          { binding: 1, resource: from.view },
          { binding: 2, resource: ctx.pipelines.linearSampler() },
        ],
      }));
    };
    const h = pool.acquire(W, H, "rgba16float", RT, "subtitle-blur-h");
    pass(0, seed, h, [1, 0]);
    const v = pool.acquire(W, H, "rgba16float", RT, "subtitle-blur-v");
    pass(1, h, v, [0, 1]);
    device.queue.submit([enc.finish()]);
    pool.release(seed);
    pool.release(h);
    return v;
  }

  private draw(ctx: PassContext, enc: FrameEncoder, r: Raster): void {
    const t = ctx.scene.target;
    const fwd = enc.cardToTarget;
    const inv = invert(fwd);
    this.quadU ??= new Uniforms(ctx.device, 32, "subtitle-quad-u");
    this.subU ??= new Uniforms(ctx.device, 8, "subtitle-u");
    this.quadU.write([
      ...toRows(fwd),
      ...toRows(inv),
      t.width, t.height, inverseFootprint(inv, t.width / 2, t.height / 2), 0,
      r.x, r.y, r.width, r.height,
    ]);
    this.subU.write([...r.shadow, ctx.scene.workingSpace === "display-p3" ? 1 : 0, 0, 0, 0]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "subtitle", code: subtitleWGSL, vertexEntry: "vs_quad", format: enc.format, blend: "premultipliedOver",
      entries: [L.uniform(0, true), L.uniform(1), L.texture(2), L.texture(3)],
    });
    const pass = enc.pass!;
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: this.quadU.buffer } },
        { binding: 1, resource: { buffer: this.subU.buffer } },
        { binding: 2, resource: r.textView },
        { binding: 3, resource: r.blurred?.view ?? ctx.dummy },
      ],
    }));
    pass.draw(6);
  }

  destroy(): void {
    this.unsubscribe?.();
    this.raster?.text.destroy();
    this.quadU?.destroy();
    this.subU?.destroy();
    for (const u of this.blurU) u.destroy();
  }
}
