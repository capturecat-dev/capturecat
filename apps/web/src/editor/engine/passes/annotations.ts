/**
 * Annotations — the exporter's `renderAnnotations` burn + the canvas half of
 * the annotation blackout (VideoExporter.export frame loop).
 *
 * AnnotationsPass (stage "card", after every other card overlay but the
 * curtain): `AnnotationRenderer.image(size: outputSize, annotations: active,
 * currentTime: SOURCE time, videoRect: Y-down video rect, scale:
 * outputWidth / 1920 · 2, chrome: nil, rasterScale: 1, videoCornerRadius:
 * outerCornerRadius)` — computed by the core port as a draw RECIPE
 * (`annotationImageRecipe`, locked to Swift by the annotationDrawRecipe
 * vectors), replayed with CG semantics into a Canvas2D raster the size of the
 * target (`raster/cgReplay`), uploaded and composited 1:1 in CARD space, so
 * it rides the zoom / tilt warp exactly like the Mac's pre-warp composite.
 * The card-space backdrop (even-odd video rect minus the rectangle/ellipse
 * cut-out) is part of that recipe.
 *
 * AnnotationBackdropDimPass (stage "backdrop", after the backdrop): the
 * canvas half — `dimmedBackdrop`: black at `AnnotationRenderer.backdropAlpha`
 * over whatever the card does not cover (the base / background, with or
 * without a video frame). Black-over-black source-over is order-independent,
 * so dimming before the card shadow (layer path) equals the Mac's dim over
 * the baked shadow + background.
 *
 * Build effects are sampled from the timeline clock (`frame.sourceTime`),
 * never a wall clock (AnnotationEffectMath), so scrub, playback and export
 * agree. The raster is re-drawn only when its inputs change (the set of
 * active annotations and each one's effect phase / tap-ripple progress);
 * a settled annotation costs one textured quad per frame.
 */
import { effectPhase } from "../../core/math/annotationEffectMath";
import { annotationImageRecipe, backdropAlpha, exportAnnotationScale } from "../../core/math/annotationGeometry";
import { tapRippleProgress } from "../../core/math/overlaySupport";
import type { Annotation, Project } from "../../core/model";
import { Uniforms } from "../gpu/resources";
import { drawTextOp, measureAnnotation } from "../raster/annotationText";
import { boxEmpty, boxUnion, EMPTY_BOX, replayCG, type Box, type Ctx2D } from "../raster/cgReplay";
import { ensureFaces, facesPending } from "../raster/fontCatalog";
import { RasterOverlay } from "./rasterOverlay";
import type { FrameEncoder, FrameState, PassContext, RenderPass, Scene } from "./types";

/** `outerCornerRadius` — the card clip's radius (0 for rectangle frames and device takes). */
export function outerCornerRadius(scene: Scene): number {
  const p = scene.extras.project;
  if (p && p.recordingSourceKind === "device" && p.settings.showDeviceFrame) return 0;
  return scene.geometry.outer.kind === "none" ? 0 : scene.geometry.outer.radius;
}

function activeAt(project: Project, t: number): Annotation[] {
  return project.annotations.filter((a) => t >= a.startTime && t <= a.endTime);
}

let fontEpoch = 0;

export class AnnotationsPass implements RenderPass {
  readonly name = "annotations";
  readonly stage = "card" as const;
  private overlay = new RasterOverlay("annotations");
  private canvas: OffscreenCanvas | null = null;
  private ctx2d: Ctx2D | null = null;
  private layers: OffscreenCanvas[] = [];
  private key = "";
  /** Pixels currently non-clear in the raster (cleared before the next draw). */
  private drawn: Box = EMPTY_BOX;
  private hasContent = false;

  sceneChanged(ctx: PassContext): void {
    this.key = "";
    const project = ctx.scene.extras.project;
    if (!project || project.annotations.length === 0) return;
    if (facesPending(project.annotations)) {
      void ensureFaces(project.annotations).then(() => {
        fontEpoch++;
        ctx.requestFrame();
      });
    }
  }

  invalidate(): void {
    this.key = "";
  }

  private layerCanvas = (depth: number): OffscreenCanvas => {
    const c = this.canvas!;
    let l = this.layers[depth - 1];
    if (!l || l.width !== c.width || l.height !== c.height) {
      l = new OffscreenCanvas(c.width, c.height);
      this.layers[depth - 1] = l;
    }
    return l;
  };

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const scene = ctx.scene;
    const project = scene.extras.project;
    if (!project || project.annotations.length === 0) return;
    const t = frame.sourceTime;
    const active = activeAt(project, t);
    if (active.length === 0) return;

    const { width: W, height: H } = scene.target;
    // Change key: everything the recipe reads that varies per frame.
    let key = `${scene.version}|${W}x${H}|${fontEpoch}|${facesPending(active) ? "p" : "r"}`;
    for (const a of active) {
      const ph = effectPhase(a, t);
      key += `|${a.id}:${ph.alpha},${ph.scale},${ph.offsetY},${ph.strokeProgress}`;
      if (a.type === "tap") key += `,${tapRippleProgress(t - a.startTime)}`;
      if (a.backdropOpacity > 0.001) key += "b";
    }

    if (key !== this.key) {
      this.key = key;
      this.render(ctx, active, t, W, H);
    }
    if (this.hasContent) this.overlay.draw(ctx, enc, { x: 0, y: 0, width: W, height: H }, enc.cardToTarget);
  }

  private render(ctx: PassContext, active: Annotation[], t: number, W: number, H: number): void {
    const scene = ctx.scene;
    if (!this.canvas || this.canvas.width !== W || this.canvas.height !== H) {
      this.canvas = new OffscreenCanvas(W, H);
      this.ctx2d = this.canvas.getContext("2d") as Ctx2D;
      this.layers = [];
      this.drawn = EMPTY_BOX;
    }
    const c2d = this.ctx2d!;
    const recipe = annotationImageRecipe(
      { width: W, height: H },
      active,
      t,
      scene.geometry.videoRect,
      exportAnnotationScale(W),
      null,
      1,
      outerCornerRadius(scene),
      measureAnnotation,
    );
    const prev = this.drawn;
    if (!boxEmpty(prev)) c2d.clearRect(prev.x0, prev.y0, prev.x1 - prev.x0, prev.y1 - prev.y0);
    let drawn: Box = EMPTY_BOX;
    if (recipe) {
      drawn = replayCG(c2d, recipe.ops, {
        width: W,
        height: H,
        drawText: (c, op) => drawTextOp(c, op),
        layerCanvas: this.layerCanvas,
      });
    }
    this.drawn = drawn;
    const resized = this.overlay.ensure(ctx.device, W, H);
    const dirty = resized ? { x0: 0, y0: 0, x1: W, y1: H } : boxUnion(prev, drawn);
    if (!boxEmpty(dirty)) {
      this.overlay.upload(ctx.device, this.canvas!, scene.workingSpace, {
        x: dirty.x0,
        y: dirty.y0,
        width: dirty.x1 - dirty.x0,
        height: dirty.y1 - dirty.y0,
      });
    }
    this.hasContent = !boxEmpty(drawn);
  }

  destroy(): void {
    this.overlay.destroy();
    this.canvas = null;
    this.ctx2d = null;
    this.layers = [];
  }
}

const dimWGSL = /* wgsl */ `
struct DimU { c: vec4f };
@group(0) @binding(0) var<uniform> u: DimU;
struct VSOut { @builtin(position) pos: vec4f };
@vertex fn vs_fullscreen(@builtin(vertex_index) i: u32) -> VSOut {
  var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
  var o: VSOut;
  o.pos = vec4f(p[i], 0.0, 1.0);
  return o;
}
@fragment fn fs_main(in: VSOut) -> @location(0) vec4f {
  return u.c;   // premultiplied black at the dim alpha
}
`;

export class AnnotationBackdropDimPass implements RenderPass {
  readonly name = "annotation-backdrop-dim";
  readonly stage = "backdrop" as const;
  private u: Uniforms | null = null;
  private group: { layout: GPUBindGroupLayout; group: GPUBindGroup } | null = null;

  encode(ctx: PassContext, frame: FrameState, enc: FrameEncoder): void {
    const project = ctx.scene.extras.project;
    if (!project || project.annotations.length === 0 || !enc.pass) return;
    const alpha = backdropAlpha(project.annotations, frame.sourceTime);
    if (!(alpha > 0.001)) return;
    this.u ??= new Uniforms(ctx.device, 4, "annotation-dim-u");
    this.u.write([0, 0, 0, alpha]);
    const { pipeline, layout } = ctx.pipelines.get({
      id: "annotation-dim",
      code: dimWGSL,
      format: enc.format,
      blend: "premultipliedOver",
      entries: [{ binding: 0, visibility: GPUShaderStage.FRAGMENT, buffer: { type: "uniform" } }],
    });
    if (!this.group || this.group.layout !== layout) {
      this.group = { layout, group: ctx.device.createBindGroup({ layout, entries: [{ binding: 0, resource: { buffer: this.u.buffer } }] }) };
    }
    enc.pass.setPipeline(pipeline);
    enc.pass.setBindGroup(0, this.group.group);
    enc.pass.draw(3);
  }

  destroy(): void {
    this.u?.destroy();
  }
}
