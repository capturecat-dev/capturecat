/**
 * HighlightPass (stage "card") — `applyRegionHighlight` for every active
 * HighlightRegion, in project order, over the COMPOSITED card (the exporter
 * runs it after the cursor + click ripple, before subtitles).
 *
 * Mac recipe (VideoExporter 2721-2872): a CG raster the size of the frame —
 * white over dimRect (= layout.videoRect, a plain rect, so the card's
 * rounded corners dim the background under them too), a black
 * CGPath(roundedRect:) hole over the region — used as the mask of black at
 * `1 − (1 − dimOpacity·envelope)^2.2`, source-over the frame. The export
 * CIContext composites in the gamma working space, so that is exactly
 * premultiplied (0, 0, 0, alpha·mask) OVER the frame. The envelope
 * (smootherStep fade in/out, `animationSpeed.duration`) comes from the
 * shared core `regionEnvelope`, sampled at the frame's source time — so it
 * animates identically when scrubbing, playing and exporting.
 */
import { L, Uniforms } from "../gpu/resources";
import { highlightWGSL } from "../gpu/regionShaders";
import { invert, inverseFootprint, toRows } from "../mat3";
import { exportSpace, highlightOps, roundOut } from "./regionPlan";
import type { FrameEncoder, FrameState, PassContext, RenderPass } from "./types";

export class HighlightPass implements RenderPass {
  readonly name = "highlight";
  readonly stage = "card" as const;
  private uniforms: { quad: Uniforms; hl: Uniforms }[] = [];

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const project = ctx.scene.extras.project;
    if (!project?.highlightRegions.length || !frame.video) return;
    const g = ctx.scene.geometry;
    const ops = highlightOps(project, g.videoRect, frame.sourceTime, exportSpace(ctx.scene));
    if (!ops.length) return;
    const t = ctx.scene.target;
    const fwd = enc.cardToTarget;
    const inv = invert(fwd);
    const footprint = inverseFootprint(inv, t.width / 2, t.height / 2);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "highlight", code: highlightWGSL, vertexEntry: "vs_quad", format: enc.format, blend: "premultipliedOver",
      entries: [L.uniform(0, true), L.uniform(1)],
    });
    const pass = enc.pass!;
    pass.setPipeline(pipeline);
    ops.forEach((op, i) => {
      // The quad: dimRect rounded out (the mask is 0 elsewhere), + 1 px AA.
      const b = roundOut(op.dimRect);
      const u = (this.uniforms[i] ??= {
        quad: new Uniforms(ctx.device, 32, "highlight-quad-u"),
        hl: new Uniforms(ctx.device, 12, "highlight-u"),
      });
      u.quad.write([
        ...toRows(fwd),
        ...toRows(inv),
        t.width, t.height, footprint, 0,
        b.x0 - 1, b.y0 - 1, b.x1 - b.x0 + 2, b.y1 - b.y0 + 2,
      ]);
      u.hl.write([
        op.dimRect.x, op.dimRect.y, op.dimRect.width, op.dimRect.height,
        op.holeRect.x, op.holeRect.y, op.holeRect.width, op.holeRect.height,
        op.cornerRadius, op.alpha, 0, 0,
      ]);
      pass.setBindGroup(0, ctx.device.createBindGroup({
        layout,
        entries: [
          { binding: 0, resource: { buffer: u.quad.buffer } },
          { binding: 1, resource: { buffer: u.hl.buffer } },
        ],
      }));
      pass.draw(6);
    });
  }

  destroy(): void {
    for (const u of this.uniforms) {
      u.quad.destroy();
      u.hl.destroy();
    }
  }
}
