/**
 * VideoCardPass (stage "card") — `compositeFrame` + the outer frame clip.
 *
 * Per pixel (card space, Y-down): hard crop to videoRect ∩ contentRect (CI
 * `cropped(to:)`), the fitted or directly-sampled video with clear-outside
 * edges, × window-clip mask (inner radius, circular corners) × frame-clip
 * mask (outer radius; rounded rect SDF or the rasterized squircle). Drawn
 * through `enc.cardToTarget`, so the same pass renders into the canvas
 * (identity camera) or the card layer.
 */
import { L, Uniforms } from "../gpu/resources";
import { cardDirectWGSL, cardFittedWGSL } from "../gpu/shaders";
import { cardFromLayerWGSL } from "../gpu/regionShaders";
import { invert, inverseFootprint, toRows } from "../mat3";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "./types";

export class VideoCardPass implements RenderPass {
  readonly name = "video-card";
  readonly stage = "card" as const;
  private u: Uniforms | null = null;
  private lu: Uniforms | null = null;

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const video = frame.video;
    const external = enc.resources.external;
    if (!video || !external) return;
    if (enc.resources.videoLayer) return this.encodeLayer(ctx, enc, enc.resources.videoLayer);
    const g = ctx.scene.geometry;
    const fitted = enc.resources.fitted;
    const fwd = enc.cardToTarget;
    const inv = invert(fwd);
    const t = ctx.scene.target;
    const vr = g.videoRect;
    const cr = g.contentRect;
    // Quad: video ∩ content, +1px so AA edges are never clipped by raster coverage.
    const bx0 = Math.max(vr.x, cr.x) - 1;
    const by0 = Math.max(vr.y, cr.y) - 1;
    const bx1 = Math.min(vr.x + vr.width, cr.x + cr.width) + 1;
    const by1 = Math.min(vr.y + vr.height, cr.y + cr.height) + 1;
    if (bx1 <= bx0 || by1 <= by0) return;
    const sq = ctx.statics.outerMask;
    const footprint = inverseFootprint(inv, t.width / 2, t.height / 2);
    const sampleW = fitted ? fitted.width : video.frame.displayWidth;
    const sampleH = fitted ? fitted.height : video.frame.displayHeight;
    this.u ??= new Uniforms(ctx.device, 56, "card-u");
    this.u.write([
      ...toRows(fwd),
      ...toRows(inv),
      t.width, t.height, footprint, 0,
      vr.x, vr.y, vr.width, vr.height,
      cr.x, cr.y, cr.width, cr.height,
      bx0, by0, bx1 - bx0, by1 - by0,
      g.inner.radius, g.inner.kind === "none" ? 0 : 1, 0, 0,
      g.outer.radius, g.outer.kind === "none" ? 0 : g.outer.kind === "squircle" ? 2 : 1, 0, 0,
      sq?.originX ?? 0, sq?.originY ?? 0, sq?.width ?? 1, sq?.height ?? 1,
      sampleW, sampleH, g.videoScale, g.sourceCropTop,
    ]);
    const entries = [L.uniform(0, true), L.sampler(1), L.texture(2), fitted ? L.texture(3) : L.external(3)];
    const { pipeline, layout } = ctx.pipelines.get({
      id: fitted ? "card-fitted" : "card-direct",
      code: fitted ? cardFittedWGSL : cardDirectWGSL,
      vertexEntry: "vs_card",
      format: enc.format,
      blend: "premultipliedOver",
      entries,
    });
    const pass = enc.pass!;
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: this.u.buffer } },
        { binding: 1, resource: ctx.pipelines.linearSampler() },
        { binding: 2, resource: sq?.view ?? ctx.dummy },
        { binding: 3, resource: fitted ? fitted.view : external },
      ],
    }));
    pass.draw(6);
  }

  /**
   * The region-processed video layer (RegionVideoPass) → target: the same
   * outer frame clip + contentRect crop as above, the window mask already
   * baked into the layer (VideoExporter: blur/focus run on the window-masked
   * layer BEFORE the outer clip). Same uniform layout; `bounds` = the layer.
   */
  private encodeLayer(ctx: PassContext, enc: FrameEncoder, layer: NonNullable<FrameEncoder["resources"]["videoLayer"]>): void {
    const g = ctx.scene.geometry;
    const fwd = enc.cardToTarget;
    const inv = invert(fwd);
    const t = ctx.scene.target;
    const vr = g.videoRect;
    const cr = g.contentRect;
    const b = layer.rect;
    if (b.width <= 0 || b.height <= 0) return;
    const sq = ctx.statics.outerMask;
    const footprint = inverseFootprint(inv, t.width / 2, t.height / 2);
    this.lu ??= new Uniforms(ctx.device, 56, "card-layer-u");
    this.lu.write([
      ...toRows(fwd),
      ...toRows(inv),
      t.width, t.height, footprint, 0,
      vr.x, vr.y, vr.width, vr.height,
      cr.x, cr.y, cr.width, cr.height,
      b.x, b.y, b.width, b.height,
      0, 0, 0, 0,
      g.outer.radius, g.outer.kind === "none" ? 0 : g.outer.kind === "squircle" ? 2 : 1, 0, 0,
      sq?.originX ?? 0, sq?.originY ?? 0, sq?.width ?? 1, sq?.height ?? 1,
      b.width, b.height, 1, 0,
    ]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "card-from-layer",
      code: cardFromLayerWGSL,
      vertexEntry: "vs_card",
      format: enc.format,
      blend: "premultipliedOver",
      entries: [L.uniform(0, true), L.sampler(1), L.texture(2), L.texture(3)],
    });
    const pass = enc.pass!;
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: this.lu.buffer } },
        { binding: 1, resource: ctx.pipelines.linearSampler() },
        { binding: 2, resource: sq?.view ?? ctx.dummy },
        { binding: 3, resource: layer.view },
      ],
    }));
    pass.draw(6);
  }

  destroy(): void {
    this.u?.destroy();
    this.lu?.destroy();
  }
}
