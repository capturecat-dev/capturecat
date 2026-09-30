/**
 * Backdrop + card-shadow passes.
 *
 * BackdropPass (stage "backdrop"): what sits under the card.
 *   - camera identity, video present → the baked base (background + shadow),
 *     one texel copy per pixel (Mac: `cachedBaseFrame`).
 *   - camera active → the background only; the shadow rides the card layer
 *     (Mac: `frameBackground` under the warped `cachedCardStatics`).
 *   - no video frame → the background only, NO shadow (Mac: before the first
 *     sample / hidden clip, `composited = cachedBackground`).
 *   - zoom parallax (FrameState.parallax) → the background resampled through
 *     it (Mac: `frameBackground` scaled about the zoom anchor).
 *
 * CardShadowPass (stage "card", layer mode only): the shadow alone over
 * clear, drawn first into the card layer.
 */
import { L, Uniforms } from "../gpu/resources";
import { blitWarpWGSL, blitWGSL, shadowComposeWGSL } from "../gpu/shaders";
import { toRows } from "../mat3";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "./types";

export class BackdropPass implements RenderPass {
  readonly name = "backdrop";
  readonly stage = "backdrop" as const;
  private groups = new WeakMap<GPUTextureView, GPUBindGroup>();
  private warpU: Uniforms | null = null;

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const pass = enc.pass!;
    const withShadow = frame.video !== null && !enc.layerMode;
    const tex = withShadow ? ctx.statics.base : ctx.statics.background;
    if (frame.parallax && enc.layerMode) {
      this.warpU ??= new Uniforms(ctx.device, 12, "backdrop-parallax-u");
      this.warpU.write(toRows(frame.parallax));
      const warp = ctx.pipelines.get({
        id: "blit-warp", code: blitWarpWGSL, format: enc.format, blend: "replace", entries: [L.uniform(0), L.texture(1)],
      });
      pass.setPipeline(warp.pipeline);
      pass.setBindGroup(0, ctx.device.createBindGroup({
        layout: warp.layout,
        entries: [
          { binding: 0, resource: { buffer: this.warpU.buffer } },
          { binding: 1, resource: tex.view },
        ],
      }));
      pass.draw(3);
      return;
    }
    const { pipeline, layout } = ctx.pipelines.get({
      id: "blit", code: blitWGSL, format: enc.format, blend: "replace", entries: [L.texture(0)],
    });
    let group = this.groups.get(tex.view);
    if (!group) {
      group = ctx.device.createBindGroup({ layout, entries: [{ binding: 0, resource: tex.view }] });
      this.groups.set(tex.view, group);
    }
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, group);
    pass.draw(3);
  }

  destroy(): void {
    this.warpU?.destroy();
  }
}

export class CardShadowPass implements RenderPass {
  readonly name = "card-shadow";
  readonly stage = "card" as const;
  private u: Uniforms | null = null;

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    // Direct mode bakes the shadow into the backdrop; only the layer path draws it here.
    if (!enc.layerMode || !frame.video || !ctx.statics.shadow || !ctx.scene.geometry.shadow) return;
    this.u ??= new Uniforms(ctx.device, 4, "card-shadow-u");
    this.u.write([ctx.scene.geometry.shadow.offsetY, 1, 0, 0]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "shadow-compose", code: shadowComposeWGSL, format: enc.format, blend: "premultipliedOver",
      entries: [L.uniform(0), L.texture(1), L.texture(2)],
    });
    const pass = enc.pass!;
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, ctx.device.createBindGroup({
      layout,
      entries: [
        { binding: 0, resource: { buffer: this.u.buffer } },
        { binding: 1, resource: ctx.statics.shadow.view },
        { binding: 2, resource: ctx.statics.background.view },
      ],
    }));
    pass.draw(3);
  }

  destroy(): void {
    this.u?.destroy();
  }
}
